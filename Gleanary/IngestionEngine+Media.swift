import Foundation

extension IngestionEngine {
    func acquireMedia(
        _ target: MediaTarget,
        job: CaptureJob,
        changed: @escaping @Sendable () async -> Void
    ) async throws -> [Artifact] {
        if target.site != .youtube {
            do {
                let fetched = try await fetcher.fetch(target.url)
                guard let final = try MediaTarget.parse(fetched.url),
                      final.identity == target.identity else { throw MediaError.wrongPage }
                let html = try Self.decodeText(fetched.data, encoding: fetched.encoding, html: true)
                let snapshot = try await SocialCapture.extractHTML(html, target: target)
                return try await retainSocial(snapshot, target: target)
            } catch {
                try Task.checkCancellation()
                throw MediaError.browserRequired
            }
        }
        if job.request.audioLocale != nil {
            let resolved: ResolvedAudio
            do { resolved = try await youtube.audio(for: target) }
            catch {
                try Task.checkCancellation(); throw (error as? MediaError) ?? MediaError.blocked
            }
            let fetched = try await fetcher.fetch(resolved.url)
            let audio = try await artifacts.retain(
                fetched.data,
                kind: .audio,
                name: "YouTube audio.m4a",
                sourceURL: target.url
            )
            let info = try await artifacts.retain(
                JSONEncoder().encode(resolved.info),
                kind: .json,
                name: "Audio metadata.json",
                sourceURL: target.url
            )
            let acquired = [audio, info]
            try await store.checkpoint(
                job,
                acquired: acquired,
                progress: "Audio retained, preparing on-device transcription"
            )
            await changed()
            return try await transcribeAudio(target, job: job, acquired: acquired, changed: changed)
        }
        let transcript: VideoTranscript
        do { transcript = try await youtube.transcript(for: target) }
        catch {
            try Task.checkCancellation()
            guard job.request.summarizeLink == false else { throw error }
            // A user-requested chat capture can retain a known video identity without inventing
            // content. Say whether the video has no captions or YouTube just didn't send them,
            // since only the second is worth retrying.
            let missing = (error as? MediaError) == .noCaptions
                ? "This video has no captions."
                : "YouTube didn't return the video's captions. Retry the capture to try again."
            return try await retainSnapshot(withCreatorText(target, CapturedDocument(
                title: "YouTube · \(target.id)", identifier: target.id, sourceURL: target.url,
                coverage: .partial,
                warnings: [missing + " Only the source link is saved."],
                blocks: [ContentBlock(
                    kind: .paragraph,
                    markdown: "Source: \(target.url.absoluteString)\n\nTranscript unavailable. \(missing)",
                    text: "Source: \(target.url.absoluteString). Transcript unavailable. \(missing)",
                    method: "metadata-only"
                )]
            )), originals: [])
        }
        let raw = try await artifacts.retain(
            JSONEncoder().encode(transcript),
            kind: .json,
            name: "Fetched transcript.json",
            sourceURL: target.url
        )
        return try await retainSnapshot(
            withCreatorText(target, transcript.document(for: target)),
            originals: [raw]
        )
    }

    /// Adds the creator's description and pinned comment after the transcript, when YouTube
    /// provides them.
    func withCreatorText(
        _ target: MediaTarget,
        _ document: CapturedDocument
    ) async -> CapturedDocument {
        guard let creator = await youtube.creatorText(for: target) else { return document }
        var document = document
        document.blocks += creator.blocks
        return document
    }

    func transcribeAudio(
        _ target: MediaTarget,
        job: CaptureJob,
        acquired: [Artifact],
        changed: @escaping @Sendable () async -> Void
    ) async throws -> [Artifact] {
        guard let audio = acquired.first, audio.kind == .audio,
              let metadata = acquired.dropFirst().first,
              let locale = job.request.audioLocale else { throw MediaError.noCaptions }
        // Integrity-check before handing the managed file to an audio decoder.
        _ = try await artifacts.data(for: audio)
        let info = try await JSONDecoder().decode(
            VideoAudioInfo.self,
            from: artifacts.data(for: metadata)
        )
        guard info.videoID == target.id, info.duration > 0,
              info.duration <= 7200 else { throw MediaError.durationLimit }
        try await store.checkpoint(
            job,
            acquired: acquired,
            progress: "Transcribing locally (\(locale))"
        )
        await changed()
        let segments = try await transcriber.transcribe(
            artifacts.fileURL(audio.hash),
            locale: locale,
            downloadModel: job.request.downloadSpeechModel == true
        )
        try Task.checkCancellation()
        let transcript = VideoTranscript(
            videoID: target.id,
            title: info.title,
            author: info.author,
            language: locale,
            generated: true,
            method: "apple-speech-transcriber-v1",
            segments: segments
        )
        let raw = try await artifacts.retain(
            JSONEncoder().encode(transcript),
            kind: .json,
            name: "On-device transcript.json",
            sourceURL: target.url
        )
        let retained = try await retainSnapshot(
            withCreatorText(target, transcript.document(for: target)),
            originals: acquired + [raw]
        )
        try await store.checkpoint(job, acquired: retained, progress: "Transcript retained locally")
        return retained
    }

    func submitBrowserCapture(_ snapshot: SocialSnapshot, job: CaptureJob) async throws {
        guard let url = job.request.url, let target = try MediaTarget.parse(url),
              target.site != .youtube else { throw MediaError.invalidLink }
        let retained = try await retainSocial(snapshot, target: target)
        try Task.checkCancellation()
        try await store.resumeMedia(job, artifacts: retained)
    }

    private func retainSocial(
        _ snapshot: SocialSnapshot,
        target: MediaTarget
    ) async throws -> [Artifact] {
        let document = try SocialCapture.document(snapshot, target: target)
        let raw = try await artifacts.retain(
            JSONEncoder().encode(snapshot),
            kind: .json,
            name: "Loaded posts.json",
            sourceURL: target.url
        )
        return try await retainSnapshot(document, originals: [raw])
    }

    private func retainSnapshot(
        _ input: CapturedDocument,
        originals: [Artifact]
    ) async throws -> [Artifact] {
        var document = input
        try document.validate()
        let retained = try await artifacts.retain(
            JSONEncoder().encode(document),
            kind: .capture,
            name: "Extracted capture.json",
            sourceURL: document.sourceURL
        )
        return [retained] + originals
    }
}
