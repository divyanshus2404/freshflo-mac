import Foundation

/// Providers retire models regularly; this picks a working replacement instead of failing.
enum ModelResolver {
    enum Kind {
        case chat, transcription
    }

    /// Called with the missing model and its replacement so settings can remember it in the right slot
    /// (smart calls carry the smart model in `cleanupModel`).
    static var onResolved: ((_ kind: Kind, _ missing: String, _ replacement: String) -> Void)?

    private static let chatPreferences = [
        "qwen/qwen3.8-27b", "openai/gpt-oss-20b", "openai/gpt-oss-120b", "gpt-4.1-mini", "gpt-4o-mini", "gpt-5-mini",
        "llama-3.3-70b-versatile", "llama-3.1-8b-instant",
    ]
    private static let transcriptionPreferences = [
        "whisper-large-v3-turbo", "gpt-4o-mini-transcribe", "gpt-4o-transcribe", "whisper-large-v3", "whisper-1",
    ]
    private static let notChat = ["whisper", "guard", "tts", "orpheus", "embed", "safeguard", "transcribe", "moderation", "dall-e", "image", "audio"]

    static func isModelMissing(_ error: Error) -> Bool {
        guard case APIError.http(let code, let message) = error else { return false }
        let m = message.lowercased()
        return code == 404 || ((code == 400 || code == 403) && m.contains("model") && (m.contains("not") || m.contains("decommission")))
    }

    static func best(_ kind: Kind, endpoint: ProviderEndpoint) async -> String? {
        guard let ids = try? await OpenAICompatible.models(endpoint), !ids.isEmpty else { return nil }
        return pick(kind, replacing: kind == .chat ? endpoint.cleanupModel : endpoint.transcriptionModel, from: ids)
    }

    /// Nemotron sizes, largest first; a replacement keeps the size that was asked for.
    private static let nemotronTiers = ["ultra", "super", "nano", "lightning"]

    /// A working replacement for `missing` among the provider's `ids`.
    static func pick(_ kind: Kind, replacing missing: String, from ids: [String]) -> String? {
        let candidates = ids.filter { $0 != missing }.sorted()
        let available = Set(candidates)
        switch kind {
        case .chat:
            // Token Factory ids are case-sensitive ("nvidia/NVIDIA-Nemotron-3-Nano-30B-A3B"): the same model, spelled right.
            if let same = candidates.first(where: { $0.caseInsensitiveCompare(missing) == .orderedSame }) { return same }
            // Prefer an NVIDIA Nemotron model when the provider serves one (e.g. Nebius Token Factory), so the app
            // stays on an NVIDIA open model, and keep the tier: Ultra for reasoning, Super or Nano for fast calls.
            let nemotrons = candidates.filter { $0.lowercased().contains("nemotron") && !notChat.contains(where: $0.lowercased().contains) }
            let wanted = missing.lowercased()
            for tier in nemotronTiers where wanted.contains(tier) {
                if let match = nemotrons.first(where: { $0.lowercased().contains(tier) }) { return match }
            }
            if let nemotron = nemotrons.first
                ?? candidates.first(where: { $0.lowercased().hasPrefix("nvidia/") && !notChat.contains(where: $0.lowercased().contains) }) {
                return nemotron
            }
            return chatPreferences.first(where: available.contains)
                ?? candidates.first { id in !notChat.contains(where: id.lowercased().contains) }
        case .transcription:
            return transcriptionPreferences.first(where: available.contains)
                ?? candidates.first { $0.contains("whisper") || $0.contains("transcribe") }
        }
    }
}
