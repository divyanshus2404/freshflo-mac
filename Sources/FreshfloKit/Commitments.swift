import CryptoKit
import Foundation

/// Open commitments: every action item from every meeting in one list. Items are read from each meeting's notes on this
/// Mac; a model then merges the same commitment raised in several meetings, turns "by Friday" into a date relative to the
/// meeting it was said in, and checks later meetings for items already done.
enum Commitments {
    struct Item: Identifiable, Hashable, Codable {
        /// Meeting id + task, so a tick survives re-reading the notes.
        let id: String
        var task: String
        /// "You", a name, or "" when nobody was named.
        var owner: String
        /// As written in the notes: "by Friday", "today", "".
        var due: String
        var dueDate: Date?
        let meetingID: String
        let meetingTitle: String
        let meetingDate: Date
        /// Why it counts as done: ticked in the notes, or what a later meeting said.
        var doneNote: String?
        /// Other meetings the same commitment came up in.
        var alsoIn: [String] = []

        var isMine: Bool { owner.isEmpty || owner == "You" }
    }

    enum Bucket: Int, CaseIterable, Identifiable {
        case overdue, thisWeek, later, noDate, done
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .overdue: return "Overdue"
            case .thisWeek: return "Due this week"
            case .later: return "Later"
            case .noDate: return "No date"
            case .done: return "Done"
            }
        }
    }

    static func bucket(_ item: Item, ticked: Bool, today: Date = Date()) -> Bucket {
        if ticked || item.doneNote != nil { return .done }
        guard let due = item.dueDate else { return .noDate }
        let start = Calendar.current.startOfDay(for: today)
        if due < start { return .overdue }
        return due < start.addingTimeInterval(7 * 86_400) ? .thisWeek : .later
    }

    // MARK: Reading the notes

    private static let trailingDue = try! NSRegularExpression(
        pattern: #"(?i)[,;]?\s+((?:by|before|due|until)\s+[\w ]+?|today|tonight|tomorrow|this week|next week)\.?$"#)

    /// The "## Action items" checklist of one meeting. Understands "- [ ] task — owner, due" and the older "- Owner: task by Friday".
    static func parse(_ meeting: Meeting) -> [Item] {
        var items: [Item] = []
        var inSection = false
        for line in meeting.notes.components(separatedBy: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") { inSection = t.lowercased().contains("action item"); continue }
            guard inSection, t.hasPrefix("- ") || t.hasPrefix("* ") else { continue }
            var body = String(t.dropFirst(2))
            var ticked = false
            if body.hasPrefix("[ ] ") { body.removeFirst(4) } else if body.lowercased().hasPrefix("[x] ") { body.removeFirst(4); ticked = true }
            var task = body, owner = "", due = ""
            if let dash = body.range(of: " — ", options: .backwards) ?? body.range(of: " – ", options: .backwards) {
                task = String(body[..<dash.lowerBound])
                let meta = body[dash.upperBound...].split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                owner = meta.first ?? ""
                due = meta.count > 1 ? meta[1] : ""
            } else if let colon = body.firstIndex(of: ":"), body[..<colon].split(separator: " ").count <= 3 {
                owner = String(body[..<colon])
                task = String(body[body.index(after: colon)...])
            }
            owner = owner.replacingOccurrences(of: #"(?i)^owner:\s*"#, with: "", options: .regularExpression).trimmingCharacters(in: .whitespaces)
            if ["none", "unassigned", "n/a", "-", "—", "tbd"].contains(owner.lowercased()) { owner = "" }
            // The owner slot sometimes holds only the date: "— by Friday".
            if due.isEmpty, owner.range(of: #"(?i)^(by|before|due|until)\b|^(today|tomorrow)$"#, options: .regularExpression) != nil { due = owner; owner = "" }
            task = task.trimmingCharacters(in: .whitespaces)
            if due.isEmpty, let match = trailingDue.firstMatch(in: task, range: NSRange(task.startIndex..., in: task)),
               let whole = Range(match.range, in: task), let phrase = Range(match.range(at: 1), in: task) {
                due = String(task[phrase])
                task = String(task[..<whole.lowerBound])
            }
            task = task.trimmingCharacters(in: CharacterSet(charactersIn: " .")).trimmingCharacters(in: .whitespaces)
            guard !task.isEmpty else { continue }
            items.append(Item(id: meeting.id + "|" + task.lowercased(), task: task, owner: owner, due: due,
                              dueDate: resolveDue(due, from: meeting.date), meetingID: meeting.id, meetingTitle: meeting.title,
                              meetingDate: meeting.date, doneNote: ticked ? "Ticked in the notes" : nil))
        }
        return items
    }

    static func parse(_ meetings: [Meeting]) -> [Item] {
        meetings.filter { $0.status == .ready }.sorted { $0.date > $1.date }.flatMap(parse)
    }

    private static let weekdays = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"]

    /// "by Friday" said in a meeting on Tuesday → that Friday. Only plain phrases; anything vaguer stays undated
    /// (the model can still date it).
    static func resolveDue(_ text: String, from date: Date) -> Date? {
        let cal = Calendar.current
        var s = text.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        s = s.replacingOccurrences(of: #"^(by|before|due|until|on)\s+"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"^(the\s+)?end of\s+(the\s+)?"#, with: "end of ", options: .regularExpression)
        let day = cal.startOfDay(for: date)
        func after(_ weekday: Int, from start: Date) -> Date? {
            cal.nextDate(after: start, matching: DateComponents(weekday: weekday), matchingPolicy: .nextTime).map(cal.startOfDay)
        }
        switch s {
        case "today", "tonight", "eod", "end of day": return day
        case "tomorrow": return cal.date(byAdding: .day, value: 1, to: day)
        case "this week", "end of week", "end of this week": return after(6, from: cal.date(byAdding: .day, value: -1, to: day)!)
        case "next week": return after(6, from: cal.date(byAdding: .day, value: 6, to: day)!)
        case "end of month", "end of this month", "month end":
            return cal.dateInterval(of: .month, for: day).flatMap { cal.date(byAdding: .day, value: -1, to: $0.end) }.map(cal.startOfDay)
        default: break
        }
        let next = s.hasPrefix("next ")
        let name = next ? String(s.dropFirst(5)) : s
        if let index = weekdays.firstIndex(of: name), let first = after(index + 1, from: day) {
            return next ? cal.date(byAdding: .day, value: 7, to: first) : first
        }
        return isoDay(s)
    }

    static func isoDay(_ s: String) -> Date? {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: s.trimmingCharacters(in: .whitespaces))
    }

    private static func isoString(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private static func day(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd, EEEE"
        return f.string(from: date)
    }

    // MARK: Organising with a model

    /// Sends the parsed items and the meetings' notes to the model and applies what comes back. Anything the reply
    /// leaves out is kept as parsed, so a sloppy reply can merge or date items but never lose one.
    @MainActor
    static func organize(_ items: [Item], meetings: [Meeting], settings: AppSettings) async throws -> (items: [Item], model: String) {
        guard !items.isEmpty else { return (items, "") }
        let instructions = """
        You organise the user's commitments from their meeting notes. "You" is the user.
        You get numbered action items, each from one meeting, then the notes of every meeting in date order.
        Return only JSON, no prose: {"items":[{"ids":[numbers],"task":"…","owner":"…","due":"YYYY-MM-DD" or null,"done":"…" or null}]}
        - Merge items that are the same commitment raised in more than one meeting, including a later meeting restating it ("I still owe them the quote"): list all their ids, and keep the latest wording and owner.
        - "due": when an item's due date is given in brackets, copy it exactly. Otherwise give a date only if the wording names one clearly, relative to the meeting it was set in; else null. Never guess.
        - Set "done" only if a LATER meeting clearly says the item was finished, shipped, sent or reported back on (e.g. "I scoped it: about three weeks"): a short reason naming who said so and the meeting in brackets, like "Priya said the page went live [Weekly standup]". Saying it slipped or is still owed is not done.
        - Keep owners exactly as written ("You", names). Include every id exactly once. Never invent items, owners or dates.
        Today is \(day(Date())).
        """
        var prompt = "Action items:\n"
        for (i, item) in items.enumerated() {
            let due = item.due.isEmpty ? "none" : item.due + (item.dueDate.map { " (\(isoString($0)))" } ?? "")
            prompt += "\(i). \(item.task) | owner: \(item.owner.isEmpty ? "none" : item.owner) | due: \(due)"
            prompt += " | from: \(item.meetingTitle) (\(day(item.meetingDate)))\n"
        }
        prompt += "\nMeetings, oldest first:\n"
        for m in meetings.filter({ $0.status == .ready }).sorted(by: { $0.date < $1.date }).suffix(12) {
            prompt += "### \(m.title) (\(day(m.date)))\n\(m.notes.prefix(2_500))\n\n"
        }

        let reply: String
        let model: String
        if settings.canUseCloud {
            let endpoint = settings.endpoint.smart
            reply = try await Cleanup.chat(instructions: instructions, prompt: prompt, endpoint: endpoint, temperature: 0.1)
            model = ModelCredit.label(model: Cleanup.lastModel ?? endpoint.cleanupModel, baseURL: endpoint.baseURL)
        } else if AppleModel.isAvailable {
            reply = try await AppleModel.respond(instructions: instructions, prompt: prompt)
            model = ModelCredit.appleOnDevice
        } else {
            throw KnowledgeError.noModel
        }
        guard let organized = apply(Cleanup.stripThinking(reply), to: items) else { throw APIError.badResponse }
        return (organized, model)
    }

    /// Applies the model's JSON to the parsed items. nil when the reply isn't the JSON that was asked for.
    static func apply(_ reply: String, to items: [Item]) -> [Item]? {
        guard let start = reply.firstIndex(of: "{"), let end = reply.lastIndex(of: "}"), start < end,
              let data = String(reply[start...end]).data(using: .utf8),
              let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let entries = json["items"] as? [[String: Any]] else { return nil }
        var used = Set<Int>()
        var result: [Item] = []
        for entry in entries {
            let ids = ((entry["ids"] as? [Any]) ?? []).compactMap { ($0 as? Int) ?? ($0 as? String).flatMap(Int.init) }
                .filter { items.indices.contains($0) && !used.contains($0) }
            // The newest mention carries the current wording, owner and source meeting.
            guard let baseIndex = ids.max(by: { items[$0].meetingDate < items[$1].meetingDate }) else { continue }
            used.formUnion(ids)
            var item = items[baseIndex]
            if let task = entry["task"] as? String, !task.trimmingCharacters(in: .whitespaces).isEmpty { item.task = task }
            if let owner = entry["owner"] as? String {
                item.owner = ["none", "unassigned", "null"].contains(owner.lowercased()) ? "" : owner
            }
            // Dates resolved on this Mac are exact; the model only fills in ones the wording didn't make plain.
            // A merged item keeps the earliest date any mention set.
            item.dueDate = ids.compactMap { items[$0].dueDate }.min() ?? (entry["due"] as? String).flatMap(isoDay)
            if let done = entry["done"] as? String, !done.trimmingCharacters(in: .whitespaces).isEmpty, done.lowercased() != "null" {
                item.doneNote = done
            }
            item.alsoIn = ids.filter { $0 != baseIndex }.map { items[$0].meetingTitle }
                .filter { $0 != item.meetingTitle }.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
            if items[baseIndex].doneNote != nil, item.doneNote == nil { item.doneNote = items[baseIndex].doneNote }
            result.append(item)
        }
        guard !result.isEmpty else { return nil }
        result += items.indices.filter { !used.contains($0) }.map { items[$0] }
        return result
    }

    // MARK: Ticks and cache

    private static let tickedKey = "commitmentsTicked"

    static var ticked: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: tickedKey) ?? []) }
        set { UserDefaults.standard.set(Array(newValue).sorted(), forKey: tickedKey) }
    }

    /// The last organised list, reused while the meetings' notes haven't changed.
    @MainActor static var cache: (key: String, items: [Item], model: String)?

    /// Same notes, same key, in every process: the MCP server reads the list the app organised.
    static func cacheKey(_ meetings: [Meeting]) -> String {
        var text = ""
        for m in meetings.filter({ $0.status == .ready }).sorted(by: { $0.id < $1.id }) {
            text += m.id + "\u{1}" + m.notes + "\u{2}"
        }
        return SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    struct Saved: Codable {
        let key: String
        let items: [Item]
        let model: String
    }

    private static var savedURL: URL {
        MeetingStore.shared.root.deletingLastPathComponent().appendingPathComponent("commitments.json")
    }

    static func save(_ saved: Saved) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        if let data = try? encoder.encode(saved) { try? data.write(to: savedURL, options: .atomic) }
    }

    static func loadSaved() -> Saved? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? Data(contentsOf: savedURL)).flatMap { try? decoder.decode(Saved.self, from: $0) }
    }

    /// The organised list when it matches the current notes, else the items as written. `model` is nil for the latter.
    static func current(_ meetings: [Meeting]) -> (items: [Item], model: String?) {
        if let saved = loadSaved(), saved.key == cacheKey(meetings) { return (saved.items, saved.model) }
        return (parse(meetings), nil)
    }

    // MARK: For agents

    /// The list as an agent reads it over MCP: grouped by when it's due, every item with the ids `propose_action` needs.
    static func agentText(_ items: [Item], model: String?, ticked: Set<String>, everyone: Bool, includeDone: Bool, today: Date = Date()) -> String {
        let visible = items.filter { everyone || $0.isMine }
        let groups = Dictionary(grouping: visible) { bucket($0, ticked: ticked.contains($0.id), today: today) }
        var out = model.map { "Organised by \($0): duplicates merged, deadlines dated, finished items marked done." }
            ?? "As written in the meeting notes (open Open commitments in Freshflo to merge duplicates and spot finished items)."
        out += "\nToday is \(day(today)). \"You\" is the user.\n"
        var shown = 0
        for b in Bucket.allCases where includeDone || b != .done {
            guard let rows = groups[b], !rows.isEmpty else { continue }
            out += "\n## \(b.title) (\(rows.count))\n"
            for item in rows.sorted(by: { ($0.dueDate ?? .distantFuture) < ($1.dueDate ?? .distantFuture) }) {
                shown += 1
                var due = item.dueDate.map(isoString) ?? "none"
                if !item.due.isEmpty { due += " (\"\(item.due)\")" }
                out += "- \(item.task)\n  commitment_id: \(item.id)\n"
                out += "  owner: \(item.owner.isEmpty ? "none" : item.owner) · due: \(due) · from: \(item.meetingTitle) (\(isoString(item.meetingDate))), meeting_id: \(item.meetingID)\n"
                if !item.alsoIn.isEmpty { out += "  also came up in: \(item.alsoIn.joined(separator: ", "))\n" }
                if let doneNote = item.doneNote { out += "  done: \(doneNote)\n" }
            }
        }
        if shown == 0 { out += everyone ? "\nNo open commitments." : "\nNo open commitments owned by the user. Pass owner: \"everyone\" to see the rest.\n" }
        return out
    }
}
