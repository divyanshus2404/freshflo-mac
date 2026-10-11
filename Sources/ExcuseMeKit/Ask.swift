import AppKit
import EventKit
import Foundation

/// Ask mode (hold the dictation key + Shift): answers questions about what's on screen, or performs a local action.
@MainActor
enum Ask {
    enum Intent {
        case answer(String)
        case reminder(title: String, due: Date?)
        case event(title: String, start: Date, end: Date, location: String?)
        case email(to: String, subject: String, body: String)
        case open(String)
        case search(String)
    }

    static func handle(question: String, context: FocusContext) async {
        let card = AnswerCard.shared
        card.show(icon: "sparkles", title: question, subtitle: context.appName.isEmpty ? "" : "In \(context.appName)")
        do {
            var selection = context.selectedText ?? ""
            if selection.isEmpty, context.selectedText == nil { selection = await TextInserter.copySelection() ?? "" }
            let intent = try await route(question: question, selection: selection, context: context)
            present(intent)
        } catch {
            card.update(body: "⚠︎ " + error.localizedDescription, actions: [])
        }
    }

    static func route(question: String, selection: String, context: FocusContext) async throws -> Intent {
        let now = Date()
        let iso = DateFormatter()
        iso.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        let weekday = now.formatted(.dateTime.weekday(.wide))
        // Models are unreliable at weekday arithmetic; give them the calendar explicitly.
        let dayFormat = DateFormatter()
        dayFormat.dateFormat = "EEEE yyyy-MM-dd"
        let upcoming = (1...14).compactMap { Calendar.current.date(byAdding: .day, value: $0, to: now) }
            .map { dayFormat.string(from: $0) }.joined(separator: ", ")
        let userName = NSFullUserName()
        let instructions = """
        You are the voice assistant inside ExcuseMe, a macOS dictation app. Now: \(iso.string(from: now)) (\(weekday)), time zone \(TimeZone.current.identifier).
        Upcoming days (use these exact dates; "this Friday" means the next Friday listed): \(upcoming).
        The user's name is \(userName.isEmpty ? "unknown" : userName); sign emails with it and never use placeholders like [Your Name].
        Decide what the user wants and reply with ONLY one JSON object, no prose:
        {"type":"answer","answer":"<concise Markdown answer>"}: questions, explanations, summaries, translations, rewrites of the selected text
        {"type":"reminder","title":"<task>","due":"<yyyy-MM-ddTHH:mm:ss or null>"}
        {"type":"event","title":"<title>","start":"<yyyy-MM-ddTHH:mm:ss>","end":"<yyyy-MM-ddTHH:mm:ss or null>","location":"<or null>"}
        {"type":"email","to":"<email address, or a name, or empty>","subject":"<subject>","body":"<full email body>"}
        {"type":"open","target":"<app name or URL>"}
        {"type":"search","query":"<web search query>"}
        If selected text is provided, the request is usually about it. Answers: under 150 words unless asked for more; never invent facts. If unsure of a fact, say so.
        """
        var prompt = "Request: \(question)"
        if !selection.isEmpty { prompt += "\n\nSelected text:\n\(selection.prefix(12_000))" }
        if !context.appName.isEmpty { prompt += "\n\nFrontmost app: \(context.appName)" + (context.windowTitle.isEmpty ? "" : " — \(context.windowTitle)") }

        let reply = try await Assistant.complete(instructions: instructions, prompt: prompt, temperature: 0.2)
        return parse(reply) ?? .answer(Cleanup.stripThinking(reply))
    }

    static func parse(_ reply: String) -> Intent? {
        guard let json = Assistant.jsonObject(in: reply), let type = json["type"] as? String else { return nil }
        func str(_ key: String) -> String? {
            guard let v = json[key] as? String, !v.isEmpty, v.lowercased() != "null" else { return nil }
            return v
        }
        switch type {
        case "reminder":
            guard let title = str("title") else { return nil }
            return .reminder(title: title, due: str("due").flatMap(parseDate))
        case "event":
            guard let title = str("title"), let start = str("start").flatMap(parseDate) else { return nil }
            let end = str("end").flatMap(parseDate) ?? start.addingTimeInterval(3600)
            return .event(title: title, start: start, end: max(end, start.addingTimeInterval(900)), location: str("location"))
        case "email":
            return .email(to: str("to") ?? "", subject: str("subject") ?? "", body: str("body") ?? "")
        case "open":
            return str("target").map(Intent.open)
        case "search":
            return str("query").map(Intent.search)
        default:
            return str("answer").map(Intent.answer)
        }
    }

