import AppKit

/// Once, after two weeks and 50 dictations: "Enjoying Freshflo?". A happy answer asks for a sentence we may
/// quote (testimonials only with explicit permission); an unhappy one asks what's wrong. Never asked again.
@MainActor
enum EnjoyPrompt {
    private static let askedKey = "enjoy.asked"

    nonisolated static func shouldAsk(days: Int, dictations: Int, asked: Bool) -> Bool {
        !asked && days >= 14 && dictations >= 50
    }

    static func maybeAsk() {
        let d = UserDefaults.standard
        let days = Insights.secondsSinceInstall / 86_400
        guard shouldAsk(days: days, dictations: HistoryStore.shared.items.count, asked: d.bool(forKey: askedKey)) else { return }
        d.set(true, forKey: askedKey)
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Enjoying Freshflo?"
        alert.informativeText = "You've dictated \(HistoryStore.shared.items.count) times in \(days) days. Freshflo is made by one person, and a sentence from you helps more than you'd think."
        alert.addButton(withTitle: "Love It")
        alert.addButton(withTitle: "Something's Wrong")
        alert.addButton(withTitle: "Not Now")
        switch alert.runModal() {
        case .alertFirstButtonReturn: askForQuote()
        case .alertSecondButtonReturn: NotificationCenter.default.post(name: .openFeedbackWindow, object: nil)
        default: break
        }
    }

    private static func askForQuote() {
        let alert = NSAlert()
        alert.messageText = "Thank you! What do you like about it?"
        alert.informativeText = "One or two sentences is perfect."
        let stack = NSStackView(frame: NSRect(x: 0, y: 0, width: 320, height: 118))
        stack.orientation = .vertical
        stack.alignment = .leading
        let text = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 60))
        text.placeholderString = "e.g. It types my Hinglish perfectly and saves me an hour a day."
        text.lineBreakMode = .byWordWrapping
        text.usesSingleLineMode = false
        let name = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        name.placeholderString = "Your name and role (optional), e.g. Priya, designer"
        let quote = NSButton(checkboxWithTitle: "Freshflo may quote this on its website", target: nil, action: nil)
        quote.state = .off
        for v in [text, name, quote] { stack.addArrangedSubview(v) }
        text.widthAnchor.constraint(equalToConstant: 320).isActive = true
        text.heightAnchor.constraint(equalToConstant: 60).isActive = true
        name.widthAnchor.constraint(equalToConstant: 320).isActive = true
        alert.accessoryView = stack
        alert.addButton(withTitle: "Send")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = text
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let words = text.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !words.isEmpty else { return }
        let who = name.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let tag = quote.state == .on ? "[testimonial · may quote]" : "[testimonial · private]"
        Task {
            try? await Insights.post("feedback", ["message": "\(tag) \(words)" + (who.isEmpty ? "" : " — \(who)"),
                                                  "id": Insights.installID, "version": Updater.currentVersion])
        }
    }
}

extension Notification.Name {
    static let openFeedbackWindow = Notification.Name("Freshflo.openFeedback")
}
