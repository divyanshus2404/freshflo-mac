import AppKit
import ApplicationServices

/// What the user is typing into, captured via the Accessibility API when dictation starts.
struct FocusContext {
    var appName = ""
    var bundleID = ""
    var windowTitle = ""
    /// Up to 300 characters before the caret; nil when the app doesn't expose it.
    var textBefore: String?
    /// Selected text; "" when nothing is selected, nil when the app doesn't expose it.
    var selectedText: String?
    var isSecureField = false
    /// The focused text element, kept so the correction learner can re-read it later.
    var element: AXUIElement?
    /// Where the text cursor is on screen (Cocoa coordinates), so the indicator can appear right there.
    var caretRect: CGRect?

    private static var accessibilityEnabledPIDs = Set<pid_t>()

    /// Current full text of an element (capped), used to spot user edits after insertion.
    static func currentText(of element: AXUIElement) -> String? {
        guard let text = string(element, kAXValueAttribute), text.utf16.count <= 50_000 else { return nil }
        return text
    }

    static func capture(app: NSRunningApplication?, readText: Bool) -> FocusContext {
        var ctx = FocusContext(appName: app?.localizedName ?? "", bundleID: app?.bundleIdentifier ?? "")
        guard let app, AXIsProcessTrusted() else { return ctx }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.25)
        enableAccessibilityTree(appElement, pid: app.processIdentifier)

        if let window: AXUIElement = element(appElement, kAXFocusedWindowAttribute) {
            ctx.windowTitle = string(window, kAXTitleAttribute) ?? ""
        }
        guard let focused: AXUIElement = element(appElement, kAXFocusedUIElementAttribute) else { return ctx }
        AXUIElementSetMessagingTimeout(focused, 0.25)
        ctx.element = focused

        if string(focused, kAXSubroleAttribute) == (kAXSecureTextFieldSubrole as String) {
            ctx.isSecureField = true
            return ctx
        }
        guard readText else { return ctx }

