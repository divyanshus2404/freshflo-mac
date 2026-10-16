import Foundation

enum APIError: LocalizedError {
    case missingKey
    case badURL
    case http(Int, String)
    case badResponse

    var errorDescription: String? {
        switch self {
        case .missingKey: return "Add an API key in Settings"
        case .badURL: return "Invalid API base URL"
        case .http(429, _): return "Rate limit reached: wait a moment, or switch to On-device in Settings"
        case .http(401, _), .http(403, _): return "API key rejected: check it in Settings"
        case .http(let code, let message): return message.isEmpty ? "API error \(code)" : "API error \(code): \(message)"
        case .badResponse: return "Unexpected API response"
        }
    }
}

enum OpenAICompatible {
    static let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 90
        config.httpMaximumConnectionsPerHost = 4
        return URLSession(configuration: config)
    }()

    static func request(_ endpoint: ProviderEndpoint, path: String) throws -> URLRequest {
        guard let url = URL(string: endpoint.baseURL + path), url.scheme != nil else { throw APIError.badURL }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        if !endpoint.apiKey.isEmpty {
            req.setValue("Bearer \(endpoint.apiKey)", forHTTPHeaderField: "Authorization")
        }
        return req
    }

    /// Cheap authenticated call used by the settings "Test" button.
    static func verify(_ endpoint: ProviderEndpoint) async throws {
        var req = try request(endpoint, path: "/models")
        req.httpMethod = "GET"
        _ = try await send(req)
    }

    static func models(_ endpoint: ProviderEndpoint) async throws -> [String] {
        var req = try request(endpoint, path: "/models")
        req.httpMethod = "GET"
        let json = try await send(req)
        return (json["data"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
    }

    /// Opens DNS/TLS/HTTP2 to the provider while the user is still talking, so the upload starts immediately.
    static func prewarm(_ endpoint: ProviderEndpoint) {
        guard var req = try? request(endpoint, path: "/models") else { return }
        req.httpMethod = "GET"
        req.timeoutInterval = 5
        session.dataTask(with: req).resume()
    }

    static func send(_ req: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: req)
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard let http = response as? HTTPURLResponse else { throw APIError.badResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = ((json?["error"] as? [String: Any])?["message"] as? String)
                ?? String(data: data, encoding: .utf8)?.prefix(200).description ?? ""
            throw APIError.http(http.statusCode, message)
        }
        guard let json else { throw APIError.badResponse }
        return json
    }
}

enum Transcriber {
    /// Clips longer than this are uploaded as AAC instead of WAV.
    private static let compressAfterSeconds = 10.0

    static func transcribe(samples raw: [Float], endpoint: ProviderEndpoint, vocabulary: [String]) async throws -> String {
        let samples = AudioRecorder.normalizeQuiet(raw)
        do {
            return try await transcribeOnce(samples: samples, endpoint: endpoint, vocabulary: vocabulary)
        } catch where ModelResolver.isModelMissing(error) {
            guard let model = await ModelResolver.best(.transcription, endpoint: endpoint), model != endpoint.transcriptionModel else { throw error }
            ModelResolver.onResolved?(.transcription, model)
            var fixed = endpoint
            fixed.transcriptionModel = model
            return try await transcribeOnce(samples: samples, endpoint: fixed, vocabulary: vocabulary)
        }
    }

    private static func transcribeOnce(samples: [Float], endpoint: ProviderEndpoint, vocabulary: [String]) async throws -> String {
        let prompt = vocabularyPrompt(vocabulary)
        let seconds = Double(samples.count) / AudioRecorder.sampleRate
        if seconds > compressAfterSeconds, let aac = try? AudioRecorder.m4a(from: samples) {
            do {
                return try await withRetry { try await upload(aac, filename: "audio.m4a", mime: "audio/mp4", endpoint: endpoint, prompt: prompt) }
            } catch APIError.http(400, _) {
                // Some OpenAI-compatible servers reject AAC; fall through to WAV.
            }
        }
        let wav = AudioRecorder.wav(from: samples)
        return try await withRetry { try await upload(wav, filename: "audio.wav", mime: "audio/wav", endpoint: endpoint, prompt: prompt) }
    }

    /// Uploads an existing audio file as-is (mp3, m4a, wav, ogg/opus voice notes, webm, flac).
    static func transcribeFile(data: Data, filename: String, endpoint: ProviderEndpoint, vocabulary: [String]) async throws -> String {
        let ext = (filename as NSString).pathExtension.lowercased()
        // Groq/OpenAI accept Opus in an Ogg container but only under the .ogg name.
        let name = ext == "opus" ? (filename as NSString).deletingPathExtension + ".ogg" : filename
        return try await retryOnNetwork {
            try await upload(data, filename: name, mime: mime(for: ext), endpoint: endpoint, prompt: vocabularyPrompt(vocabulary))
        }
    }

    struct Segment {
        var start: Double
        var text: String
    }

