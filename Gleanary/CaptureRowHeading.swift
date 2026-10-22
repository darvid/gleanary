import Foundation
import SwiftUI

/// Presentation only: retain the submitted address for hover and copying.
struct CaptureRowPresentation: Sendable, Equatable {
    let title: String
    let hostname: String?
    let url: URL?

    init(_ job: CaptureJob) {
        let source = job.request.submittedURL ?? job.request.url
        url = source.flatMap {
            ["http", "https"].contains($0.scheme?.lowercased() ?? "") && $0.host() != nil ? $0 : nil
        }
        let host = url?.host().map { $0.hasPrefix("www.") ? String($0.dropFirst(4)) : $0 }
        let label = [job.savedTitle, job.request.label].compactMap { value -> String? in
            guard let text = value?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty else { return nil }
            if let address = URL(string: text),
               ["http", "https"].contains(address.scheme?.lowercased() ?? "")
            {
                return nil
            }
            return text == host ? nil : text
        }.first
        if let label {
            title = label
            hostname = host
        } else if let url, let host {
            title = host + Self.shortPath(url)
            hostname = nil // The fallback already names the host.
        } else {
            title = job.request.artifact?.name ?? "Untitled capture"
            hostname = nil
        }
    }

    private static func shortPath(_ url: URL) -> String {
        let segments = url.path.split(separator: "/")
        guard !segments.isEmpty else { return "" }
        let path = segments.count > 2
            ? "/\(segments[0])/…/\(segments[segments.count - 1])"
            : "/" + segments.joined(separator: "/")
        let singleLine = path.components(separatedBy: .whitespacesAndNewlines)
            .joined(separator: " ")
        guard singleLine.count > 72 else { return singleLine }
        return String(singleLine.prefix(35)) + "…" + String(singleLine.suffix(36))
    }
}

struct CaptureRowHeading: View {
    let presentation: CaptureRowPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(presentation.title).font(.headline).lineLimit(2)
                .multilineTextAlignment(.leading)
            if let hostname = presentation.hostname {
                Text(hostname).font(.caption).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .help(presentation.url?.absoluteString ?? presentation.title)
        .accessibilityElement(children: .combine)
    }
}