        ctx.selectedText = string(focused, kAXSelectedTextAttribute)
        ctx.textBefore = textBeforeCaret(focused)
        ctx.caretRect = caretBounds(focused)
        return ctx
    }

    /// Screen rect of the caret, converted from Accessibility (top-left origin) to Cocoa (bottom-left) coordinates.
    static func caretBounds(_ el: AXUIElement) -> CGRect? {
        guard let range = selectedRange(el) else { return nil }
        var target = CFRange(location: range.location, length: 0)
        var rect = CGRect.zero
        for attempt in [target, CFRange(location: max(0, range.location - 1), length: 1)] {
            target = attempt
            guard let param = AXValueCreate(.cfRange, &target) else { continue }
            var out: CFTypeRef?
            guard AXUIElementCopyParameterizedAttributeValue(el, kAXBoundsForRangeParameterizedAttribute as CFString, param, &out) == .success,
                  let value = out, CFGetTypeID(value) == AXValueGetTypeID(),
                  AXValueGetValue(value as! AXValue, .cgRect, &rect), rect.height > 2, rect.height < 200 else { continue }
            if attempt.length == 1 { rect.origin.x += rect.width; rect.size.width = 1 }
            break
        }
        guard rect.height > 2, let primary = NSScreen.screens.first else { return nil }
        let cocoa = CGRect(x: rect.minX, y: primary.frame.height - rect.maxY, width: max(1, rect.width), height: rect.height)
        // Some apps report (0,0) or off-screen garbage; only trust rects that land on a screen.
        guard cocoa.minX > 1 || cocoa.minY > 1, NSScreen.screens.contains(where: { $0.frame.intersects(cocoa) }) else { return nil }
        return cocoa
    }

    private static func selectedRange(_ el: AXUIElement) -> CFRange? {
        var range = CFRange()
        guard let rangeValue = value(el, kAXSelectedTextRangeAttribute),
              CFGetTypeID(rangeValue) == AXValueGetTypeID(),
              AXValueGetValue(rangeValue as! AXValue, .cfRange, &range),
              range.location >= 0 else { return nil }
        return range
    }

    /// Up to `limit` characters before the caret, or nil when the element doesn't expose its text.
    static func textBeforeCaret(_ el: AXUIElement, limit: Int = 300) -> String? {
        guard let range = selectedRange(el) else { return nil }
        let start = max(0, range.location - limit)
        var before = CFRange(location: start, length: range.location - start)
        if before.length == 0 {
            // Caret at the very start; only trust it if the field actually exposes its text.
            return string(el, kAXValueAttribute) != nil ? "" : nil
        }
        if let param = AXValueCreate(.cfRange, &before) {
            var out: CFTypeRef?
            if AXUIElementCopyParameterizedAttributeValue(el, kAXStringForRangeParameterizedAttribute as CFString, param, &out) == .success,
               let text = out as? String {
                return text
            }
        }
        if let full = string(el, kAXValueAttribute) {
            let ns = full as NSString
            if range.location <= ns.length {
                return ns.substring(with: NSRange(location: start, length: range.location - start))
            }
        }
        return nil
    }

    /// Selects the `utf16Length` characters just before the caret (used to edit the last insertion by voice).
    func selectBeforeCaret(utf16Length: Int) -> Bool {
        guard let element, utf16Length > 0, let range = Self.selectedRange(element),
              range.length == 0, range.location >= utf16Length else { return false }
        var target = CFRange(location: range.location - utf16Length, length: utf16Length)
        guard let value = AXValueCreate(.cfRange, &target) else { return false }
        return AXUIElementSetAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, value) == .success
    }

    /// Whether the text just before the caret ends with `text` (ignoring surrounding whitespace).
    func caretFollows(_ text: String) -> Bool {
        let tail = String(text.trimmingCharacters(in: .whitespacesAndNewlines).suffix(200))
        guard !tail.isEmpty, let before = textBefore?.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        return before.hasSuffix(tail)
    }

    /// Chromium/Electron apps (Slack, Notion, VS Code, Chrome) only build their accessibility tree on request.
    private static func enableAccessibilityTree(_ appElement: AXUIElement, pid: pid_t) {
        guard !accessibilityEnabledPIDs.contains(pid) else { return }
        accessibilityEnabledPIDs.insert(pid)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private static func value(_ el: AXUIElement, _ name: String) -> CFTypeRef? {
        var out: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &out) == .success else { return nil }
        return out
    }

    private static func element(_ el: AXUIElement, _ name: String) -> AXUIElement? {
        guard let v = value(el, name), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private static func string(_ el: AXUIElement, _ name: String) -> String? {
        value(el, name) as? String
    }

    // MARK: - Formatting against context

    /// True when the caret sits mid-sentence, so the insertion should continue it rather than start a new one.
    var continuesSentence: Bool {
        guard let last = textBefore?.trimmingCharacters(in: .whitespaces).last else { return false }
        return last.isLetter || last.isNumber || last == ","
    }

    /// Lowercases a sentence-initial everyday word when the insertion continues an existing sentence.
    func continued(_ text: String) -> String {
        guard continuesSentence, let firstWord = text.split(whereSeparator: { !$0.isLetter && $0 != "'" }).first else { return text }
        let word = String(firstWord)
        guard word != "I", !word.hasPrefix("I'"), word != word.uppercased() || word.count == 1,
              Self.sentenceStarters.contains(word.lowercased()),
              let range = text.range(of: word) else { return text }
        return text.replacingCharacters(in: range, with: word.lowercased())
    }

    private static let sentenceStarters: Set<String> = [
        "what", "why", "how", "who", "when", "where", "which", "whether", "can", "could", "would", "should", "will",
        "is", "are", "was", "were", "do", "does", "did", "have", "has", "had", "the", "a", "an", "and", "but", "or",
        "so", "if", "that", "this", "these", "those", "it", "its", "it's", "we", "you", "they", "he", "she", "my",
        "our", "your", "their", "there", "here", "then", "also", "just", "to", "for", "in", "on", "at", "of", "with",
        "about", "as", "because", "since", "though", "although", "please", "maybe", "not", "all", "some", "any",
    ]

    /// Adds a separating space when needed, based on the character before the caret.
    func spaced(_ text: String, fallbackTrailingSpace: Bool) -> String {
        guard let before = textBefore else {
            if fallbackTrailingSpace, let last = text.last, !last.isWhitespace { return text + " " }
            return text
        }
        guard let prev = before.last, let first = text.first else { return text }
        let noSpaceAfter: Set<Character> = ["(", "[", "{", "\"", "'", "“", "‘", "/", "-", "@", "#"]
        let noSpaceBefore: Set<Character> = [",", ".", ";", ":", "!", "?", ")", "]", "}", "”", "’"]
        if !prev.isWhitespace, !noSpaceAfter.contains(prev), !noSpaceBefore.contains(first) {
            return " " + text
        }
        return text
    }
}
