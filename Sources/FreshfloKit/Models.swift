import Foundation

enum Tone: String, Codable, CaseIterable, Identifiable {
    case formal, casual, veryCasual

    var id: String { rawValue }

    var label: String {
        switch self {
        case .formal: return "Formal"
        case .casual: return "Casual"
        case .veryCasual: return "Very casual"
        }
    }

    var example: String {
        switch self {
        case .formal: return "Hey, are you free for lunch tomorrow? Let's do 12 if that works for you."
        case .casual: return "Hey are you free for lunch tomorrow? Let's do 12 if that works for you"
        case .veryCasual: return "hey are you free for lunch tomorrow? let's do 12 if that works for you"
        }
    }

    var instruction: String {
        switch self {
        case .formal:
            return "Formal: complete sentences, standard capitalization and punctuation, polished professional wording."
        case .casual:
            return "Casual: conversational, normal capitalization, light punctuation, no trailing period on short messages."
        case .veryCasual:
            return "Very casual: all lowercase, minimal punctuation, no trailing period, like a quick text message."
        }
    }
}

enum HotkeyKey: String, CaseIterable, Identifiable {
    case fn, rightOption, rightCommand, rightControl

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fn: return "Fn / Globe"
        case .rightOption: return "Right Option ⌥"
        case .rightCommand: return "Right Command ⌘"
        case .rightControl: return "Right Control ⌃"
        }
    }

    var shortLabel: String {
        switch self {
        case .fn: return "Fn"
        case .rightOption: return "Right ⌥"
        case .rightCommand: return "Right ⌘"
        case .rightControl: return "Right ⌃"
        }
    }

    /// Virtual key codes that report this key in flagsChanged events.
    var keyCodes: Set<Int64> {
        switch self {
        case .fn: return [63, 179]
        case .rightOption: return [61]
        case .rightCommand: return [54]
        case .rightControl: return [62]
        }
    }

    /// Device-specific modifier bit that is set while this exact key is held.
    var flagMask: UInt64 {
        switch self {
        case .fn: return 0x800000 // kCGEventFlagMaskSecondaryFn
        case .rightOption: return 0x40 // NX_DEVICERALTKEYMASK
        case .rightCommand: return 0x10 // NX_DEVICERCMDKEYMASK
        case .rightControl: return 0x2000 // NX_DEVICERCTLKEYMASK
        }
    }
}

enum Provider: String, CaseIterable, Identifiable {
    case groq, openai, custom, local

    var id: String { rawValue }

    var isCloud: Bool { self != .local }

    var label: String {
        switch self {
        case .groq: return "Groq"
        case .openai: return "OpenAI"
        case .custom: return "Custom (OpenAI-compatible)"
        case .local: return "Built-in (Apple · free · no key)"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .groq: return "https://api.groq.com/openai/v1"
        case .openai: return "https://api.openai.com/v1"
        case .custom: return "http://localhost:8000/v1"
        case .local: return ""
        }
    }

    var defaultTranscriptionModel: String {
        switch self {
        case .groq: return "whisper-large-v3-turbo"
        case .openai: return "gpt-4o-mini-transcribe"
        case .custom: return "whisper-1"
        case .local: return ""
        }
    }

    var defaultCleanupModel: String {
        switch self {
        case .groq: return "qwen/qwen3.8-27b"
        case .openai: return "gpt-4.1-mini"
        case .custom: return "gpt-4o-mini"
        case .local: return ""
        }
    }

    /// Stronger model for translation, Command and Ask, where quality matters more than ~300 ms.
    var defaultSmartModel: String {
        switch self {
        case .groq: return "openai/gpt-oss-120b"
        case .openai: return "gpt-4.1"
        case .custom: return "gpt-4o-mini"
        case .local: return ""
        }
    }

    var keyURL: URL? {
        switch self {
        case .groq: return URL(string: "https://console.groq.com/keys")
        case .openai: return URL(string: "https://platform.openai.com/api-keys")
        case .custom, .local: return nil
        }
    }
}

enum RegionalFormat: String, CaseIterable, Identifiable {
    case none, india, us, uk

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "No preference"
        case .india: return "India (₹, lakh/crore, DD/MM)"
        case .us: return "United States ($, MM/DD)"
        case .uk: return "United Kingdom (£, DD/MM)"
        }
    }

    var instruction: String? {
        switch self {
        case .none: return nil
        case .india:
            return "Regional conventions (India): rupee amounts as ₹ with Indian digit grouping (₹1,50,000), keep lakh and crore, numeric dates as DD/MM/YYYY (keep spoken dates like \"15th August\" as words), and \"at the rate\" inside an email address means @."
        case .us: return "Regional conventions (US): $ for dollars, dates as MM/DD/YYYY, American spelling."
        case .uk: return "Regional conventions (UK): £ for pounds, dates as DD/MM/YYYY, British spelling."
        }
    }
}

enum DictationMode: String, Codable {
    case dictation, command, ask
}

enum CleanupMode: String, CaseIterable, Identifiable {
    case auto, apple, api, rules, off

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto (best available)"
        case .apple: return "Apple on-device model"
        case .api: return "Cloud LLM (same provider)"
        case .rules: return "Basic rules (no AI)"
        case .off: return "Off (raw transcript)"
        }
    }
}

struct Snippet: Codable, Identifiable, Hashable {
    var id = UUID()
    var trigger: String
    var expansion: String
}

struct AppToneRule: Codable, Identifiable, Hashable {
    var id = UUID()
    var bundleID: String
    var appName: String
    var tone: Tone
}

struct HistoryItem: Codable, Identifiable, Hashable {
    var id = UUID()
    var date: Date
    var appName: String
    var bundleID: String
    var raw: String
    var text: String
    var tone: Tone
    var duration: Double
    var cleanup: String
    var mode: DictationMode?
    /// Which engine transcribed it, for the privacy log.
    var transcriber: String?
    /// Release-to-inserted time, for the History list.
    var latencyMs: Int?

    /// True when neither the audio nor the text left this Mac.
    var stayedOnDevice: Bool {
        (transcriber ?? "").hasPrefix("apple-speech") && ["apple", "rules", "fast", "snippet", "off"].contains(cleanup)
    }

    var wordCount: Int { text.split(whereSeparator: \.isWhitespace).count }
}
