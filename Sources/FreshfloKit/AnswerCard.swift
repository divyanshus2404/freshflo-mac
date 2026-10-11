import AppKit
import SwiftUI

/// Renders the small Markdown subset our models produce: headings, bullets, checkboxes, inline emphasis/code/links.
struct MarkdownText: View {
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                block
            }
        }
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var blocks: [AnyView] {
        text.components(separatedBy: "\n").compactMap { rawLine in
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { return nil }
            if line.hasPrefix("### ") { return AnyView(inline(String(line.dropFirst(4))).font(.headline)) }
            if line.hasPrefix("## ") { return AnyView(inline(String(line.dropFirst(3))).font(.title3.weight(.semibold)).padding(.top, 6)) }
            if line.hasPrefix("# ") { return AnyView(inline(String(line.dropFirst(2))).font(.title2.weight(.bold))) }
            for (prefix, symbol) in [("- [ ] ", "square"), ("- [x] ", "checkmark.square.fill"), ("- [X] ", "checkmark.square.fill")]
            where line.hasPrefix(prefix) {
                return AnyView(row(Image(systemName: symbol).foregroundStyle(.secondary), String(line.dropFirst(prefix.count))))
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                return AnyView(row(Text("•").foregroundStyle(.secondary), String(line.dropFirst(2))))
            }
            return AnyView(inline(line))
        }
    }

    private func row<V: View>(_ marker: V, _ content: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            marker
            inline(content)
        }
    }

    private func inline(_ s: String) -> Text {
        if let attributed = try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) {
            return Text(attributed)
        }
        return Text(s)
    }
}

final class AnswerCardModel: ObservableObject {
    struct Action: Identifiable {
        let id = UUID()
        var title: String
        var isPrimary = false
        var handler: () -> Void
    }

    @Published var icon = "sparkles"
    @Published var title = ""
    @Published var subtitle = ""
    @Published var body = ""
    @Published var isLoading = false
    @Published var actions: [Action] = []
}

private struct AnswerCardView: View {
    @ObservedObject var model: AnswerCardModel
    var onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: model.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.tint)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.title).font(.headline).lineLimit(2)
                    if !model.subtitle.isEmpty {
                        Text(model.subtitle).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                    }
                }
                Spacer()
                Button(action: onClose) { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .keyboardShortcut(.cancelAction)
            }
            if model.isLoading {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Thinking…").foregroundStyle(.secondary)
                }
            } else if !model.body.isEmpty {
                ScrollView {
                    MarkdownText(text: model.body)
                }
                .frame(maxHeight: 340)
                .fixedSize(horizontal: false, vertical: true)
            }
            if !model.actions.isEmpty {
                HStack {
                    Spacer()
                    ForEach(model.actions) { action in
                        if action.isPrimary {
                            Button(action.title, action: action.handler)
                                .buttonStyle(.borderedProminent)
                                .keyboardShortcut(.defaultAction)
                        } else {
                            Button(action.title, action: action.handler)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 480)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.primary.opacity(0.08)))
    }
}

/// A floating card for answers, confirmations and rewrites. Esc closes it.
@MainActor
final class AnswerCard {
    static let shared = AnswerCard()

    let model = AnswerCardModel()
    private var panel: NSPanel?
    /// The app that was in front before the card appeared, so "Insert" pastes there.
    private(set) var targetApp: NSRunningApplication?

    func show(icon: String, title: String, subtitle: String = "", loading: Bool = true) {
        let front = NSWorkspace.shared.frontmostApplication
        if front?.bundleIdentifier != Bundle.main.bundleIdentifier { targetApp = front }
        model.icon = icon
        model.title = title
        model.subtitle = subtitle
        model.body = ""
        model.actions = []
        model.isLoading = loading
        present()
    }

    func update(body: String, actions: [AnswerCardModel.Action]) {
        model.isLoading = false
        model.body = body
        model.actions = actions
        resize()
    }

    /// Standard buttons for a text result: Copy, plus Insert when there's an app to paste into.
    func textActions(_ text: String) -> [AnswerCardModel.Action] {
        var actions = [AnswerCardModel.Action(title: "Copy") { [weak self] in
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            self?.close()
        }]
        if targetApp != nil {
            actions.append(.init(title: "Insert", isPrimary: true) { [weak self] in self?.insert(text) })
        }
        return actions
    }

    func insert(_ text: String) {
        let app = targetApp
        close()
        app?.activate()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { TextInserter.insert(text) }
    }

    func close() {
        panel?.orderOut(nil)
    }

    func flashDone(_ message: String) {
        update(body: "✓ " + message, actions: [])
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.4) { [weak self] in self?.close() }
    }

    private func present() {
        if panel == nil {
            let p = NSPanel(
                contentRect: NSRect(x: 0, y: 0, width: 480, height: 160),
                styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            p.titleVisibility = .hidden
            p.titlebarAppearsTransparent = true
            p.isMovableByWindowBackground = true
            p.level = .floating
            p.isOpaque = false
            p.backgroundColor = .clear
            p.hidesOnDeactivate = false
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            p.standardWindowButton(.closeButton)?.isHidden = true
            p.standardWindowButton(.miniaturizeButton)?.isHidden = true
            p.standardWindowButton(.zoomButton)?.isHidden = true
            p.contentView = NSHostingView(rootView: AnswerCardView(model: model) { [weak self] in self?.close() })
            panel = p
        }
        resize()
        panel?.makeKeyAndOrderFront(nil)
    }

    private func resize() {
        guard let panel, let content = panel.contentView else { return }
        let size = content.fittingSize
        let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return }
        let origin = NSPoint(x: frame.midX - size.width / 2, y: frame.maxY - size.height - 80)
        panel.setFrame(NSRect(origin: origin, size: size), display: true, animate: panel.isVisible)
    }
}
