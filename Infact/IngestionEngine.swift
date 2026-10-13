import CoreFoundation
import Foundation

actor IngestionEngine {
    let store: DocumentStore
    let artifacts: ArtifactStore
    let fetcher: any SourceFetching
    let youtube: any YouTubeProviding
    let transcriber: any AudioTranscribing
    let summarizer: any LinkSummarizing
    private let pdf = PDFExtractor()
    private var running = false
    private var active: (UUID, Task<UUID, any Error>)?

    init(
        store: DocumentStore,
        fetcher: any SourceFetching = SourceFetcher(),
        youtube: any YouTubeProviding = NativeYouTubeProvider(),
        transcriber: any AudioTranscribing = LocalTranscriber(),
        summarizer: any LinkSummarizing = AppleLinkSummarizer()
    ) {
        self.store = store
        self.fetcher = fetcher
        self.youtube = youtube
        self.transcriber = transcriber
        self.summarizer = summarizer
        artifacts = ArtifactStore(root: store.url.deletingLastPathComponent()
            .appending(path: "artifacts"))
    }

    func enqueue(_ input: String, deduplicate: Bool = true) async throws -> UUID {
        if let url = try CaptureRequest.classify(input) {
            let media = try MediaTarget.parse(url)
            let canonical = try CaptureRequest.canonicalURL(media?.url ?? url)
            guard let canonicalURL = URL(string: canonical) else { throw CaptureError.unsafeURL }
            return try await store.enqueueCapture(CaptureRequest(
                url: canonicalURL,
                identity: media?.identity ?? ("url:" + canonical),
                label: canonical
            ), deduplicate: deduplicate)
        }
        guard input.utf8.count <= CaptureLimits.markdownBytes else { throw CaptureError.tooLarge }
        let artifact = try await artifacts.retain(
            Data(input.utf8),
            kind: .markdown,
            name: "Pasted text.md"
        )
        return try await store.enqueueCapture(CaptureRequest(
            artifact: artifact,
            identity: "text:" + artifact.hash,
            label: Self.title(input)
        ), deduplicate: deduplicate)
    }

    func enqueueFile(_ url: URL) async throws -> UUID {
        let artifact = try await artifacts.retainFile(url)
        return try await store.enqueueCapture(CaptureRequest(
            artifact: artifact,
            identity: "file:" + artifact.hash,
            label: artifact.name
        ))
    }

    func run(changed: @escaping @Sendable () async -> Void = {}) async throws {
        guard !running else { return }
        running = true
        defer { running = false; active = nil }
        while !Task.isCancelled, let job = try await store.claimCapture() {
            let task = Task { try await self.process(job, changed: changed) }
            active = (job.id, task)
            await changed()
            do {
                _ = try await withTaskCancellationHandler { try await task.value } onCancel: {
                    task.cancel()
                }
            } catch is CancellationError {
                try await store.cancelCapture(job.id, token: job.token)
            } catch let error as MediaError {
                try await store.failCapture(
                    job,
                    error: error.localizedDescription,
                    recovery: error.recovery
                )
            } catch let error as LinkSummaryError {
                try await store.failCapture(job, error: error.localizedDescription)
            } catch let error as CaptureError {
                try await store.failCapture(job, error: error.localizedDescription)
            } catch {
                try await store.failCapture(
                    job,
                    error: CaptureError.extractionFailed.localizedDescription
                )
            }
            active = nil
            await changed()
        }
    }

    func cancel(_ id: UUID) async throws {
        try await store.cancelCapture(id)
        if active?.0 == id {
            active?.1.cancel()
        }
    }

    func summarizeExisting(_ document: MarkdownDocument) async throws -> MarkdownDocument {
        let source = try await store.summarySource(for: document)
        let summary = try await summarizer.summarize(source.document)
        try Task.checkCancellation()
        let artifact = try await artifacts.retain(
            Data(summary.utf8), kind: .markdown, name: "Summary.md",
            sourceURL: source.document.sourceURL
        )
        do {
            return try await store.publishSummary(
                summary,
                artifact: artifact,
                for: document,
                captureID: source.id
            )
        } catch {
            try? await store.queueArtifactCleanup(artifact)
            throw error
        }
    }

    private func process(
        _ job: CaptureJob,
        changed: @escaping @Sendable () async -> Void
    ) async throws -> UUID {
        var acquired = try await acquireOriginals(job, changed: changed)
        guard let primary = acquired.first else { throw CaptureError.missingArtifact }
        var document: CapturedDocument
        var faviconURL: URL?
        switch primary.kind {
        case .capture:
            document = try await JSONDecoder().decode(
                CapturedDocument.self,
                from: artifacts.data(for: primary)
            )
        case .audio:
            guard let url = job.request.url,
                  let target = try MediaTarget.parse(url) else { throw MediaError.invalidLink }
            acquired = try await transcribeAudio(
                target,
                job: job,
                acquired: acquired,
                changed: changed
            )
            guard let snapshot = acquired.first else { throw CaptureError.missingArtifact }
            document = try await JSONDecoder().decode(
                CapturedDocument.self,
                from: artifacts.data(for: snapshot)
            )
        case .json:
            throw CaptureError.unsupported
        case .pdf:
            document = try await extractPDF(primary, job: job, acquired: acquired, changed: changed)
        case .html:
            document = try await extractHTML(
                primary,
                job: job,
                acquired: &acquired,
                faviconURL: &faviconURL,
                changed: changed
            )
        case .text, .markdown:
            let text = try await Self.decodeText(
                artifacts.data(for: primary),
                encoding: primary.textEncoding
            )
            let title = job.request.identity.hasPrefix("text:") ? Self.title(text) : primary.name
            document = CapturedDocument(
                title: title,
                sourceURL: primary.sourceURL,
                coverage: .note,
                blocks: [ContentBlock(
                    kind: .paragraph,
                    markdown: text,
                    text: text,
                    method: primary.kind == .markdown ? "markdown" : "text"
                )]
            )
        }
        try Task.checkCancellation()
        try document.validate()
        let summary = try await summarize(
            job,
            document: document,
            acquired: &acquired,
            changed: changed
        )
        let favicon = await FaviconLoader(fetcher: fetcher).load(
            source: primary.sourceURL ?? document.sourceURL ?? job.request.url,
            preferred: faviconURL
        )
        try Task.checkCancellation()
        return try await store.publishCapture(
            job,
            document: document,
            artifacts: acquired,
            favicon: favicon,
            summary: summary
        )
    }

    private func summarize(
        _ job: CaptureJob,
        document: CapturedDocument,
        acquired: inout [Artifact],
        changed: @escaping @Sendable () async -> Void
    ) async throws -> String? {
        guard job.request.url != nil else { return nil }
        var summary: String?
        try await store.checkpoint(job, acquired: acquired, progress: "Writing a brief summary")
        await changed()
        do {
            summary = try await summarizer.summarize(document)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as LinkSummaryError {
            throw error
        } catch {
            throw LinkSummaryError.failed
        }
        guard let summary, !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              summary.utf8.count <= CaptureLimits.markdownBytes
        else {
            throw LinkSummaryError.failed
        }
        let artifact = try await artifacts.retain(
            Data(summary.utf8), kind: .markdown,
            name: "Summary.md", sourceURL: document.sourceURL ?? job.request.url
        )
        acquired.append(artifact)
        try await store.checkpoint(
            job,
            acquired: acquired,
            progress: "Summary retained locally"
        )
        return summary
    }

    private func acquireOriginals(
        _ job: CaptureJob,
        changed: @escaping @Sendable () async -> Void
    ) async throws -> [Artifact] {
        guard job.acquired.isEmpty else { return job.acquired }
        guard let url = job.request.url else { throw CaptureError.missingArtifact }
        let acquired: [Artifact] = if let target = try MediaTarget.parse(url) {
            try await acquireMedia(target, job: job, changed: changed)
        } else {
            try await [download(url)]
        }
        try await store.checkpoint(job, acquired: acquired, progress: "Original retained locally")
        await changed()
        return acquired
    }

    private func extractHTML(
        _ primary: Artifact, job: CaptureJob, acquired: inout [Artifact],
        faviconURL: inout URL?,
        changed: @escaping @Sendable () async -> Void
    ) async throws -> CapturedDocument {
        let data = try await artifacts.data(for: primary)
        let html = try Self.decodeText(data, encoding: primary.textEncoding, html: true)
        let analysis = try HTMLExtractor.analyze(html, url: primary.sourceURL)
        faviconURL = analysis.faviconURL
        guard let pdfURL = analysis.pdfURL else {
            return try await HTMLExtractor.extract(analysis, url: primary.sourceURL)
        }
        do {
            let pdfArtifact: Artifact
            if let retained = acquired.dropFirst().first(where: { $0.kind == .pdf }) {
                pdfArtifact = retained
            } else {
                pdfArtifact = try await download(pdfURL)
                guard pdfArtifact.kind == .pdf else { throw CaptureError.invalidPDF }
                acquired.append(pdfArtifact)
                try await store.checkpoint(
                    job,
                    acquired: acquired,
                    progress: "Full-text PDF retained locally"
                )
            }
            var document = try await extractPDF(
                pdfArtifact,
                job: job,
                acquired: acquired,
                changed: changed
            )
            if !analysis.title.isEmpty {
                document.title = analysis.title
            }
            if !analysis.authors.isEmpty {
                document.authors = analysis.authors
            }
            document.published = analysis.published
            document.identifier = analysis.identifier
            return document
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            var document = try await HTMLExtractor.extract(analysis, url: primary.sourceURL)
            document.coverage = analysis.academic ? .abstractOnly : .partial
            document.warnings
                .append(
                    "The linked full-text PDF could not be acquired or extracted. Only the landing-page text was captured."
                )
            return document
        }
    }

    private func download(_ url: URL) async throws -> Artifact {
        try Self.requireDocumentSource(url)
        let fetched = try await fetcher.fetch(url)
        try Self.requireDocumentSource(fetched.url)
        let kind = try ArtifactStore.kind(
            data: fetched.data,
            extension: fetched.url.pathExtension,
            mime: fetched.mime
        )
        var name = fetched.url.lastPathComponent
        if name.isEmpty {
            name = fetched.url.host ?? "Web capture"
        }
        return try await artifacts.retain(
            fetched.data,
            kind: kind,
            name: name,
            sourceURL: fetched.url,
            textEncoding: fetched.encoding
        )
    }

    private func extractPDF(
        _ artifact: Artifact,
        job: CaptureJob,
        acquired: [Artifact],
        changed: @escaping @Sendable () async -> Void
    ) async throws -> CapturedDocument {
        let data = try await artifacts.data(for: artifact)
        var document = try await pdf
            .extract(data, name: artifact.name, url: artifact.sourceURL) { [store] message in
                try await store.checkpoint(job, acquired: acquired, progress: message)
                await changed()
            }
        try document.validate()
        return document
    }

    private static func requireDocumentSource(_ url: URL) throws {
        guard try MediaTarget.parse(url) == nil else { throw CaptureError.unsupported }
    }

    private static func title(_ text: String) -> String {
        let first = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? "Untitled capture"
        let cleaned = first.trimmingCharacters(in: CharacterSet(charactersIn: "# ")).prefix(80)
        return cleaned.isEmpty ? "Untitled capture" : String(cleaned)
    }

    static func decodeText(
        _ data: Data,
        encoding name: String? = nil,
        html: Bool = false
    ) throws -> String {
        var encoding = name
        if encoding == nil, html {
            let prefix = String(decoding: data.prefix(4096), as: UTF8.self)
            if let match = prefix.range(
                of: #"charset\s*=\s*["']?([A-Za-z0-9_-]+)"#,
                options: [.regularExpression, .caseInsensitive]
            ) {
                encoding = prefix[match].split(separator: "=").last?
                    .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            }
        }
        if let encoding {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(encoding as CFString)
            if cfEncoding != kCFStringEncodingInvalidId,
               let text = String(
                   data: data,
                   encoding: String
                       .Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
               )
            {
                return text
            }
        }
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]), let text = String(
            data: data,
            encoding: .utf16
        ) {
            return text
        }
        guard let text = String(data: data, encoding: .utf8) else { throw CaptureError.unsupported }
        return text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
    }
}
