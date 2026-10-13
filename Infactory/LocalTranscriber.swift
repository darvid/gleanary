import AVFoundation
import CoreMedia
import Foundation
import Speech

protocol AudioTranscribing: Sendable {
    func transcribe(_ file: URL, locale: String, downloadModel: Bool) async throws -> [TimedText]
}

struct LocalTranscriber: AudioTranscribing {
    static func timedSegments(_ text: AttributedString, fallback: CMTimeRange) -> [TimedText] {
        var segments: [TimedText] = []
        var prefix = ""
        for run in text.runs {
            let content = String(text[run.range].characters)
            if let range = run.audioTimeRange {
                segments.append(TimedText(
                    text: prefix + content,
                    start: range.start.seconds,
                    duration: range.duration.seconds
                ))
                prefix = ""
            } else if let previous = segments.popLast() {
                // Untimed spaces and punctuation belong to the adjacent timed words.
                segments.append(TimedText(
                    text: previous.text + content,
                    start: previous.start,
                    duration: previous.duration
                ))
            } else {
                prefix += content
            }
        }
        if segments.isEmpty, !prefix.isEmpty {
            segments.append(TimedText(
                text: prefix,
                start: fallback.start.seconds,
                duration: fallback.duration.seconds
            ))
        }
        return segments
    }

    func transcribe(
        _ url: URL,
        locale identifier: String,
        downloadModel: Bool
    ) async throws -> [TimedText] {
        guard SpeechTranscriber.isAvailable,
              let locale = await SpeechTranscriber
              .supportedLocale(equivalentTo: Locale(identifier: identifier))
        else { throw MediaError.speechUnavailable }
        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .timeIndexedTranscriptionWithAlternatives
        )
        if await AssetInventory.status(forModules: [transcriber]) != .installed {
            guard downloadModel else { throw MediaError.speechModelMissing }
            if let installation = try await AssetInventory
                .assetInstallationRequest(supporting: [transcriber])
            {
                try await withTaskCancellationHandler { try await installation.downloadAndInstall()
                }
                onCancel: { installation.progress.cancel() }
            }
        }
        try Task.checkCancellation()
        let file = try AVAudioFile(forReading: url)
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard duration.isFinite, duration > 0,
              duration <= 7200 else { throw MediaError.durationLimit }
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let results = Task<[TimedText], any Error> {
            var segments: [TimedText] = []
            for try await result in transcriber.results {
                try Task.checkCancellation()
                guard result.isFinal else { continue }
                let timed = Self.timedSegments(result.text, fallback: result.range)
                guard segments.count + timed.count <= 100_000 else { throw CaptureError.tooLarge }
                segments.append(contentsOf: timed)
            }
            return segments
        }
        do {
            return try await withTaskCancellationHandler {
                try await analyzer.start(inputAudioFile: file, finishAfterFile: true)
                return try await results.value
            } onCancel: {
                results.cancel()
                Task { await analyzer.cancelAndFinishNow() }
            }
        } catch {
            results.cancel()
            await analyzer.cancelAndFinishNow()
            throw error
        }
    }
}
