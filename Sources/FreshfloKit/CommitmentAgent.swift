import AppKit
import Foundation

/// "Next step" on a commitment: Nemotron reads the commitment and the meetings it came up in, then calls one tool:
/// draft a follow-up email, add a reminder, or research what the notes don't say (Tavily). The call becomes an
/// `ActionProposal` that you review; nothing is sent or created until you approve it.
enum CommitmentAgent {
    /// One function call from the model, arguments flattened to text.
    struct ToolCall: Equatable {
        let name: String
        let arguments: [String: String]
    }

    // MARK: Tools

    static func tools(research: Bool) -> [[String: Any]] {
        var list = [
            function("draft_email", "Draft a follow-up email from the user that moves this commitment forward: deliver what was promised, confirm a date, or ask for what's missing.",
                     ["to": string("Recipient name or email address as written in the notes; empty if unknown"),
                      "subject": string("Short subject line"),
                      "body": string("The email: greeting, 2–5 short sentences using only facts from the notes, sign-off without a name")],
                     required: ["subject", "body"]),
            function("add_reminder", "Add a reminder when the user simply has to do the task at a certain time (prepare, book, review, build).",
                     ["title": string("What to do, starting with a verb"),
                      "due_date": string("YYYY-MM-DD: the commitment's due date if it has one, else empty"),
                      "notes": string("One or two lines of context from the meeting")],
                     required: ["title"]),
        ]
        if research {
            list.append(function("research", "Search the web when finishing the commitment needs facts that are not in the notes: prices, comparisons, specifications, how-tos.",
                                 ["query": string("A focused web search query"), "why": string("What the user needs to find out, in one sentence")],
                                 required: ["query"]))
        }
        return list
    }

    private static func function(_ name: String, _ description: String, _ properties: [String: Any], required: [String]) -> [String: Any] {
        ["type": "function", "function": ["name": name, "description": description,
                                          "parameters": ["type": "object", "properties": properties, "required": required]]]
    }

    private static func string(_ description: String) -> [String: Any] { ["type": "string", "description": description] }

    static func instructions(research: Bool, today: Date = Date()) -> String {
        """
        You help the user keep a commitment they made in a meeting. Choose the single most useful next step and call exactly one tool:
        - draft_email when the commitment is owed to someone (send, share, reply, follow up, confirm).
        - add_reminder when the user just has to do it at a certain time.\(research ? "\n- research when finishing it needs facts that are not in the notes." : "")
        "You" in the notes and transcript is the user. Use only facts from the meetings below; never invent names, numbers, prices or dates.
        Today is \(today.formatted(date: .complete, time: .omitted)).
        """
    }

