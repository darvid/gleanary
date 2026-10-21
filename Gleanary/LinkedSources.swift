import Foundation

struct LinkedSourceLink: Identifiable, Sendable, Equatable {
    let id: String
    let url: URL
    var title: String

    /// Foundation's Markdown parser excludes code and resolves reference-style links.
    static func extract(from markdown: String) throws -> [LinkedSourceLink] {
        let text = try AttributedString(markdown: markdown)
        let detector = try NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)
        var links: [LinkedSourceLink] = []
        var previousLink: String?
        var previousIntent: PresentationIntent?
        for run in text.runs {
            let label = String(text[run.range].characters)
            if let url = run.link, let request = try? CaptureRequest.webLink(url) {
                if previousLink == request.identity, previousIntent == run.presentationIntent,
                   let index = links.indices.last,
                   links[index].id == request.identity
                {
                    links[index].title += label
                } else {
                    links.append(LinkedSourceLink(id: request.identity, url: url, title: label))
                }
                previousLink = request.identity
                previousIntent = run.presentationIntent
                continue
            }
            previousLink = nil
            guard run.inlinePresentationIntent?.contains(.code) != true,
                  run.presentationIntent?.components.contains(where: {
                      if case .codeBlock = $0.kind {
                          return true
                      }
                      return false
                  }) != true else { continue }
            for match in detector.matches(
                in: label,
                range: NSRange(label.startIndex..., in: label)
            ) {
                guard let url = match.url,
                      let request = try? CaptureRequest.webLink(url) else { continue }
                links.append(LinkedSourceLink(
                    id: request.identity,
                    url: url,
                    title: url.absoluteString
                ))
            }
        }
        return preferredTitles(in: links)
    }

    private static func preferredTitles(in occurrences: [LinkedSourceLink]) -> [LinkedSourceLink] {
        var links: [LinkedSourceLink] = []
        var indices: [String: Int] = [:]
        for link in occurrences {
            if let index = indices[link.id] {
                if titleRank(link.title) > titleRank(links[index].title) {
                    links[index].title = link.title
                }
            } else {
                indices[link.id] = links.count
                links.append(link)
            }
        }
        for index in links.indices where titleRank(links[index].title) == 0 {
            links[index].title = links[index].url.absoluteString
        }
        return links
    }

    private static func titleRank(_ title: String) -> Int {
        let label = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let marker = label.trimmingCharacters(in: CharacterSet(charactersIn: "[]()"))
        if label.isEmpty || marker.range(
            of: #"^(?:[Ss]\s*)?\d+(?:\s*[,–-]\s*\d+)*$"#,
            options: .regularExpression
        ) != nil {
            return 0
        }
        if let url = URL(string: label), ["http", "https"].contains(url.scheme?.lowercased()) {
            return 1
        }
        return 2
    }
}

struct LinkedSource: Identifiable, Sendable {
    let link: LinkedSourceLink
    var noteID: UUID?
    var archived = false
    var job: CaptureJob?
    var summaries: [DocumentSummary] = []

    var captureProgress: String? {
        guard let job else { return nil }
        switch job.state {
        case .queued: return "Queued"
        case .fetching: return "Fetching source…"
        case .extracting:
            let progress = job.progress.trimmingCharacters(in: .whitespacesAndNewlines)
            return progress.isEmpty ? "Extracting text…" : progress
        case .ready, .failed, .cancelled: return nil
        }
    }

    var id: String {
        link.id
    }

    var canAdd: Bool {
        noteID == nil && (job == nil || job?.state.terminal == true)
    }

    var retryID: UUID? {
        guard let job, job.state == .failed || job.state == .cancelled else { return nil }
        return job.id
    }
}
