import Foundation
import NaturalLanguage

/// Which language was spoken, and whether a translation really came out in the language you asked for.
/// Combines Whisper's own guess, Apple's text-based recognizer and the languages you said you speak; recognises
/// Hinglish (Hindi written in Latin letters), which recognizers usually mistake for English.
enum LanguageID {
    struct Detection: Equatable {
        var code: String        // Whisper/ISO code: "en", "hi", "ta"… ("hi" with hinglish = true for Hinglish)
        var hinglish = false
        var name: String {
            if hinglish { return "Hinglish" }
            return Languages.spoken.first { $0.code == code }?.name ?? code
        }
    }

    // MARK: Spoken language

    /// Common Hindi words written in Latin letters. Two or more (and some share of the words) means Hinglish, not English.
    private static let hinglishWords: Set<String> = [
        "hai", "hain", "nahi", "nahin", "kya", "kyun", "kyunki", "mein", "main", "mai", "yaar", "kal", "aaj", "aap", "tum", "hum",
        "kar", "karo", "karna", "karke", "tha", "thi", "the", "hoga", "hogi", "bhai", "accha", "acha", "theek", "thik", "matlab",
        "lekin", "aur", "toh", "bhi", "abhi", "jaldi", "bahut", "bohot", "kuch", "sab", "mujhe", "tujhe", "humein", "unko", "usko",
        "wala", "wali", "raha", "rahi", "rahe", "gaya", "gayi", "chalo", "haan", "na", "ji", "ho", "hua", "kaise", "kab", "kahan",
    ]

    /// Romanised Hindi words that never appear in English text (so one is enough to say "not translated").
    private static let onlyHindi: Set<String> = [
        "hai", "hain", "nahi", "nahin", "kya", "kyun", "kyunki", "mein", "yaar", "karo", "karna", "karke", "karenge", "karein",
        "hoga", "hogi", "accha", "acha", "theek", "thik", "matlab", "lekin", "aur", "toh", "abhi", "jaldi", "bahut", "bohot",
        "kuch", "mujhe", "tujhe", "humein", "hume", "unko", "usko", "wala", "wali", "raha", "rahi", "rahe", "gaya", "gayi",
        "chalo", "haan", "hua", "kaise", "kab", "kahan", "chahiye", "pehla", "doosra", "teesra", "pehle", "baad", "lena", "dena",
        "bhej", "bhejo", "rakhna", "batana", "bata", "bolo", "bolna", "sakte", "sakta", "sakti", "tha", "thi", "hoon", "hu",
    ]

    /// How many words in the text are only ever Hindi (romanised).
    static func hinglishLeftovers(_ text: String) -> Int {
        text.lowercased().split(whereSeparator: { !$0.isLetter }).filter { onlyHindi.contains(String($0)) }.count
    }

    static func isHinglish(_ text: String) -> Bool {
        let words = text.lowercased().split(whereSeparator: { !$0.isLetter }).map(String.init)
        guard words.count >= 3, text.unicodeScalars.contains(where: { $0.properties.isAlphabetic && $0.value < 0x250 }) else { return false }
        let hits = words.filter { hinglishWords.contains($0) && $0 != "the" && $0 != "main" && $0 != "na" && $0 != "ho" }.count
        return hits >= 2 && Double(hits) / Double(words.count) >= 0.12
    }

    /// Apple's recognizer on the text, optionally limited to the languages you speak. Returns (code, confidence).
    static func recognize(_ text: String, among hints: [String] = []) -> (String, Double)? {
        let r = NLLanguageRecognizer()
        let constraints = hints.compactMap(nlLanguage)
        if constraints.count >= 2 { r.languageConstraints = constraints }
        r.processString(text)
        guard let (lang, p) = r.languageHypotheses(withMaximum: 1).first else { return nil }
        return (whisperCode(lang), p)
    }

    /// The spoken language, from Whisper's guess (if any), the text and your languages.
    static func detect(text: String, whisperGuess: String?, hints: [String]) -> Detection? {
        guard let d = rawDetect(text: text, whisperGuess: whisperGuess, hints: hints) else { return nil }
        // Spoken Hindi and Urdu are nearly the same, and Whisper often guesses Urdu for Hindi speakers. If you speak
        // Hindi and not Urdu, it's Hindi (then re-heard in Devanagari, since Urdu letters are the wrong script for it).
        if d.code == "ur", hints.contains("hi"), !hints.contains("ur") { return Detection(code: "hi", hinglish: d.hinglish) }
        return d
    }

