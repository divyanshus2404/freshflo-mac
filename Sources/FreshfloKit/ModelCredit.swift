import SwiftUI

/// Says which model wrote something ("nvidia/nemotron-3-super-120b-a12b · Nebius Token Factory"), so notes, chat answers
/// and commitments show what produced them instead of a generic "AI".
enum ModelCredit {
    static let appleOnDevice = "Apple on-device model"

    static func host(_ baseURL: String) -> String {
        let url = baseURL.lowercased()
        if url.contains("nebius") { return "Nebius Token Factory" }
        if url.contains("groq.com") { return "Groq" }
        if url.contains("openai.com") { return "OpenAI" }
        return URL(string: baseURL)?.host ?? baseURL
    }

    static func label(model: String, baseURL: String) -> String { "\(model) · \(host(baseURL))" }

    /// The model the last cloud call used (it can differ from settings after a rate-limit or retired-model fallback).
    static func current(_ settings: AppSettings) -> String {
        guard settings.canUseCloud else { return appleOnDevice }
        let endpoint = settings.endpoint.smart
        return label(model: Cleanup.lastModel ?? endpoint.cleanupModel, baseURL: endpoint.baseURL)
    }

    /// What would answer right now, before any call has been made.
    static func configured(_ settings: AppSettings) -> String? {
        if settings.canUseCloud { return label(model: settings.endpoint.smart.cleanupModel, baseURL: settings.endpoint.baseURL) }
        return AppleModel.isAvailable ? appleOnDevice : nil
    }

    struct Parts: Equatable {
        let headline: String
        let model: String
        let nvidia: Bool
    }

    static func parts(_ credit: String) -> Parts {
        let pieces = credit.components(separatedBy: " · ")
        let model = pieces[0], host = pieces.count > 1 ? pieces[1] : ""
        let nvidia = model.lowercased().contains("nemotron") || model.lowercased().hasPrefix("nvidia/")
        if credit == appleOnDevice { return Parts(headline: appleOnDevice, model: "", nvidia: false) }
        let name = nvidia ? "NVIDIA Nemotron" : model
        return Parts(headline: host.isEmpty ? name : "\(name) on \(host)", model: nvidia ? model : "", nvidia: nvidia)
    }
}

/// A small capsule naming the model: "NVIDIA Nemotron on Nebius Token Factory  nvidia/nemotron-…  · 1.4 s".
struct ModelBadge: View {
    let credit: String
    var extra: String? = nil

    private static let nvidiaGreen = Color(red: 0.46, green: 0.73, blue: 0)

    var body: some View {
        let parts = ModelCredit.parts(credit)
        let tint = parts.nvidia ? Self.nvidiaGreen : Color.secondary
        HStack(spacing: 5) {
            Image(systemName: parts.nvidia ? "cpu" : "sparkles")
            Text(parts.headline).fontWeight(.semibold)
            if !parts.model.isEmpty { Text(parts.model).font(.caption2.monospaced()).foregroundStyle(.secondary) }
            if let extra { Text("· \(extra)").foregroundStyle(.secondary) }
        }
        .font(.caption)
        .foregroundStyle(tint)
        .lineLimit(1)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background(Capsule().fill(tint.opacity(0.12)))
        .help("Written by \(credit)")
        .accessibilityLabel("Written by \(parts.headline)")
    }
}
