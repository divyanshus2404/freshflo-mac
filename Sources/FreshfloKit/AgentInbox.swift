import Foundation

/// Something to do about a commitment: a follow-up email, a reminder, a research brief or a note. Nemotron drafts one
/// from inside the app, or an agent you connected (Hermes, Claude…) proposes one over MCP. Nothing is sent or created
/// until you approve it.
struct ActionProposal: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        case email, reminder, research, note

        var label: String {
            switch self {
            case .email: return "Follow-up email"
            case .reminder: return "Reminder"
            case .research: return "Research brief"
            case .note: return "Note"
            }
        }

        var icon: String {
            switch self {
            case .email: return "envelope"
            case .reminder: return "bell"
            case .research: return "magnifyingglass"
            case .note: return "note.text"
            }
        }

        /// What approving it does.
        var approveLabel: String {
            switch self {
            case .email: return "Open in Mail"
            case .reminder: return "Add to Reminders"
            case .research, .note: return "Copy"
            }
        }
    }

    var id = UUID().uuidString
    var kind: Kind
    var commitmentID: String
    var commitmentTask: String
    /// Email subject, reminder title or research question.
    var title: String
    /// Email body, reminder notes or the brief itself.
    var body: String = ""
    /// Email recipient(s), as the model or agent wrote them.
    var to: String = ""
    var due: Date?
    /// Web pages a research brief is based on.
    var sources: [String] = []
    /// Who drafted it: a model credit ("… · Nebius Token Factory") or the connected agent's name.
    var proposedBy: String
    var created = Date()
}

/// Proposals waiting for your approval, kept in one small file so the app and the MCP server (a separate process,
/// started by the agent) see the same list.
enum AgentInbox {
    static let limit = 50

    static var url: URL {
        MeetingStore.shared.root.deletingLastPathComponent().appendingPathComponent("agent-inbox.json")
    }

    static func load() -> [ActionProposal] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: url)).flatMap { try? decoder.decode([ActionProposal].self, from: $0) } ?? []
    }

    static func save(_ proposals: [ActionProposal]) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(Array(proposals.suffix(limit))) { try? data.write(to: url, options: .atomic) }
    }

    static func add(_ proposal: ActionProposal) {
        var all = load()
        // The same agent asking twice for the same thing replaces its earlier draft.
        all.removeAll { $0.commitmentID == proposal.commitmentID && $0.kind == proposal.kind && $0.proposedBy == proposal.proposedBy }
        all.append(proposal)
        save(all)
    }

    static func remove(_ id: String) {
        save(load().filter { $0.id != id })
    }
}
