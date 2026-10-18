import AppKit
import UserNotifications

/// Monday morning: "Your week with Freshflo: 8,420 words, 2 h 42 min saved · 9-day streak". Clicking opens Your Week.
/// One notification a week at most, only when you actually dictated, and off with one switch.
final class WeeklyRecap: NSObject, UNUserNotificationCenterDelegate {
    static let shared = WeeklyRecap()
    static let site = URL(string: "https://freshflo.vercel.app")!
    var onOpen: (() -> Void)?
    private var timer: Timer?

    func start() {
        UNUserNotificationCenter.current().delegate = self
        timer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.checkNow() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.checkNow() }
    }

    /// Due on a Monday after 9 am, once per week, if last week had any dictation.
    static func isDue(now: Date = Date(), lastSent: Date?, wordsLastWeek: Int) -> Bool {
        let cal = Calendar.current
        guard wordsLastWeek > 0, cal.component(.weekday, from: now) == 2, cal.component(.hour, from: now) >= 9 else { return false }
        guard let lastSent else { return true }
        return now.timeIntervalSince(lastSent) > 5 * 86_400
    }

    static func message(words: Int, minutesSaved: Int, streak: Int) -> String {
        let saved = minutesSaved >= 60 ? "\(minutesSaved / 60) h \(minutesSaved % 60) min" : "\(minutesSaved) min"
        return "\(words.formatted()) words, \(saved) saved" + (streak > 1 ? " · \(streak)-day streak" : "")
    }

    func checkNow() {
        let settings = AppSettings.shared, defaults = UserDefaults.standard
        let week = UsageStats.shared.thisWeek
        guard settings.weeklyRecap,
              Self.isDue(lastSent: defaults.object(forKey: "recap.lastSent") as? Date, wordsLastWeek: week.words) else { return }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            guard granted else { return }
            let content = UNMutableNotificationContent()
            content.title = "Your week with Freshflo"
            content.body = Self.message(words: week.words, minutesSaved: week.minutesSaved, streak: UsageStats.shared.streak)
            center.add(UNNotificationRequest(identifier: "weekly-recap", content: content, trigger: nil))
            DispatchQueue.main.async { defaults.set(Date(), forKey: "recap.lastSent") }
        }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        await MainActor.run { onOpen?() }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner]
    }

    /// The share sheet with a short pitch and the download link.
    /// A short anonymous code for this install, so the site can count visits and sign-ups from your link.
    static var referralCode: String { String(Insights.installID.replacingOccurrences(of: "-", with: "").prefix(8)) }

    /// Your personal link: https://freshflo.vercel.app/?r=1a2b3c4d
    static var referralLink: URL {
        var c = URLComponents(url: site, resolvingAgainstBaseURL: false)!
        c.path = "/"
        c.queryItems = [URLQueryItem(name: "r", value: referralCode)]
        return c.url!
    }

    static func share(from view: NSView?) {
        let pitch = "I've been using Freshflo: hold a key, talk, and clean text appears in any app. Free for Mac and Windows:"
        let link = referralLink
        let picker = NSSharingServicePicker(items: [pitch, link])
        if let view { picker.show(relativeTo: view.bounds, of: view, preferredEdge: .minY) } else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(pitch + " " + link.absoluteString, forType: .string)
        }
    }
}
