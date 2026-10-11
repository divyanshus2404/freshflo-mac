import Foundation

/// Providers retire models regularly; this picks a working replacement instead of failing.
enum ModelResolver {
    enum Kind {
        case chat, transcription
    }

    /// Called with the replacement so settings can remember it.
    static var onResolved: ((Kind, String) -> Void)?

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
        let available = Set(ids)
        switch kind {
        case .chat:
            return chatPreferences.first(where: available.contains)
                ?? ids.sorted().first { id in !notChat.contains(where: id.lowercased().contains) }
        case .transcription:
            return transcriptionPreferences.first(where: available.contains)
                ?? ids.first { $0.contains("whisper") || $0.contains("transcribe") }
        }
    }
}
