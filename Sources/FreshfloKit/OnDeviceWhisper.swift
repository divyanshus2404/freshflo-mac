import Foundation
import WhisperKit

/// OpenAI's Whisper (large-v3 turbo) running on this Mac's Neural Engine through WhisperKit.
/// Cloud-level accuracy with no key, no rate limits, no internet after the one-time download, and nothing leaves the Mac.
enum OnDeviceWhisper {
    /// Quantized large-v3 turbo: about 630 MB, close to full large-v3 accuracy, fast on Apple Silicon.
    static let model = "openai_whisper-large-v3-v20240930_turbo_632MB"
    static let sizeLabel = "about 630 MB"

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Freshflo/Models", isDirectory: true)
    }
    private static var modelFolder: URL {
        folder.appendingPathComponent("models/argmaxinc/whisperkit-coreml/\(model)", isDirectory: true)
    }

    /// The model files are on disk.
    static var isDownloaded: Bool {
        FileManager.default.fileExists(atPath: modelFolder.appendingPathComponent("AudioEncoder.mlmodelc").path)
    }

    /// Whether dictation should use it right now.
    static var isActive: Bool { AppSettings.shared.useOnDeviceWhisper && isDownloaded }

    private actor Holder {
        var kit: WhisperKit?
        func get() async throws -> WhisperKit {
            if let kit { return kit }
            let config = WhisperKitConfig(model: OnDeviceWhisper.model, downloadBase: OnDeviceWhisper.folder,
                                          modelFolder: OnDeviceWhisper.isDownloaded ? OnDeviceWhisper.modelFolder.path : nil,
                                          verbose: false, prewarm: true, load: true, download: true)
            let made = try await WhisperKit(config)
            kit = made
            return made
        }
        func drop() { kit = nil }
    }
    private static let holder = Holder()

    /// Downloads the model (once) and loads it. `progress` gets 0…1 during the download.
    static func download(progress: @escaping @Sendable (Double) -> Void) async throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if !isDownloaded {
            _ = try await WhisperKit.download(variant: model, downloadBase: folder) { p in progress(p.fractionCompleted) }
        }
        progress(1)
        _ = try await holder.get()
    }

    /// Loads the model in the background so the first dictation isn't slow.
    static func prewarm() {
        guard isActive else { return }
        Task.detached(priority: .utility) { _ = try? await holder.get() }
    }

    static func delete() async {
        await holder.drop()
        try? FileManager.default.removeItem(at: folder)
    }

    private static func options(language: String, vocabulary: [String], timestamps: Bool) -> DecodingOptions {
        var o = DecodingOptions(task: .transcribe, language: language.isEmpty ? nil : language, temperature: 0,
                                usePrefillPrompt: true, detectLanguage: language.isEmpty,
                                skipSpecialTokens: true, withoutTimestamps: !timestamps)
        o.chunkingStrategy = .vad
        _ = vocabulary
        return o
    }

    /// 16 kHz mono samples → text.
    static func transcribe(_ samples: [Float], language: String, vocabulary: [String]) async throws -> String {
        let kit = try await holder.get()
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options(language: language, vocabulary: vocabulary, timestamps: false))
        return Transcriber.stripHallucinations(results.map(\.text).joined(separator: " ")
            .replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// For meetings and files: timestamped segments.
    static func segments(_ samples: [Float], language: String, vocabulary: [String]) async throws -> [Transcriber.Segment] {
        let kit = try await holder.get()
        let results = try await kit.transcribe(audioArray: samples, decodeOptions: options(language: language, vocabulary: vocabulary, timestamps: true))
        return results.flatMap(\.segments).compactMap { seg in
            let text = Transcriber.stripHallucinations(seg.text.replacingOccurrences(of: #"<\|[^|]*\|>"#, with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces))
            return text.isEmpty ? nil : Transcriber.Segment(start: Double(seg.start), text: text)
        }
    }
}
