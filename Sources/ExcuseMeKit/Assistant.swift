import Foundation

/// General-purpose LLM calls (meeting notes, Ask mode, re-polish): cloud when available, Apple on-device otherwise.
@MainActor
enum Assistant {
    static var isAvailable: Bool { AppSettings.shared.canUseCloud || AppleModel.isAvailable }

    static func complete(instructions: String, prompt: String, temperature: Double = 0.3) async throws -> String {
        let settings = AppSettings.shared
        if settings.canUseCloud {
            return try await Cleanup.chat(instructions: instructions, prompt: prompt, endpoint: settings.endpoint.smart, temperature: temperature)
        }
        guard AppleModel.isAvailable else { throw CommandError.noModel }
        return try await AppleModel.respond(instructions: instructions, prompt: prompt)
    }

    /// Long inputs: the on-device model has a small context window, so summarize in pieces and then combine.
    static func completeLong(instructions: String, text: String, chunkInstructions: String) async throws -> String {
        let limit = AppSettings.shared.canUseCloud ? 100_000 : 6_000
        guard text.count > limit else { return try await complete(instructions: instructions, prompt: text) }
        var partials: [String] = []
        for chunk in chunks(text, size: limit) {
            partials.append(try await complete(instructions: chunkInstructions, prompt: chunk, temperature: 0.2))
        }
        return try await complete(instructions: instructions, prompt: "Notes from consecutive parts of one transcript:\n\n" + partials.joined(separator: "\n\n---\n\n"))
    }

    private static func chunks(_ text: String, size: Int) -> [String] {
        var result: [String] = []
        var current = ""
        for line in text.components(separatedBy: "\n") {
            if current.count + line.count > size, !current.isEmpty {
                result.append(current)
                current = ""
            }
            current += line + "\n"
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    /// Pulls the first JSON object out of a model reply (models sometimes wrap it in prose or fences).
    static func jsonObject(in text: String) -> [String: Any]? {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end,
              let data = String(text[start...end]).data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
}
