import Foundation

/// Search and questions across your meeting notes and dictation history. Everything is read from this Mac;
/// only the few most relevant excerpts are sent to the model you already use for cleanup when you ask a question.
enum Knowledge {
    struct Hit {
        let meeting: Meeting
        let score: Double
    }

    private static let stop: Set<String> = ["the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "with", "is", "are", "was", "were",
                                            "what", "who", "when", "where", "why", "how", "did", "do", "does", "we", "i", "you", "it", "that",
                                            "this", "about", "my", "our", "me", "us", "any", "there", "be", "at", "from", "by", "last", "said"]

    static func terms(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init).filter { $0.count > 1 && !stop.contains($0) }
    }

    /// Keyword relevance (title counts most, then notes, then transcript) with a gentle preference for recent meetings.
    static func search(_ query: String, in meetings: [Meeting], limit: Int = 5) -> [Hit] {
        let q = Set(terms(query))
        let ready = meetings.filter { $0.status == .ready }
        guard !q.isEmpty else { return ready.prefix(limit).map { Hit(meeting: $0, score: 0) } }
        let now = Date()
        return ready.compactMap { m -> Hit? in
            func count(_ text: String) -> Double { Double(terms(text).filter(q.contains).count) }
            let raw = count(m.title) * 4 + count(m.notes) * 2 + count(m.transcript) * 0.5
            guard raw > 0 else { return nil }
            let days = max(0, now.timeIntervalSince(m.date) / 86_400)
            return Hit(meeting: m, score: raw * (1 + 1 / (1 + days / 14)))
        }
        .sorted { $0.score > $1.score }
        .prefix(limit).map { $0 }
    }

    static func search(_ query: String, in history: [HistoryItem], limit: Int = 10) -> [HistoryItem] {
        let q = Set(terms(query))
        guard !q.isEmpty else { return Array(history.prefix(limit)) }
        var scored: [(item: HistoryItem, score: Int)] = []
        for item in history {
            let score = terms(item.text).filter(q.contains).count
            if score > 0 { scored.append((item, score)) }
        }
        scored.sort { a, b in a.score == b.score ? a.item.date > b.item.date : a.score > b.score }
        return scored.prefix(limit).map { $0.item }
    }

    /// The parts of a transcript that mention the question's words, with a little surrounding context.
    static func excerpt(_ transcript: String, for query: String, maxChars: Int = 1_800) -> String {
        let q = Set(terms(query))
        let lines = transcript.components(separatedBy: "\n")
        var keep = IndexSet()
        for (i, line) in lines.enumerated() where !Set(terms(line)).isDisjoint(with: q) {
            keep.insert(integersIn: max(0, i - 1)...min(lines.count - 1, i + 1))
        }
        let picked = keep.map { lines[$0] }.joined(separator: "\n")
        return String(picked.prefix(maxChars))
    }

    static func label(_ m: Meeting) -> String {
        "\(m.title) (\(m.date.formatted(date: .abbreviated, time: .omitted)))"
    }

    struct Answer {
        let text: String
        let sources: [Meeting]
    }

    /// One exchange in a "Chat with your meetings" conversation.
    struct Turn: Identifiable, Hashable {
        let id = UUID()
        let question: String
        var answer: String
        var sources: [Meeting]
        var failed: Bool = false
    }

    /// Multi-turn chat over your meetings: like `ask`, but the model also sees the conversation so far, so
    /// follow-ups ("who owns that?", "and when is it due?") resolve against the earlier answers. Cited, local-first.
    static func converse(history: [Turn], question: String, meetings: [Meeting], settings: AppSettings) async throws -> Answer {
        // A follow-up may carry no keywords of its own, so retrieve on it plus the previous question.
        let retrievalQuery = ([question] + history.suffix(1).map(\.question)).joined(separator: " ")
        var hits = search(retrievalQuery, in: meetings, limit: 4).map(\.meeting)
        // Keep meetings cited in the last turn in view, so pronoun references still have their source.
        for m in history.last?.sources ?? [] where !hits.contains(where: { $0.id == m.id }) { hits.append(m) }
        if hits.isEmpty { hits = Array(meetings.filter { $0.status == .ready }.prefix(3)) }
        guard !hits.isEmpty else { return Answer(text: "You don't have any processed meeting notes yet.", sources: []) }

        var context = ""
        for m in hits.prefix(5) {
            context += "### \(label(m))\n\(m.notes.prefix(3_000))\n"
            let ex = excerpt(m.transcript, for: retrievalQuery)
            if !ex.isEmpty { context += "Transcript excerpts:\n\(ex)\n" }
            context += "\n"
        }

        let instructions = """
        You are a chat assistant answering questions about the user's own meetings, using only the notes and transcript \
        excerpts provided. You are in an ongoing conversation; use the earlier turns to resolve references like "that", \
        "they" or "it" in the latest question.
        Be direct and brief: one to four sentences, or a short list when there are several items (decisions, owners, dates).
        After each fact, name the meeting it came from in brackets, like [Pricing sync (Oct 3, 2026)].
        "You" in the notes and transcripts is the user, so "my action items" means only the items owned by You (or with no owner).
        If the answer isn't in the provided meetings, say you couldn't find it in the notes. Never guess or add outside knowledge.
        Today is \(Date().formatted(date: .complete, time: .omitted)).
        """
        var convo = ""
        for turn in history.suffix(6) {
            convo += "User: \(turn.question)\nAssistant: \(turn.answer)\n\n"
        }
        let prompt = "Meetings:\n\(context)\nConversation so far:\n\(convo)User: \(question)\nAssistant:"

        let reply: String
        if settings.canUseCloud {
            reply = try await Cleanup.chat(instructions: instructions, prompt: prompt, endpoint: settings.endpoint.smart, temperature: 0.2)
        } else if AppleModel.isAvailable {
            reply = try await AppleModel.respond(instructions: instructions, prompt: prompt)
        } else {
            throw KnowledgeError.noModel
        }
        let text = Cleanup.stripThinking(reply)
        let notFound = text.range(of: #"couldn['’]t find|could not find|not in the (?:provided )?notes"#, options: [.regularExpression, .caseInsensitive]) != nil
        let cited = hits.filter { text.contains($0.title) }
        return Answer(text: text, sources: notFound ? [] : (cited.isEmpty ? Array(hits.prefix(3)) : cited))
    }

    /// "What did we decide about pricing?" → an answer drawn only from your notes, naming the meetings it came from.
    static func ask(_ question: String, meetings: [Meeting], settings: AppSettings) async throws -> Answer {
        var hits = search(question, in: meetings, limit: 4).map(\.meeting)
        // Questions like "what happened this week" have no keywords: use the most recent meetings.
        if hits.isEmpty { hits = Array(meetings.filter { $0.status == .ready }.prefix(3)) }
        guard !hits.isEmpty else { return Answer(text: "You don't have any processed meeting notes yet.", sources: []) }
        var context = ""
        for m in hits {
            context += "### \(label(m))\n\(m.notes.prefix(3_000))\n"
            let ex = excerpt(m.transcript, for: question)
            if !ex.isEmpty { context += "Transcript excerpts:\n\(ex)\n" }
            context += "\n"
        }
        let instructions = """
        You answer questions about the user's own meetings using only the notes and transcript excerpts provided.
        Be direct and brief: one to four sentences, or a short list when there are several items (decisions, owners, dates).
        After each fact, name the meeting it came from in brackets, like [Pricing sync (Oct 3, 2026)].
        "You" in the notes and transcripts is the user, so "my action items" means only the items owned by You (or with no owner).
        If the answer isn't in the provided meetings, say you couldn't find it in the notes. Never guess or add outside knowledge.
        Today is \(Date().formatted(date: .complete, time: .omitted)).
        """
        let prompt = "Meetings:\n\(context)\nQuestion: \(question)"
        let reply: String
        if settings.canUseCloud {
            reply = try await Cleanup.chat(instructions: instructions, prompt: prompt, endpoint: settings.endpoint.smart, temperature: 0.2)
        } else if AppleModel.isAvailable {
            reply = try await AppleModel.respond(instructions: instructions, prompt: prompt)
        } else {
            throw KnowledgeError.noModel
        }
        let text = Cleanup.stripThinking(reply)
        let notFound = text.range(of: #"couldn['’]t find|could not find|not in the (?:provided )?notes"#, options: [.regularExpression, .caseInsensitive]) != nil
        let cited = hits.filter { text.contains($0.title) }
        return Answer(text: text, sources: notFound ? [] : (cited.isEmpty ? hits : cited))
    }
}

enum KnowledgeError: LocalizedError {
    case noModel
    var errorDescription: String? {
        "Asking needs a language model: add a Groq key in Settings, or use macOS 26 with Apple Intelligence on."
    }
}

// MARK: - MCP server

/// `Freshflo --mcp`: a Model Context Protocol server over stdio, so Claude Desktop, Claude Code, Cursor and other MCP clients
/// can search your meeting notes (and, if you allow it, your dictation history). Read-only and local: nothing leaves this Mac
/// except what the AI app you connected asks for.
enum MCPServer {
    static let protocolVersion = "2025-06-18"

    static func run() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        while let line = readLine(strippingNewline: true) {
            guard let data = line.data(using: .utf8),
                  let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let method = message["method"] as? String else { continue }
            let id = message["id"]
            // Notifications (no id) never get a reply.
            guard let id, !(id is NSNull) else { continue }
            let params = message["params"] as? [String: Any] ?? [:]
            do {
                let result = try handle(method: method, params: params)
                send(["jsonrpc": "2.0", "id": id, "result": result])
            } catch {
                send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": error.localizedDescription]])
            }
        }
        exit(0)
    }

    private struct Unknown: LocalizedError {
        let method: String
        var errorDescription: String? { "Unknown method \(method)" }
    }

    static func handle(method: String, params: [String: Any]) throws -> [String: Any] {
        switch method {
        case "initialize":
            let requested = params["protocolVersion"] as? String
            return [
                "protocolVersion": requested ?? protocolVersion,
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": "freshflo", "title": "Freshflo", "version": Updater.currentVersion],
                "instructions": "Freshflo is the user's Mac dictation app. Use these tools to look up their meeting notes (summaries, decisions, action items, who said what) and, if they allowed it, things they recently dictated.",
            ]
        case "ping":
            return [:]
        case "tools/list":
            return ["tools": tools()]
        case "tools/call":
            let name = params["name"] as? String ?? ""
            let args = params["arguments"] as? [String: Any] ?? [:]
            let (text, isError) = call(name, args)
            return ["content": [["type": "text", "text": text]], "isError": isError]
        default:
            throw Unknown(method: method)
        }
    }

    static var historyAllowed: Bool { AppSettings.shared.mcpShareHistory }

    static func tools() -> [[String: Any]] {
        var list: [[String: Any]] = [
            tool("search_meetings", "Search the user's meeting notes by keywords (people, topics, projects). Returns matching meetings with their notes.",
                 ["query": ["type": "string", "description": "Keywords to search for"], "limit": ["type": "integer", "description": "Max results (default 5)"]], required: ["query"]),
            tool("list_meetings", "List the user's most recent meetings (title, date, length, id).",
                 ["limit": ["type": "integer", "description": "How many (default 10)"]], required: []),
            tool("get_meeting", "Full notes and transcript of one meeting, by id from list_meetings or search_meetings.",
                 ["id": ["type": "string"], "include_transcript": ["type": "boolean", "description": "Include the full transcript (default false)"]], required: ["id"]),
        ]
        if historyAllowed {
            list.append(tool("search_dictations", "Search text the user recently dictated with Freshflo (messages, emails, prompts), newest first.",
                              ["query": ["type": "string", "description": "Keywords; empty for the most recent"], "limit": ["type": "integer"]], required: []))
        }
        return list
    }

    private static func tool(_ name: String, _ description: String, _ properties: [String: Any], required: [String]) -> [String: Any] {
        ["name": name, "description": description, "inputSchema": ["type": "object", "properties": properties, "required": required],
         "annotations": ["readOnlyHint": true, "openWorldHint": false]]
    }

    static func call(_ name: String, _ args: [String: Any]) -> (String, Bool) {
        let store = MeetingStore.shared
        store.reload()
        let limit = min(50, max(1, args["limit"] as? Int ?? 0))
        switch name {
        case "search_meetings":
            let query = args["query"] as? String ?? ""
            let hits = Knowledge.search(query, in: store.meetings, limit: args["limit"] == nil ? 5 : limit)
            guard !hits.isEmpty else { return ("No meetings match “\(query)”.", false) }
            return (hits.map { describe($0.meeting, notes: true) }.joined(separator: "\n\n---\n\n"), false)
        case "list_meetings":
            let items = store.meetings.prefix(args["limit"] == nil ? 10 : limit)
            guard !items.isEmpty else { return ("No meetings yet.", false) }
            return (items.map { describe($0, notes: false) }.joined(separator: "\n"), false)
        case "get_meeting":
            guard let id = args["id"] as? String, let m = store.meetings.first(where: { $0.id == id }) else { return ("No meeting with that id.", true) }
            var text = describe(m, notes: true)
            if args["include_transcript"] as? Bool == true, !m.transcript.isEmpty { text += "\n\nTranscript:\n" + m.transcript }
            return (text, false)
        case "search_dictations" where historyAllowed:
            let items = Knowledge.search(args["query"] as? String ?? "", in: HistoryStore.shared.items, limit: args["limit"] == nil ? 10 : limit)
            guard !items.isEmpty else { return ("Nothing found.", false) }
            return (items.map { "[\($0.date.formatted(date: .abbreviated, time: .shortened)) · \($0.appName)] \($0.text)" }.joined(separator: "\n"), false)
        default:
            return ("Unknown tool \(name).", true)
        }
    }

    private static func describe(_ m: Meeting, notes: Bool) -> String {
        let head = "\(m.title) — \(m.date.formatted(date: .abbreviated, time: .shortened)), \(Int(m.duration / 60)) min, id: \(m.id)"
        guard notes else { return "• " + head }
        return "## " + head + (m.status == .ready ? "\n" + m.notes : "\n(\(m.status.rawValue))")
    }

    private static func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object), let line = String(data: data, encoding: .utf8) else { return }
        FileHandle.standardOutput.write((line + "\n").data(using: .utf8)!)
    }

    // MARK: Connecting AI apps

    static var executablePath: String { Bundle.main.executablePath ?? "/Applications/Freshflo.app/Contents/MacOS/Freshflo" }

    /// Claude Desktop reads MCP servers from this file.
    static var claudeConfigURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Claude/claude_desktop_config.json")
    }
    static var cursorConfigURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".cursor/mcp.json") }

    static var configSnippet: String {
        """
        {
          "mcpServers": {
            "freshflo": { "command": "\(executablePath)", "args": ["--mcp"] }
          }
        }
        """
    }

    static func isConnected(_ url: URL) -> Bool {
        guard let data = try? Data(contentsOf: url), let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = json["mcpServers"] as? [String: Any] else { return false }
        return servers["freshflo"] != nil
    }

    /// Adds Freshflo to an MCP client's config file, keeping everything else in it.
    static func connect(_ url: URL) throws {
        var json: [String: Any] = [:]
        if let data = try? Data(contentsOf: url), !data.isEmpty {
            guard let existing = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw CocoaError(.fileReadCorruptFile) }
            json = existing
        }
        var servers = json["mcpServers"] as? [String: Any] ?? [:]
        servers["freshflo"] = ["command": executablePath, "args": ["--mcp"]]
        json["mcpServers"] = servers
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
    }

    static func disconnect(_ url: URL) throws {
        guard let data = try? Data(contentsOf: url), var json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var servers = json["mcpServers"] as? [String: Any] else { return }
        servers.removeValue(forKey: "freshflo")
        json["mcpServers"] = servers
        try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
    }
}
