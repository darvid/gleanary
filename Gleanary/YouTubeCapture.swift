import Foundation
import SwiftSoup
@preconcurrency import YouTubeKit
import YouTubeTranscript

struct VideoAudioInfo: Codable, Sendable {
    let videoID: String
    let title: String
    let author: String
    let duration: Double
}

struct ResolvedAudio: Sendable {
    let url: URL
    let info: VideoAudioInfo
}

protocol YouTubeProviding: Sendable {
    func transcript(for target: MediaTarget) async throws -> VideoTranscript
    func audio(for target: MediaTarget) async throws -> ResolvedAudio
}

struct NativeYouTubeProvider: YouTubeProviding {
    func transcript(for target: MediaTarget) async throws -> VideoTranscript {
        do {
            let result: FetchedTranscript
            do { result = try await YouTubeTranscript.fetch(
                target.id,
                languages: Locale.preferredLanguages + ["en"]
            ) } catch let YouTubeTranscriptError.noTranscriptFound(_, _, available) {
                guard !available.isEmpty else { throw MediaError.noCaptions }
                result = try await YouTubeTranscript.fetch(target.id, languages: available)
            }
            try Task.checkCancellation()
            return VideoTranscript(
                videoID: result.videoId,
                title: result.video?.title ?? "",
                author: result.video?.author ?? "",
                language: result.language,
                generated: result.isGenerated,
                method: "youtube-captions/536cf88",
                segments: result.segments.map { TimedText(
                    text: $0.text,
                    start: $0.start,
                    duration: $0.duration
                ) }
            )
        } catch YouTubeTranscriptError.transcriptsDisabled { throw MediaError.noCaptions }
        catch YouTubeTranscriptError.emptyTranscript { throw MediaError.noCaptions }
        catch {
            try Task.checkCancellation()
            if let media = error as? MediaError {
                throw media
            }
            throw MediaError.blocked
        }
    }

    func audio(for target: MediaTarget) async throws -> ResolvedAudio {
        // YouTubeKit has age-gate fallback code. Only invoke it after a strict public-playability
        // check.
        let fetched = try await SourceFetcher(maximumBytes: 10_000_000).fetch(target.url)
        let info = try Self.publicVideoInfo(
            html: IngestionEngine.decodeText(fetched.data),
            target: target
        )
        guard info.duration > 0, info.duration <= 7200 else { throw MediaError.durationLimit }
        try Task.checkCancellation()
        let video = YouTube(
            videoID: target.id,
            useOAuth: false,
            allowOAuthCache: false,
            methods: [.local]
        )
        guard let stream = try await video.streams.filterAudioOnly()
            .filter({ $0.fileExtension == .m4a }).lowestAudioBitrateStream()
        else {
            throw MediaError.blocked
        }
        try Task.checkCancellation()
        let host = stream.url.host?.lowercased() ?? ""
        guard stream.url.scheme == "https",
              host.hasSuffix(".googlevideo.com") else { throw MediaError.blocked }
        return ResolvedAudio(url: stream.url, info: info)
    }

    static func publicVideoInfo(html: String, target: MediaTarget) throws -> VideoAudioInfo {
        let document = try SwiftSoup.parse(html)
        for script in try document.select("script").array() {
            let text = try script.html()
            guard let range = text.range(
                of: #"(?:var\s+)?ytInitialPlayerResponse\s*=\s*"#,
                options: .regularExpression
            ),
                let json = JSONAssignment.object(in: text[range.upperBound...]) else { continue }
            let player = try JSONDecoder().decode(Player.self, from: Data(json.utf8))
            guard player.playabilityStatus.status == "OK", let details = player.videoDetails,
                  details.videoId == target.id,
                  details.isLiveContent != true else { throw MediaError.blocked }
            return VideoAudioInfo(
                videoID: details.videoId,
                title: details.title,
                author: details.author,
                duration: Double(details.lengthSeconds) ?? 0
            )
        }
        throw MediaError.blocked
    }
}

private struct Player: Decodable {
    struct Status: Decodable { let status: String }
    struct Details: Decodable {
        let videoId: String
        let title: String
        let author: String
        let lengthSeconds: String
        let isLiveContent: Bool?
    }

    let playabilityStatus: Status
    let videoDetails: Details?
}

enum JSONAssignment {
    static func object(in input: Substring) -> String? {
        let text = input.drop(while: \.isWhitespace)
        guard text.first == "{" else { return nil }
        var depth = 0, quoted = false, escaped = false
        for index in text.indices {
            let character = text[index]
            if quoted {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    quoted = false
                }
            } else {
                if character == "\"" {
                    quoted = true
                } else if character == "{" {
                    depth += 1
                } else if character == "}" {
                    depth -= 1
                    if depth == 0 {
                        return String(text[...index])
                    }
                }
            }
        }
        return nil
    }
}
