import Foundation
import SwiftUI

/// `gleanary://entity/<id>?name=<name>`: opens Entities on one entity. The name lets Entities
/// find it by search, whichever page of the list it's on.
enum EntityLink {
    static func url(id: String, name: String) -> URL? {
        var components = URLComponents()
        components.scheme = "gleanary"
        components.host = "entity"
        components.path = "/" + id
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        return components.url
    }

    static func target(from url: URL) -> EntityFocus? {
        guard url.scheme == "gleanary", url.host == "entity",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else { return nil }
        let id = String(components.path.dropFirst())
        guard !id.isEmpty else { return nil }
        let name = components.queryItems?.first { $0.name == "name" }?.value ?? ""
        return EntityFocus(id: id, name: name)
    }
}

/// An entity to show in Entities; each request is distinct, so opening the same one twice works.
struct EntityFocus: Equatable, Sendable {
    let id: String
    let name: String
    var request = UUID()
}

/// An entity a note mentions, with every name it goes by in that note's text.
struct EntityLinkTarget: Equatable, Sendable {
    let id: String
    let name: String
    let names: [String]

    init(_ entity: EntitySummary) {
        id = entity.id
        name = entity.name
        var seen = Set<String>()
        // Longest first, so "Maggie Appleton" wins over a shorter alias inside it.
        names = ([entity.name] + entity.aliases.map(\.name))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 && seen.insert($0.lowercased()).inserted }
            .sorted { $0.count > $1.count }
    }
}

/// Links each entity's first mention in a note, as encyclopedias do: later mentions stay plain,
/// so the text doesn't turn into a wall of links. Only words already in the text are linked;
/// the text itself never changes.
enum EntityLinking {
    /// Which entities each block should link: every entity goes to the first linkable block
    /// that mentions it by any of its names.
    static func firstMentions(
        in blocks: [String],
        targets: [EntityLinkTarget],
        linkable: (String) -> Bool
    ) -> [Int: [EntityLinkTarget]] {
        var assigned: [Int: [EntityLinkTarget]] = [:]
        for target in targets {
            if let index = blocks.indices.first(where: { index in
                linkable(blocks[index]) && target.names
                    .contains { mention($0, in: blocks[index]) != nil }
            }) {
                assigned[index, default: []].append(target)
            }
        }
        return assigned
    }

    /// Links the first whole-word mention of each target, outside existing links and code.
    static func link(in text: inout AttributedString, targets: [EntityLinkTarget]) {
        for target in targets {
            let plain = String(text.characters)
            for name in target.names {
                guard let range = mention(name, in: plain),
                      let url = EntityLink.url(id: target.id, name: target.name)
                else { continue }
                // Both views count the same characters, so offsets carry across.
                let lower = text.characters.index(
                    text.startIndex, offsetBy: plain.distance(
                        from: plain.startIndex,
                        to: range.lowerBound
                    )
                )
                let upper = text.characters.index(
                    lower, offsetBy: plain.distance(from: range.lowerBound, to: range.upperBound)
                )
                let span = lower ..< upper
                let blocked = text[span].runs.contains { run in
                    run.link != nil || (run.inlinePresentationIntent ?? []).contains(.code)
                }
                guard !blocked else { continue }
                text[span].link = url
                break
            }
        }
    }

    /// The first case-insensitive, whole-word occurrence of `name`.
    static func mention(_ name: String, in text: String) -> Range<String.Index>? {
        var start = text.startIndex
        while let range = text.range(
            of: name, options: [.caseInsensitive, .diacriticInsensitive],
            range: start ..< text.endIndex
        ) {
            let before = range.lowerBound == text.startIndex ? nil
                : text[text.index(before: range.lowerBound)]
            let after = range.upperBound == text.endIndex ? nil : text[range.upperBound]
            if !(before?.isWordCharacter ?? false), !(after?.isWordCharacter ?? false) {
                return range
            }
            start = range.upperBound
        }
        return nil
    }
}

private extension Character {
    var isWordCharacter: Bool {
        isLetter || isNumber || self == "_"
    }
}

extension EnvironmentValues {
    /// Entities the open note mentions; the reader links each one's first mention.
    @Entry var entityLinks: [EntityLinkTarget] = []
}