    static func parseDate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            f.dateFormat = format
            if let d = f.date(from: s) { return d }
        }
        return ISO8601DateFormatter().date(from: s)
    }

    private static func present(_ intent: Intent) {
        let card = AnswerCard.shared
        switch intent {
        case .answer(let text):
            card.model.icon = "sparkles"
            card.update(body: text, actions: card.textActions(text))

        case .reminder(let title, let due):
            card.model.icon = "checklist"
            let when = due.map { "\n\nDue: " + $0.formatted(date: .abbreviated, time: .shortened) } ?? ""
            card.update(body: "**Add reminder:** \(title)\(when)", actions: [
                .init(title: "Cancel") { card.close() },
                .init(title: "Add Reminder", isPrimary: true) {
                    Task { @MainActor in
                        do {
                            try await LocalActions.addReminder(title: title, due: due)
                            card.flashDone("Added to Reminders")
                        } catch {
                            card.update(body: "⚠︎ " + error.localizedDescription, actions: [])
                        }
                    }
                },
            ])

        case .event(let title, let start, let end, let location):
            card.model.icon = "calendar.badge.plus"
            var body = "**Add event:** \(title)\n\n\(start.formatted(date: .abbreviated, time: .shortened)) – \(end.formatted(date: .omitted, time: .shortened))"
            if let location { body += "\n\nLocation: \(location)" }
            card.update(body: body, actions: [
                .init(title: "Cancel") { card.close() },
                .init(title: "Add to Calendar", isPrimary: true) {
                    Task { @MainActor in
                        do {
                            try await LocalActions.addEvent(title: title, start: start, end: end, location: location)
                            card.flashDone("Added to Calendar")
                        } catch {
                            card.update(body: "⚠︎ " + error.localizedDescription, actions: [])
                        }
                    }
                },
            ])

        case .email(let to, let subject, let body):
            card.model.icon = "envelope"
            card.update(body: "**To:** \(to.isEmpty ? "—" : to)\n**Subject:** \(subject)\n\n\(body)", actions: [
                .init(title: "Copy Body") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(body, forType: .string)
                    card.close()
                },
                .init(title: "Open in Mail", isPrimary: true) {
                    LocalActions.composeEmail(to: to, subject: subject, body: body)
                    card.close()
                },
            ])

        case .open(let target):
            if LocalActions.open(target) {
                card.model.icon = "arrow.up.forward.app"
                card.flashDone("Opening \(target)")
            } else {
                card.update(body: "Couldn't find “\(target)”.", actions: [])
            }

        case .search(let query):
            LocalActions.search(query)
            card.model.icon = "magnifyingglass"
            card.flashDone("Searching for “\(query)”")
        }
    }
}

enum LocalActionError: LocalizedError {
    case denied(String)

    var errorDescription: String? {
        switch self {
        case .denied(let what): return "ExcuseMe needs access to \(what). Allow it in System Settings → Privacy & Security."
        }
    }
}

/// Actions that run on this Mac with Apple's own frameworks; nothing goes through a third-party account.
@MainActor
enum LocalActions {
    private static let store = EKEventStore()

    static func addReminder(title: String, due: Date?) async throws {
        guard try await store.requestFullAccessToReminders() else { throw LocalActionError.denied("Reminders") }
        let reminder = EKReminder(eventStore: store)
        reminder.title = title
        reminder.calendar = store.defaultCalendarForNewReminders()
        if let due {
            reminder.dueDateComponents = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)
            reminder.addAlarm(EKAlarm(absoluteDate: due))
        }
        try store.save(reminder, commit: true)
    }

    static func addEvent(title: String, start: Date, end: Date, location: String?) async throws {
        guard try await store.requestFullAccessToEvents() else { throw LocalActionError.denied("Calendar") }
        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start
        event.endDate = end
        event.location = location
        event.calendar = store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent, commit: true)
    }

    static func composeEmail(to: String, subject: String, body: String) {
        var components = URLComponents()
        components.scheme = "mailto"
        components.path = to.contains("@") ? to : ""
        components.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    static func search(_ query: String) {
        var components = URLComponents(string: "https://www.google.com/search")!
        components.queryItems = [URLQueryItem(name: "q", value: query)]
        if let url = components.url { NSWorkspace.shared.open(url) }
    }

    /// Opens a URL, or an app by (fuzzy) name.
    static func open(_ target: String) -> Bool {
        let t = target.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.contains("://"), let url = URL(string: t) { return NSWorkspace.shared.open(url) }
        if !t.contains(" "), t.contains("."), let url = URL(string: "https://" + t) { return NSWorkspace.shared.open(url) }
        guard let app = findApp(named: t) else { return false }
        NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
        return true
    }

    private static func findApp(named name: String) -> URL? {
        let wanted = name.lowercased().replacingOccurrences(of: ".app", with: "")
        let dirs = ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities",
                    NSHomeDirectory() + "/Applications"]
        var candidates: [URL] = []
        for dir in dirs {
            let items = (try? FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: dir), includingPropertiesForKeys: nil)) ?? []
            candidates += items.filter { $0.pathExtension == "app" }
        }
        let names = candidates.map { ($0, $0.deletingPathExtension().lastPathComponent.lowercased()) }
        return names.first { $0.1 == wanted }?.0
            ?? names.first { $0.1.hasPrefix(wanted) }?.0
            ?? names.first { $0.1.contains(wanted) }?.0
    }
}