    /// The commitment, the meeting it was made in (notes plus the transcript lines that mention it) and later mentions.
    static func prompt(for item: Commitments.Item, meetings: [Meeting]) -> String {
        var text = "Commitment: \(item.task)\nOwner: \(item.owner.isEmpty ? "nobody named" : item.owner)\n"
        if let due = item.dueDate { text += "Due: \(due.formatted(date: .complete, time: .omitted))\(item.due.isEmpty ? "" : " (\"\(item.due)\")")\n" }
        else if !item.due.isEmpty { text += "Due: \(item.due)\n" }
        if let source = meetings.first(where: { $0.id == item.meetingID }) {
            text += "\n### \(Knowledge.label(source)), where it was agreed\n\(source.notes.prefix(3_000))\n"
            let lines = Knowledge.excerpt(source.transcript, for: item.task, maxChars: 1_500)
            if !lines.isEmpty { text += "Transcript lines about it:\n\(lines)\n" }
        }
        for title in item.alsoIn {
            guard let later = meetings.first(where: { $0.title == title }) else { continue }
            text += "\n### \(Knowledge.label(later)), where it came up again\n\(later.notes.prefix(1_200))\n"
        }
        return text
    }

    // MARK: Asking the model

    /// Asks the model for the next step and returns it as a proposal (not yet run). Research is done before returning,
    /// so a research proposal arrives with its brief.
    static func propose(_ item: Commitments.Item, meetings: [Meeting], settings: AppSettings) async throws -> ActionProposal {
        guard settings.canUseCloud else { throw CommitmentAgentError.needsCloud }
        let research = Tavily.isConfigured
        var endpoint = settings.endpoint.smart
        let messages: [[String: Any]] = [
            ["role": "system", "content": instructions(research: research)],
            ["role": "user", "content": prompt(for: item, meetings: meetings)],
        ]
        let message: [String: Any]
        do {
            message = try await complete(messages, tools: tools(research: research), endpoint: endpoint)
        } catch where ModelResolver.isModelMissing(error) {
            guard let model = await ModelResolver.best(.chat, endpoint: endpoint), model != endpoint.cleanupModel else { throw error }
            ModelResolver.onResolved?(.chat, endpoint.cleanupModel, model)
            endpoint.cleanupModel = model
            message = try await complete(messages, tools: tools(research: research), endpoint: endpoint)
        }
        let credit = ModelCredit.label(model: endpoint.cleanupModel, baseURL: endpoint.baseURL)
        guard let call = toolCall(from: message), var proposal = proposal(call, item: item, by: credit) else {
            // No usable tool call: keep what the model said as a note rather than failing.
            let said = Cleanup.stripThinking(message["content"] as? String ?? "")
            guard !said.isEmpty else { throw APIError.badResponse }
            return ActionProposal(kind: .note, commitmentID: item.id, commitmentTask: item.task, title: "Next step: \(item.task)", body: said, proposedBy: credit)
        }
        if proposal.kind == .research { proposal = try await brief(proposal, item: item, settings: settings) }
        return proposal
    }

    private static func complete(_ messages: [[String: Any]], tools: [[String: Any]], endpoint: ProviderEndpoint) async throws -> [String: Any] {
        var req = try OpenAICompatible.request(endpoint, path: "/chat/completions")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 90
        req.httpBody = try JSONSerialization.data(withJSONObject: [
            "model": endpoint.cleanupModel, "temperature": 0.2, "messages": messages, "tools": tools, "tool_choice": "auto",
        ] as [String: Any])
        let json = try await OpenAICompatible.send(req)
        guard let message = (json["choices"] as? [[String: Any]])?.first?["message"] as? [String: Any] else { throw APIError.badResponse }
        Cleanup.lastModel = endpoint.cleanupModel
        return message
    }

    /// Turns a research proposal's question into a cited brief: Tavily finds pages, Nemotron writes from them only.
    static func brief(_ proposal: ActionProposal, item: Commitments.Item, settings: AppSettings) async throws -> ActionProposal {
        let found = try await Tavily.search(proposal.title)
        let pages = Array(found.results.prefix(5))
        var sources = ""
        for (i, page) in pages.enumerated() { sources += "[\(i + 1)] \(page.title) (\(page.url))\n\(page.content)\n\n" }
        let instructions = """
        Write a short research brief that helps the user finish their commitment: 3–6 bullet points starting with "- ", \
        facts only from the sources, each bullet ending with its source number like [2]. Then one line starting with "Next step:". \
        If the sources don't answer the question, say so in one line. No preamble.
        """
        let prompt = "Commitment: \(item.task)\nQuestion: \(proposal.title)\(proposal.body.isEmpty ? "" : "\nWhy: \(proposal.body)")\n"
            + (found.answer.map { "Search summary: \($0)\n" } ?? "") + "\nSources:\n\(sources)"
        let text = Cleanup.stripThinking(try await Cleanup.chat(instructions: instructions, prompt: prompt, endpoint: settings.endpoint.smart, temperature: 0.2))
        var out = proposal
        out.body = text
        out.sources = pages.map(\.url)
        out.proposedBy = proposal.proposedBy + " + Tavily"
        return out
    }

    // MARK: Reading the reply

    /// The model's tool call: OpenAI-style `tool_calls`, or, from servers without a tool parser, the call written as text
    /// (Nemotron's `<TOOLCALL>[{"name": …, "arguments": {…}}]</TOOLCALL>`, or bare JSON).
    static func toolCall(from message: [String: Any]) -> ToolCall? {
        if let calls = message["tool_calls"] as? [[String: Any]], let fn = calls.first?["function"] as? [String: Any], let name = fn["name"] as? String {
            return ToolCall(name: name, arguments: arguments(fn["arguments"]))
        }
        guard let content = message["content"] as? String else { return nil }
        return toolCall(inText: Cleanup.stripThinking(content))
    }

    static func toolCall(inText text: String) -> ToolCall? {
        guard let start = text.firstIndex(where: { $0 == "{" || $0 == "[" }),
              let end = text.lastIndex(where: { $0 == "}" || $0 == "]" }), start < end,
              let parsed = try? JSONSerialization.jsonObject(with: Data(text[start...end].utf8)),
              let object = (parsed as? [[String: Any]])?.first ?? (parsed as? [String: Any]) else { return nil }
        let fn = object["function"] as? [String: Any] ?? object
        guard let name = fn["name"] as? String ?? fn["tool"] as? String else { return nil }
        return ToolCall(name: name, arguments: arguments(fn["arguments"] ?? fn["parameters"]))
    }

    /// Arguments arrive as a JSON string (OpenAI) or an object (text calls).
    static func arguments(_ raw: Any?) -> [String: String] {
        var dict = raw as? [String: Any]
        if dict == nil, let s = raw as? String { dict = (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? [String: Any] }
        var out: [String: String] = [:]
        for (key, value) in dict ?? [:] where !(value is NSNull) { out[key] = value as? String ?? "\(value)" }
        return out
    }

    static func proposal(_ call: ToolCall, item: Commitments.Item, by credit: String) -> ActionProposal? {
        func arg(_ key: String) -> String { (call.arguments[key] ?? "").trimmingCharacters(in: .whitespacesAndNewlines) }
        switch call.name {
        case "draft_email":
            guard !arg("body").isEmpty else { return nil }
            return ActionProposal(kind: .email, commitmentID: item.id, commitmentTask: item.task, title: arg("subject").isEmpty ? item.task : arg("subject"),
                                  body: arg("body"), to: arg("to"), proposedBy: credit)
        case "add_reminder":
            return ActionProposal(kind: .reminder, commitmentID: item.id, commitmentTask: item.task, title: arg("title").isEmpty ? item.task : arg("title"),
                                  body: arg("notes"), due: Commitments.isoDay(arg("due_date")) ?? item.dueDate, proposedBy: credit)
        case "research":
            guard !arg("query").isEmpty else { return nil }
            return ActionProposal(kind: .research, commitmentID: item.id, commitmentTask: item.task, title: arg("query"), body: arg("why"), proposedBy: credit)
        default:
            return nil
        }
    }
}

enum CommitmentAgentError: LocalizedError {
    case needsCloud

    var errorDescription: String? {
        "Next step needs a cloud model with tool calling: pick Nebius Token Factory (NVIDIA Nemotron) in Settings and add a key."
    }
}

/// Runs an approved proposal with the Mac's own apps: Mail opens a draft (you press Send), Reminders gets the reminder.
@MainActor
enum ActionRunner {
    static func approve(_ proposal: ActionProposal) async throws -> String {
        switch proposal.kind {
        case .email:
            LocalActions.composeEmail(to: proposal.to, subject: proposal.title, body: proposal.body)
            return "Opened in Mail. Check it and press Send."
        case .reminder:
            // A date-only due gets a 9 am alarm, not midnight.
            let due = proposal.due.map { Calendar.current.date(bySettingHour: 9, minute: 0, second: 0, of: $0) ?? $0 }
            try await LocalActions.addReminder(title: proposal.title, due: due, notes: proposal.body.isEmpty ? nil : proposal.body)
            return "Added to Reminders."
        case .research, .note:
            var text = proposal.title + "\n\n" + proposal.body
            if !proposal.sources.isEmpty { text += "\n\nSources:\n" + proposal.sources.enumerated().map { "[\($0.offset + 1)] \($0.element)" }.joined(separator: "\n") }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            return "Copied to the clipboard."
        }
    }
}
