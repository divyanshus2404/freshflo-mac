import Foundation

/// Web search for commitments that need facts the notes don't have ("compare Postgres and Mongo for the Acme import"),
/// through Tavily's search API. Only the search question leaves the Mac, never the notes or transcript.
enum Tavily {
    struct Result: Equatable {
        let title: String
        let url: String
        let content: String
    }

    struct Response: Equatable {
        let answer: String?
        let results: [Result]
    }

    static let keychainAccount = "tavily"

    /// `TAVILY_API_KEY` (for the command line and agents) wins over the key saved in Settings.
    static var apiKey: String {
        let env = ProcessInfo.processInfo.environment["TAVILY_API_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return env.isEmpty ? Keychain.get(keychainAccount) : env
    }

    static var isConfigured: Bool { !apiKey.isEmpty }

    static func search(_ query: String, maxResults: Int = 5) async throws -> Response {
        guard isConfigured else { throw TavilyError.noKey }
        var req = URLRequest(url: URL(string: "https://api.tavily.com/search")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "query": query, "search_depth": "basic", "max_results": maxResults, "include_answer": true,
        ] as [String: Any])
        guard let response = parse(try await OpenAICompatible.send(req)) else { throw APIError.badResponse }
        return response
    }

    /// `{"answer": "…", "results": [{"title", "url", "content"}]}` → the answer and the pages it came from.
    static func parse(_ json: [String: Any]) -> Response? {
        guard let raw = json["results"] as? [[String: Any]] else { return nil }
        let results = raw.compactMap { r -> Result? in
            guard let url = r["url"] as? String, !url.isEmpty else { return nil }
            let title = (r["title"] as? String).flatMap { $0.isEmpty ? nil : $0 } ?? url
            return Result(title: title, url: url, content: String((r["content"] as? String ?? "").prefix(1_200)))
        }
        let answer = (json["answer"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return Response(answer: answer.flatMap { $0.isEmpty ? nil : $0 }, results: results)
    }
}

enum TavilyError: LocalizedError {
    case noKey

    var errorDescription: String? {
        "Research needs a Tavily API key: add one in Settings → Meetings, or set TAVILY_API_KEY."
    }
}
