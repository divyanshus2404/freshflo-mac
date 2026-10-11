import AppKit
import MetricKit
import SwiftUI

/// Learning from real users without reading them:
/// - Feedback: a message (and optionally an email and app diagnostics) the user chooses to send.
/// - Usage counts and crash reports: only when "Share anonymous usage" is on. Counts never include words,
///   app names or anything typed; crash reports are Apple's MetricKit call stacks.
/// Everything goes to freshflo.vercel.app and is stored privately (see the privacy policy).
enum Insights {
    static let endpoint = URL(string: ProcessInfo.processInfo.environment["FRESHFLO_INSIGHTS_URL"] ?? "https://freshflo.vercel.app/api")!

    /// A random ID for this install, so daily counts can be told apart. Not linked to the person.
    static var installID: String {
        if let id = UserDefaults.standard.string(forKey: "insights.id") { return id }
        let id = UUID().uuidString.lowercased()
        UserDefaults.standard.set(id, forKey: "insights.id")
        return id
    }

    /// App and Mac facts that help debug: no words, no app names, no file paths.
    static var environment: [String: Any] {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        let settings = AppSettings.shared
        return [
            "version": Updater.currentVersion,
            "os": "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "arch": { () -> String in
                #if arch(arm64)
                return "arm64"
                #else
                return "x86_64"
                #endif
            }(),
            "model": String(decoding: model.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self),
            "engine": settings.provider.rawValue,
            "cleanup": settings.cleanupMode.rawValue,
            "language": settings.language.isEmpty ? "auto" : settings.language,
            "writeIn": settings.outputLanguage.isEmpty ? "same" : settings.outputLanguage,
            "hotkey": settings.hotkey.rawValue,
            "grammar": settings.fixGrammar,
            "profanity": settings.profanity.rawValue,
            "promptMode": settings.autoPromptMode,
        ]
    }

    // MARK: Sending

    static func post(_ path: String, _ body: [String: Any]) async throws {
        var request = URLRequest(url: endpoint.appendingPathComponent(path), timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Freshflo/\(Updater.currentVersion)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw NSError(domain: "Freshflo", code: 1, userInfo: [NSLocalizedDescriptionKey: message ?? "Couldn't reach Freshflo. Check your connection and try again."])
        }
    }

    // MARK: Daily usage counts (opt-in)

    /// Sends yesterday's totals once a day: dictation count, words, median latency, failures and engines used.
    static func sendDailyIfNeeded() {
        guard AppSettings.shared.shareUsage else { return }
        let calendar = Calendar.current
        guard let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: Date())) else { return }
        let day = ISO8601DateFormatter.string(from: yesterday, timeZone: .current, formatOptions: [.withFullDate])
        guard UserDefaults.standard.string(forKey: "insights.lastDay") != day else { return }
        let traces = Diagnostics.recent(2000).filter { calendar.isDate($0.date, inSameDayAs: yesterday) }
        let ok = traces.filter { $0.error == nil }
        let latencies = ok.map(\.totalMs).sorted()
        var engines: [String: Int] = [:]
        for trace in ok { engines[trace.transcriber.components(separatedBy: " ").first ?? "?", default: 0] += 1 }
        var body = environment
        body["kind"] = "daily"
        body["id"] = installID
        body["day"] = day
        body["dictations"] = ok.count
        body["failed"] = traces.count - ok.count
        body["words"] = ok.reduce(0) { $0 + $1.words }
        body["medianMs"] = latencies.isEmpty ? 0 : latencies[latencies.count / 2]
        body["engines"] = engines
        body["streak"] = UsageStats.shared.streak
        Task {
            if (try? await post("insights", body)) != nil { UserDefaults.standard.set(day, forKey: "insights.lastDay") }
        }
    }

    // MARK: Crash reports (opt-in, via MetricKit)

    private static let crashSubscriber = CrashSubscriber()
    static func start() {
        MXMetricManager.shared.add(crashSubscriber)
        sendDailyIfNeeded()
        Timer.scheduledTimer(withTimeInterval: 3 * 3600, repeats: true) { _ in sendDailyIfNeeded() }
    }

    final class CrashSubscriber: NSObject, MXMetricManagerSubscriber {
        func didReceive(_ payloads: [MXDiagnosticPayload]) {
            guard AppSettings.shared.shareUsage else { return }
            for payload in payloads where !(payload.crashDiagnostics ?? []).isEmpty {
                guard let report = String(data: payload.jsonRepresentation(), encoding: .utf8) else { continue }
                var body = Insights.environment
                body["kind"] = "crash"
                body["id"] = Insights.installID
                body["report"] = String(report.prefix(180_000))
                Task { try? await Insights.post("insights", body) }
            }
        }
    }
}

/// Menu → Send Feedback…
struct FeedbackView: View {
    var onClose: () -> Void
    @State private var message = ""
    @State private var email = ""
    @State private var attachDiagnostics = true
    @State private var sending = false
    @State private var status: String?
    @State private var sent = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if sent {
                Spacer()
                Image(systemName: "checkmark.circle.fill").font(.system(size: 44)).foregroundStyle(Brand.mint)
                Text("Thank you").font(.system(size: 28, design: .serif))
                Text("Your feedback reached the person who builds Freshflo. If you left an email, you may get a reply.")
                    .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer()
                HStack { Spacer(); Button("Close", action: onClose).keyboardShortcut(.defaultAction).controlSize(.large) }
            } else {
                Text("Send feedback").font(.system(size: 28, design: .serif))
                Text("What's working, what's annoying, what you wish it did. Bugs too.").foregroundStyle(.secondary)
                ZStack(alignment: .topLeading) {
                    TextEditor(text: $message)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.black.opacity(0.1)))
                    if message.isEmpty {
                        Text("e.g. It misheard my manager's name, or: I'd love it in Notion's sidebar…").foregroundStyle(.tertiary).padding(14).allowsHitTesting(false)
                    }
                }
                .frame(height: 150)
                TextField("", text: $email, prompt: Text("Your email (optional, only if you'd like a reply)")).textFieldStyle(.roundedBorder)
                Toggle(isOn: $attachDiagnostics) {
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Include app details")
                        Text("Version, macOS, Mac model, engine, settings and recent timings. Never your words.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let status { Text(status).font(.callout).foregroundStyle(.red) }
                HStack {
                    Button("Cancel", action: onClose)
                    Spacer()
                    Button(sending ? "Sending…" : "Send") { send() }
                        .keyboardShortcut(.defaultAction).controlSize(.large).buttonStyle(.borderedProminent)
                        .disabled(sending || message.trimmingCharacters(in: .whitespacesAndNewlines).count < 3)
                }
            }
        }
        .padding(26)
        .frame(width: 480, height: 430)
        .background(Brand.backdrop)
        .environment(\.colorScheme, .light)
        .tint(Brand.mint)
    }

    private func send() {
        sending = true
        status = nil
        var body: [String: Any] = ["message": message, "version": Updater.currentVersion]
        let trimmed = email.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { body["email"] = trimmed }
        if attachDiagnostics {
            var details = Insights.environment
            details["recent"] = Diagnostics.summary()
            body["diagnostics"] = details
        }
        Task { @MainActor in
            do {
                try await Insights.post("feedback", body)
                withAnimation { sent = true }
            } catch {
                status = error.localizedDescription
            }
            sending = false
        }
    }
}