    private static func rawDetect(text: String, whisperGuess: String?, hints: [String]) -> Detection? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return nil }
        if isHinglish(t) { return Detection(code: "hi", hinglish: true) }
        // Whisper heard the audio, so trust it unless the text clearly says otherwise (checked against every language).
        if let w = whisperGuess, !w.isEmpty {
            if let (code, p) = recognize(t), code != w, p > 0.9, t.split(separator: " ").count >= 6 { return Detection(code: code) }
            return Detection(code: w)
        }
        // No audio guess: a clearly identified language wins; otherwise pick among the languages you speak.
        if let (code, p) = recognize(t), p > 0.8 { return Detection(code: code) }
        return recognize(t, among: hints).map { Detection(code: $0.0) }
    }


    /// A piece of text that reads as a language you don't speak, or uses letters none of your languages use
    /// (Vietnamese-only letters from a misheard Hindi clip, say). Used to catch a misrecognised streamed piece.
    static func looksForeign(_ text: String, hints: [String]) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !hints.isEmpty else { return false }
        if isHinglish(t) { return !hints.contains("hi") }
        // Letters outside every script your languages use.
        let allowed = Set(hints.compactMap { Indic.expectedScript($0) } + [.latin])
        for s in t.unicodeScalars {
            if let sc = Indic.script(of: s), !allowed.contains(sc) { return true }
            // Latin letters only Vietnamese uses (ơ ư, and the stacked-accent block).
            if !hints.contains("vi"), (0x1EA0...0x1EF9).contains(s.value) || [0x01A0, 0x01A1, 0x01AF, 0x01B0].contains(s.value) { return true }
        }
        // Long enough to judge, and clearly another language.
        if t.split(separator: " ").count >= 4, let (code, p) = recognize(t), p > 0.85, !hints.contains(code) { return true }
        return false
    }

    /// How sure Apple's recognizer is that `text` is in `code` (0…1), with no constraints.
    static func confidence(_ text: String, is code: String) -> Double {
        guard let lang = nlLanguage(code) else { return 0 }
        let r = NLLanguageRecognizer()
        r.processString(text)
        return r.languageHypotheses(withMaximum: 5)[lang] ?? 0
    }

    /// Should the clip be transcribed again in one of your languages?
    /// - Heard as a language you don't speak, and the text doesn't clearly read as that language (a shaky guess).
    /// - Or a short clip heard as English that doesn't read as real English ("Hot TK." for "हाँ ठीक है"), when you speak others too.
    static func shouldRetry(text: String, detected: String?, hints: [String]) -> Bool {
        guard let detected, !hints.isEmpty else { return false }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Heard as an Indian language you don't speak while you do speak another one: listen again in yours.
        // Whisper often writes Bengali or Kannada in Hindi letters (or Telugu as Tamil), which then reads
        // confidently as Hindi, so confidence can't be the test. A clear sentence in an unrelated language
        // (Spanish for an English + Hindi speaker) is still kept.
        if !hints.contains(detected), indianNeighbours(detected, hints) { return true }
        if !hints.contains(detected) { return confidence(t, is: detected) < 0.8 }
        let words = t.split(separator: " ").count
        if detected == "en", hints.count > 1, words <= 5, !isHinglish(t) { return confidence(t, is: "en") < 0.5 }
        return false
    }

    /// The language to try instead: the best of yours other than the one Whisper picked.
    static let indian: Set<String> = ["hi", "ur", "bn", "mr", "ne", "ta", "te", "kn", "ml", "gu", "pa", "as", "or"]

    /// Whisper mistook one Indian language for another you speak.
    static func indianNeighbours(_ detected: String, _ hints: [String]) -> Bool {
        indian.contains(detected) && hints.contains(where: { indian.contains($0) && $0 != detected })
    }

    static func alternative(text: String, detected: String?, hints: [String]) -> String? {
        let others = hints.filter { $0 != detected }
        guard !others.isEmpty else { return nil }
        if others.count == 1 { return others[0] }
        return recognize(text, among: others)?.0 ?? others.first
    }


    // MARK: Written language

    /// "Write in" names → the code Apple's recognizer reports.
    static func writtenCode(_ name: String) -> String? { writtenCodes[name] }

    private static let writtenCodes: [String: String] = [
        "English": "en", "Hindi": "hi", "Bengali": "bn", "Marathi": "mr", "Tamil": "ta", "Telugu": "te", "Gujarati": "gu", "Kannada": "kn",
        "Malayalam": "ml", "Punjabi": "pa", "Urdu": "ur", "Nepali": "ne", "Spanish": "es", "French": "fr", "German": "de", "Portuguese": "pt",
        "Italian": "it", "Dutch": "nl", "Swedish": "sv", "Norwegian": "no", "Danish": "da", "Finnish": "fi", "Polish": "pl", "Czech": "cs",
        "Romanian": "ro", "Hungarian": "hu", "Greek": "el", "Ukrainian": "uk", "Russian": "ru", "Turkish": "tr", "Arabic": "ar", "Persian": "fa",
        "Hebrew": "he", "Chinese (Simplified)": "zh", "Chinese (Traditional)": "zh", "Japanese": "ja", "Korean": "ko", "Vietnamese": "vi",
        "Thai": "th", "Indonesian": "id", "Malay": "ms",
    ]

    /// True when `text` is (mostly) in the requested "Write in" language. Unknown targets pass.
    /// Whether speech is already in the "Write in" language, so it needs cleanup but no translation.
    /// Stricter than `matches` on short text: "haan theek hai" is short, but it's Hindi.
    static func alreadyIn(_ text: String, target: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty, !t.isEmpty else { return true }
        guard !target.lowercased().hasPrefix("hinglish"), let code = writtenCodes[target] else { return matches(t, target: target) }
        if code != "hi", isHinglish(t) || hinglishLeftovers(t) > 0 { return false }
        // Letters from a script the target doesn't use (Devanagari or Urdu letters when writing English,
        // or Chinese, Japanese, Korean, Cyrillic… when writing a language in Latin letters).
        let want = Indic.expectedScript(code) ?? .latin
        if t.unicodeScalars.contains(where: { foreignLetter($0, want: want, latinTarget: latinTargets.contains(code)) }) { return false }
        return matches(t, target: target)
    }

    /// Languages written in Latin letters: any other script in their text means it isn't them yet.
    private static let latinTargets: Set<String> = ["en", "es", "fr", "de", "pt", "it", "nl", "sv", "no", "da", "fi", "pl", "cs", "ro", "hu", "tr", "vi", "id", "ms"]

    private static func foreignLetter(_ s: Unicode.Scalar, want: Indic.Script, latinTarget: Bool) -> Bool {
        guard s.properties.isAlphabetic else { return false }
        if let script = Indic.script(of: s) { return script != want }
        // Not a script Indic knows (CJK, Hangul, Cyrillic, Greek, Thai…): foreign for a Latin-letter language.
        return latinTarget
    }

    /// Most of the letters are in a script the target language isn't written in. Works on short text too,
    /// where a word count can't tell (a Chinese sentence is often ten characters with no spaces).
    static func mostlyForeignScript(_ text: String, target: String) -> Bool {
        guard let code = writtenCodes[target] else { return false }
        let want = Indic.expectedScript(code) ?? .latin
        let latin = latinTargets.contains(code)
        guard latin || Indic.expectedScript(code) != nil else { return false }
        let letters = text.unicodeScalars.filter { $0.properties.isAlphabetic }
        guard !letters.isEmpty else { return false }
        let foreign = letters.filter { foreignLetter($0, want: want, latinTarget: latin) }.count
        return Double(foreign) / Double(letters.count) > 0.5
    }

    static func matches(_ text: String, target: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if mostlyForeignScript(t, target: target) { return false }
        guard t.split(separator: " ").count >= 3 || t.count >= 12 else { return true }   // too short to judge
        if target.lowercased().hasPrefix("hinglish") {
            // Hindi in Latin letters: no Devanagari, and recognisably Hindi words.
            return !t.unicodeScalars.contains { (0x0900...0x097F).contains($0.value) } && (isHinglish(t) || t.split(separator: " ").count < 6)
        }
        guard let code = writtenCodes[target] else { return true }
        // Hinglish is written in English letters, so a recogniser can call it English. Any word that's only ever
        // Hindi means it wasn't translated.
        if code != "hi", hinglishLeftovers(t) > 0 { return false }
        guard let (got, p) = recognize(t) else { return true }
        if got == code { return true }
        // Short or name-heavy text can be uncertain; only fail when the recognizer is fairly sure it's something else.
        return p < 0.6
    }

    // MARK: Codes

    private static func nlLanguage(_ code: String) -> NLLanguage? {
        switch code {
        case "zh": return .simplifiedChinese
        case "no", "nn": return .norwegian
        case "jw", "su", "yue", "haw", "la", "ln", "sn": return nil
        default: return NLLanguage(rawValue: code)
        }
    }

    private static func whisperCode(_ lang: NLLanguage) -> String {
        switch lang {
        case .simplifiedChinese, .traditionalChinese: return "zh"
        case .norwegian: return "no"
        default: return String(lang.rawValue.prefix(2))
        }
    }

    /// Whisper's verbose_json reports the language by name ("hindi"); map it to its code.
    static func code(forWhisperName name: String) -> String? {
        let n = name.lowercased()
        if n.count == 2 { return n }
        return Languages.spoken.first { $0.name.lowercased() == n }?.code
    }
}