    /// Timestamped transcription (used by meeting notes to interleave speakers).
    static func transcribeSegments(data: Data, filename: String, endpoint: ProviderEndpoint, vocabulary: [String]) async throws -> [Segment] {
        let json = try await retryOnNetworkJSON {
            try await uploadJSON(data, filename: filename, mime: mime(for: (filename as NSString).pathExtension.lowercased()),
                                 endpoint: endpoint, prompt: vocabularyPrompt(vocabulary), format: "verbose_json")
        }
        let segments = (json["segments"] as? [[String: Any]] ?? []).compactMap { s -> Segment? in
            guard let text = (s["text"] as? String)?.trimmingCharacters(in: .whitespaces), !text.isEmpty else { return nil }
            return Segment(start: (s["start"] as? Double) ?? 0, text: stripHallucinations(text))
        }.filter { !$0.text.isEmpty }
        if segments.isEmpty, let text = json["text"] as? String, !text.isEmpty { return [Segment(start: 0, text: text)] }
        return segments
    }

    private static func retryOnNetworkJSON(_ attempt: () async throws -> [String: Any]) async throws -> [String: Any] {
        do {
            return try await attempt()
        } catch where isNetworkError(error) {
            try await Task.sleep(nanoseconds: 800_000_000)
            return try await attempt()
        }
    }

    static let directUploadExtensions: Set<String> = ["mp3", "mpga", "mpeg", "m4a", "mp4", "wav", "ogg", "opus", "webm", "flac"]

    private static func mime(for ext: String) -> String {
        switch ext {
        case "mp3", "mpga", "mpeg": return "audio/mpeg"
        case "m4a", "mp4": return "audio/mp4"
        case "wav": return "audio/wav"
        case "ogg", "opus": return "audio/ogg"
        case "webm": return "audio/webm"
        case "flac": return "audio/flac"
        default: return "application/octet-stream"
        }
    }

    /// Whisper uses the prompt as preceding context, which biases it toward these spellings.
    static func vocabularyPrompt(_ words: [String]) -> String? {
        let cleaned = words.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard !cleaned.isEmpty else { return nil }
        return "Vocabulary: " + cleaned.prefix(80).joined(separator: ", ") + "."
    }

    static func isNetworkError(_ error: Error) -> Bool {
        if error is URLError { return true }
        if case APIError.http(let code, _) = error { return code >= 500 || code == 429 }
        return false
    }

    /// Removes phrases Whisper is known to invent from silence or noise (subtitle credits and the like).
    static func stripHallucinations(_ text: String) -> String {
        let patterns = [
            #"(?i)\bthanks? (?:you )?for watching[.!]?"#,
            #"(?i)\bplease (?:like and )?subscribe[^.!?]*[.!?]?"#,
            #"(?i)subtitles? (?:by|created by)[^.!?]*[.!?]?"#,
            #"(?i)\bamara\.org[^.!?]*[.!?]?"#,
            #"(?i)transcribed by[^.!?]*[.!?]?"#,
        ]
        var result = text
        for p in patterns {
            result = result.replacingOccurrences(of: p, with: "", options: .regularExpression)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func withRetry(_ attempt: () async throws -> String) async throws -> String {
        do {
            return try await retryOnNetwork(attempt)
        } catch where ModelResolver.isModelMissing(error) {
            throw error
        }
    }

    /// Retries transient failures (network drops, 429 rate limits, 5xx) with backoff: 0.4 s, then 1.2 s.
    private static func retryOnNetwork(_ attempt: () async throws -> String) async throws -> String {
        var delays: [UInt64] = [400_000_000, 1_200_000_000]
        while true {
            do {
                return try await attempt()
            } catch where isNetworkError(error) && !delays.isEmpty {
                try await Task.sleep(nanoseconds: delays.removeFirst())
            }
        }
    }

    /// The language Whisper reported for the most recent upload ("hi", "en"…), when the server says.
    nonisolated(unsafe) static var lastLanguage: String?

    private static func upload(_ audio: Data, filename: String, mime: String, endpoint: ProviderEndpoint, prompt: String?) async throws -> String {
        // Groq's verbose_json also reports the detected language, at no extra cost.
        let verbose = endpoint.baseURL.contains("groq.com")
        let json = try await uploadJSON(audio, filename: filename, mime: mime, endpoint: endpoint, prompt: prompt, format: verbose ? "verbose_json" : "json")
        lastLanguage = (json["language"] as? String).flatMap(LanguageID.code(forWhisperName:)) ?? (endpoint.language.isEmpty ? nil : endpoint.language)
        guard let text = json["text"] as? String else { throw APIError.badResponse }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func uploadJSON(_ audio: Data, filename: String, mime: String, endpoint: ProviderEndpoint,
                                   prompt: String?, format: String) async throws -> [String: Any] {
        var req = try OpenAICompatible.request(endpoint, path: "/audio/transcriptions")
        let boundary = "Freshflo-\(UUID().uuidString)"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")

        var body = Data()
        func field(_ name: String, _ value: String) {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n\(value)\r\n".utf8))
        }
        field("model", endpoint.transcriptionModel)
        field("response_format", format)
        field("temperature", "0")
        if !endpoint.language.isEmpty { field("language", endpoint.language) }
        if let prompt { field("prompt", prompt) }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        body.append(audio)
        body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        req.httpBody = body

        return try await OpenAICompatible.send(req)
    }
}
