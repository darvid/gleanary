import Foundation

/// SIWC may finish with an empty response.output. Collect completed items as they arrive,
/// but never release an answer until response.completed confirms the whole request succeeded.
struct WebResearchSSEDecoder {
    private var dataLines: [String] = []
    private var passages: [WebResearchResult.Passage] = []
    private var consultedURLs: [URL] = []
    private var searchCount = 0
    private var itemIDs = Set<String>()
    private(set) var progress: String?

    mutating func consume(_ line: String) throws -> WebResearchResult? {
        guard line.utf8.count <= 400_000 else { throw ChatGPTError.invalidStream }
        if line.hasPrefix("data:") {
            dataLines.append(String(line.dropFirst(5)).trimmingCharacters(in: .whitespaces))
            guard dataLines.reduce(0, { $0 + $1.utf8.count }) <= 400_000
            else { throw ChatGPTError.invalidStream }
            return nil
        }
        guard line.isEmpty, !dataLines.isEmpty else { return nil }
        let payload = dataLines.joined(separator: "\n")
        dataLines = []
        return try process(payload)
    }

    private mutating func process(_ payload: String) throws -> WebResearchResult? {
        guard payload != "[DONE]",
              let event = try JSONSerialization
              .jsonObject(with: Data(payload.utf8)) as? [String: Any],
              let type = event["type"] as? String
        else { throw ChatGPTError.invalidStream }
        switch type {
        case "response.web_search_call.in_progress", "response.web_search_call.searching":
            progress = "Searching the web…"
        case "response.web_search_call.completed":
            progress = "Reading web sources…"
        case "response.output_text.delta":
            progress = "Writing a cited answer…"
        case "response.output_item.done":
            guard let item = event["item"] as? [String: Any]
            else { throw ChatGPTError.invalidStream }
            try collect(item)
        case "response.completed":
            return try completed(event)
        case "response.failed", "error":
            let response = event["response"] as? [String: Any]
            let error = (response?["error"] as? [String: Any]) ??
                (event["error"] as? [String: Any]) ?? event
            throw ChatGPTError.apiError(error)
        case "response.incomplete":
            throw ChatGPTError.invalidStream
        default: break
        }
        return nil
    }

    private mutating func completed(_ event: [String: Any]) throws -> WebResearchResult {
        guard let response = event["response"] as? [String: Any],
              response["status"] as? String == "completed"
        else { throw ChatGPTError.invalidStream }
        for item in response["output"] as? [[String: Any]] ?? [] {
            try collect(item)
        }
        let result = WebResearchResult(
            passages: passages, consultedURLs: consultedURLs, searchCount: searchCount
        )
        _ = try result.markdown()
        return result
    }

    mutating func finish() throws -> WebResearchResult {
        if let result = try consume("") {
            return result
        }
        throw ChatGPTError.invalidStream
    }

    private mutating func collect(_ item: [String: Any]) throws {
        guard let type = item["type"] as? String else { throw ChatGPTError.invalidStream }
        guard ["web_search_call", "message"].contains(type) else { return }
        guard let id = item["id"] as? String, id.count <= 200,
              item["status"] as? String == "completed"
        else { throw ChatGPTError.invalidStream }
        guard itemIDs.insert(id).inserted else { return }
        guard itemIDs.count <= 128 else { throw ChatGPTError.invalidStream }
        if type == "web_search_call" {
            try collectSearch(item)
        } else {
            try collectMessage(item)
        }
    }

    private mutating func collectSearch(_ item: [String: Any]) throws {
        searchCount += 1
        guard searchCount <= 24 else { throw ChatGPTError.invalidStream }
        let action = item["action"] as? [String: Any]
        for source in action?["sources"] as? [[String: Any]] ?? [] {
            guard let value = source["url"] as? String,
                  let url = URL(string: value), WebResearchResult.safeURL(url)
            else { continue }
            if !consultedURLs.contains(url) {
                guard consultedURLs.count < 256 else { throw ChatGPTError.invalidStream }
                consultedURLs.append(url)
            }
        }
    }

    private mutating func collectMessage(_ item: [String: Any]) throws {
        guard let content = item["content"] as? [[String: Any]]
        else { throw ChatGPTError.invalidStream }
        for part in content where part["type"] as? String == "output_text" {
            guard let text = part["text"] as? String,
                  let annotations = part["annotations"] as? [[String: Any]]
            else { throw ChatGPTError.invalidStream }
            let citations = try annotations.filter { $0["type"] as? String == "url_citation" }.map {
                try citation($0)
            }
            passages.append(.init(text: text, citations: citations))
            guard passages.count <= 32,
                  passages.reduce(0, { $0 + $1.text.utf8.count }) <= 64000
            else { throw ChatGPTError.invalidStream }
        }
    }

    private func citation(_ annotation: [String: Any]) throws -> WebResearchResult.Citation {
        guard let start = annotation["start_index"] as? Int,
              let end = annotation["end_index"] as? Int,
              let title = annotation["title"] as? String,
              let value = annotation["url"] as? String, let url = URL(string: value),
              WebResearchResult.safeURL(url)
        else { throw ConversationError.uncitedWebResearch }
        return .init(startIndex: start, endIndex: end, title: title, url: url)
    }
}
