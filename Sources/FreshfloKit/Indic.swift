import Foundation
import NaturalLanguage

/// Indian languages written in their own scripts: Hindi in Devanagari (not Urdu letters or romanised), Bengali in
/// Bengali script, and so on, ending sentences with the danda (।) where the language does.
enum Indic {
    enum Script: String { case devanagari, bengali, gurmukhi, gujarati, tamil, telugu, kannada, malayalam, arabic, latin, other }

    /// The script each language is written in.
    static func expectedScript(_ lang: String) -> Script? {
        switch lang {
        case "hi", "mr", "ne", "sa": return .devanagari
        case "bn", "as": return .bengali
        case "pa": return .gurmukhi
        case "gu": return .gujarati
        case "ta": return .tamil
        case "te": return .telugu
        case "kn": return .kannada
        case "ml": return .malayalam
        case "ur": return .arabic
        default: return nil
        }
    }

    static func script(of scalar: Unicode.Scalar) -> Script? {
        switch scalar.value {
        case 0x0900...0x097F, 0xA8E0...0xA8FF: return .devanagari
        case 0x0980...0x09FF: return .bengali
        case 0x0A00...0x0A7F: return .gurmukhi
        case 0x0A80...0x0AFF: return .gujarati
        case 0x0B80...0x0BFF: return .tamil
        case 0x0C00...0x0C7F: return .telugu
        case 0x0C80...0x0CFF: return .kannada
        case 0x0D00...0x0D7F: return .malayalam
        case 0x0600...0x06FF, 0x0750...0x077F, 0xFB50...0xFDFF, 0xFE70...0xFEFF: return .arabic
        case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F: return .latin
        default: return nil
        }
    }

    /// The script most of the letters are in (ignoring digits, punctuation and spaces).
    static func dominantScript(_ text: String) -> Script {
        var counts: [Script: Int] = [:]
        for s in text.unicodeScalars { if let sc = script(of: s) { counts[sc, default: 0] += 1 } }
        return counts.max { $0.value < $1.value }?.key ?? .other
    }

    /// Whisper wrote this language in the wrong script (Hindi in Urdu letters, say). Romanised Hindi is Hinglish
    /// and handled on its own, so Latin never counts as wrong here.
    static func wrongScript(_ text: String, lang: String) -> Bool {
        guard let want = expectedScript(lang) else { return false }
        let got = dominantScript(text)
        return got != want && got != .latin && got != .other
    }

    /// A short sentence in the language's own script. Given to Whisper as preceding context, it steers the output
    /// into that script (and its punctuation) instead of a neighbouring one.
    static func scriptPrompt(_ lang: String) -> String? {
        switch lang {
        case "hi": return "नमस्ते, आज हम योजना पर बात करेंगे।"
        case "mr": return "नमस्कार, आज आपण योजनेबद्दल बोलू."
        case "ne": return "नमस्ते, आज हामी योजनाको बारेमा कुरा गर्छौं।"
        case "bn": return "নমস্কার, আজ আমরা পরিকল্পনা নিয়ে কথা বলব।"
        case "pa": return "ਸਤ ਸ੍ਰੀ ਅਕਾਲ, ਅੱਜ ਅਸੀਂ ਯੋਜਨਾ ਬਾਰੇ ਗੱਲ ਕਰਾਂਗੇ।"
        case "gu": return "નમસ્તે, આજે આપણે યોજના વિશે વાત કરીશું."
        case "ta": return "வணக்கம், இன்று நாம் திட்டத்தைப் பற்றி பேசுவோம்."
        case "te": return "నమస్కారం, ఈ రోజు మనం ప్రణాళిక గురించి మాట్లాడుదాం."
        case "kn": return "ನಮಸ್ಕಾರ, ಇಂದು ನಾವು ಯೋಜನೆಯ ಬಗ್ಗೆ ಮಾತನಾಡೋಣ."
        case "ml": return "നമസ്കാരം, ഇന്ന് നമ്മൾ പദ്ധതിയെക്കുറിച്ച് സംസാരിക്കാം."
        case "ur": return "السلام علیکم، آج ہم منصوبے پر بات کریں گے۔"
        default: return nil
        }
    }

    /// Sentence ends: Hindi, Nepali, Bengali, Assamese and Punjabi use the danda (।); Urdu uses ۔.
    /// Only a full stop right after a letter of that script changes, so numbers, "p.m." and English stay as they are.
    static func punctuate(_ text: String, lang: String? = nil) -> String {
        var s = text
        // Devanagari: Hindi and Nepali use the danda, Marathi uses a full stop.
        let devanagariDanda: Bool = {
            if let lang { return lang != "mr" && lang != "sa" }
            let r = NLLanguageRecognizer()
            r.languageConstraints = [.hindi, .marathi]
            r.processString(text)
            return r.dominantLanguage != .marathi
        }()
        if devanagariDanda, s.unicodeScalars.contains(where: { script(of: $0) == .devanagari }) {
            s = s.replacingOccurrences(of: #"(?<=[\x{0900}-\x{097F}])\.(?=\s|$)"#, with: "।", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: #"(?<=[\x{0980}-\x{09FF}])\.(?=\s|$)"#, with: "।", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?<=[\x{0A00}-\x{0A7F}])\.(?=\s|$)"#, with: "।", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?<=[\x{0600}-\x{06FF}])\.(?=\s|$)"#, with: "۔", options: .regularExpression)
        // No space before a danda.
        s = s.replacingOccurrences(of: #"\s+([।۔])"#, with: "$1", options: .regularExpression)
        return s
    }
}
