import Foundation

/// An optional diagram in a hosted summary: a flowchart of steps or a sequence of messages
/// between participants. The model proposes labelled nodes and links that cite excerpts; the
/// app writes the Mermaid, so a diagram can't carry markup or syntax errors, and each link is
/// checked against its quotations like a takeaway.
struct SummaryDiagramProposal: Codable {
    enum Kind: String, Codable {
        case flowchart, sequence
    }

    struct Node: Codable {
        let id: String
        let label: String
    }

    struct Link: Codable {
        let from: String
        let to: String
        let label: String?
        let evidenceIDs: [String]
    }

    static let maximumNodes = 12
    static let maximumLinks = 16
    static let maximumLabel = 60

    let kind: Kind
    let nodes: [Node]
    let links: [Link]

    /// The diagram with its links' quotations, or nil when it breaks a rule. A bad diagram is
    /// left out rather than failing the summary.
    func anchored(in evidence: SummaryEvidence) -> SummaryDiagram? {
        func label(_ text: String) -> String? {
            let label = text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            return label.isEmpty || label.count > Self.maximumLabel ? nil : label
        }
        let labels = nodes.compactMap { label($0.label) }
        let ids = nodes.map(\.id)
        guard (2 ... Self.maximumNodes).contains(nodes.count), labels.count == nodes.count,
              Set(ids).count == ids.count, Set(labels).count == labels.count,
              (2 ... Self.maximumLinks).contains(links.count)
        else { return nil }
        var anchored: [SummaryDiagram.Link] = []
        for link in links {
            var seen = Set<String>()
            let evidenceIDs = link.evidenceIDs.filter { seen.insert($0).inserted }
            let linkLabel = link.label.flatMap { $0.isEmpty ? nil : label($0) }
            guard let from = ids.firstIndex(of: link.from), let to = ids.firstIndex(of: link.to),
                  from != to,
                  (1 ... EvidenceSummaryDraft.maximumEvidence).contains(evidenceIDs.count),
                  link.label.map({ $0.isEmpty || linkLabel != nil }) ?? true,
                  kind == .flowchart || linkLabel != nil,
                  let quotes = try? evidenceIDs.map(evidence.quote)
            else { return nil }
            anchored.append(.init(from: from, to: to, label: linkLabel, quotes: quotes))
        }
        let linked = Set(anchored.flatMap { [$0.from, $0.to] })
        guard linked.count == nodes.count else { return nil }
        return SummaryDiagram(kind: kind, nodes: labels, links: anchored)
    }

    static var jsonSchema: [String: Any] {
        let text: [String: Any] = ["type": "string", "maxLength": maximumLabel]
        let diagram: [String: Any] = [
            "type": "object",
            "properties": [
                "kind": ["type": "string", "enum": ["flowchart", "sequence"]],
                "nodes": [
                    "type": "array", "minItems": 2, "maxItems": maximumNodes,
                    "items": [
                        "type": "object",
                        "properties": ["id": ["type": "string", "maxLength": 12], "label": text],
                        "required": ["id", "label"],
                        "additionalProperties": false,
                    ],
                ],
                "links": [
                    "type": "array", "minItems": 2, "maxItems": maximumLinks,
                    "items": [
                        "type": "object",
                        "properties": [
                            "from": ["type": "string", "maxLength": 12],
                            "to": ["type": "string", "maxLength": 12],
                            "label": ["type": ["string", "null"], "maxLength": maximumLabel],
                            "evidenceIDs": [
                                "type": "array", "items": ["type": "string"], "minItems": 1,
                                "maxItems": EvidenceSummaryDraft.maximumEvidence,
                            ],
                        ],
                        "required": ["from", "to", "label", "evidenceIDs"],
                        "additionalProperties": false,
                    ],
                ],
            ],
            "required": ["kind", "nodes", "links"],
            "additionalProperties": false,
        ]
        return ["anyOf": [diagram, ["type": "null"]]]
    }

    static let rule = """
    Diagram: null unless the source explains a process, workflow, architecture, decision path, \
    cause-and-effect chain or exchange between parties, with at least three steps, that a \
    reader would follow more easily as a picture than as prose. Most sources need no diagram. \
    Use flowchart for steps, decisions and causes, and sequence for messages between \
    participants in order. Nodes are short plain-text labels naming each step or participant \
    as the source does, with short ids such as n1. Each link cites the excerpts that state \
    that connection; its label is optional in a flowchart, such as a decision's outcome, and \
    required in a sequence, naming the message. Draw only the structure the source states: \
    no steps, order or causes the cited excerpts don't give. At most \(maximumNodes) nodes.
    """
}

struct SummaryDiagram: Codable, Equatable {
    struct Link: Codable, Equatable {
        /// Indexes into `nodes`.
        let from: Int
        let to: Int
        let label: String?
        /// Exact source excerpts that together state this link.
        let quotes: [String]
    }

    let kind: SummaryDiagramProposal.Kind
    let nodes: [String]
    let links: [Link]

    /// Each link as a sentence the summary review can check against its quotations.
    var claims: [SummaryDraft.Point] {
        links.map { link in
            let from = "“\(nodes[link.from])”", to = "“\(nodes[link.to])”"
            let text = switch (kind, link.label) {
            case let (.sequence, label?): "\(from) sends “\(label)” to \(to)."
            case let (.flowchart, label?): "From \(from), “\(label)” leads to \(to)."
            default: "\(from) leads to \(to)."
            }
            return SummaryDraft.Point(text: text, quotes: link.quotes)
        }
    }

    var mermaid: String {
        switch kind {
        case .flowchart:
            (["flowchart TD"] + nodes.enumerated()
                .map { "  n\($0.offset)[\"\(Self.escaped($0.element))\"]" }
                + links.map { link in
                    let arrow = link.label.map { "-->|\"\(Self.escaped($0))\"|" } ?? "-->"
                    return "  n\(link.from) \(arrow) n\(link.to)"
                }).joined(separator: "\n")
        case .sequence:
            (["sequenceDiagram"] + nodes.enumerated()
                .map { "  participant p\($0.offset) as \(Self.escaped($0.element))" }
                + links.map { "  p\($0.from)->>p\($0.to): \(Self.escaped($0.label ?? ""))" })
                .joined(separator: "\n")
        }
    }

    /// Labels as Mermaid entity codes wherever a character could end the label or start
    /// syntax, a comment or a directive.
    static func escaped(_ label: String) -> String {
        label.reduce(into: "") { escaped, character in
            escaped += entities[character] ?? String(character)
        }
    }

    private static let entities: [Character: String] = [
        "#": "#35;", "\"": "#quot;", ";": "#59;", "%": "#37;", "<": "#lt;", ">": "#gt;",
        "|": "#124;", "`": "#96;", "\n": " ", "\r": " ",
    ]
}
