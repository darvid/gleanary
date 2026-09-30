import Foundation
import NaturalLanguage

enum MarkdownChunker {
    /// Bump when extraction, segmentation, or the input to the model changes.
    static let version = "markdown-and-source-blocks-80-v4"

    /// Lightweight Markdown extraction, not a full Markdown parser.
    static func chunks(_ markdown: String, wordLimit: Int = 80) -> [String] {
        guard wordLimit > 0 else { return [] }
        let plain = markdown
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(
                of: "(?m)^[ \\t]*```[^\\n]*$",
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "!?\\[([^\\]]+)\\]\\([^)]*\\)",
                with: "$1",
                options: .regularExpression
            )
            .replacingOccurrences(
                of: "(?m)^[ \\t]{0,3}(#{1,6}[ \\t]+|>[ \\t]*|[-*+][ \\t]+)",
                with: "",
                options: .regularExpression
            )
            .replacingOccurrences(of: "[*_`~]", with: "", options: .regularExpression)
        return plainChunks(plain, wordLimit: wordLimit)
    }

    /// Structured extractors already return plain text; do not strip meaningful code/math symbols.
    static func plainChunks(_ plain: String, wordLimit: Int = 80) -> [String] {
        guard wordLimit > 0 else { return [] }
        var result: [String] = []
        let tokenizer = NLTokenizer(unit: .sentence)
        for paragraph in plain.components(separatedBy: "\n\n") {
            tokenizer.string = paragraph
            var words: [Substring] = []
            tokenizer.enumerateTokens(in: paragraph.startIndex ..< paragraph.endIndex) { range, _ in
                let sentence = paragraph[range].split(whereSeparator: \.isWhitespace)
                if words.count + sentence.count > wordLimit, !words.isEmpty {
                    result.append(words.joined(separator: " "))
                    words.removeAll()
                }
                for word in sentence {
                    words.append(word)
                    if words.count == wordLimit {
                        result.append(words.joined(separator: " "))
                        words.removeAll()
                    }
                }
                return true
            }
            if !words.isEmpty {
                result.append(words.joined(separator: " "))
            }
        }
        return result
    }
}

/// Quote every FTS term rather than accepting operators or raw MATCH syntax.
/// Quoted input is preserved as a phrase; other terms are combined with OR.
enum KeywordQuery {
    static func pattern(_ query: String) -> String? {
        let expressions = query.matches(of: /"([^"\n]+)"|[\p{L}\p{N}_]+/)
        let terms = expressions.prefix(64).map { match in
            let text = match.output.1.map(String.init) ?? String(match.output.0)
            return "\"\(text.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
        return terms.isEmpty ? nil : terms.joined(separator: " OR ")
    }
}
