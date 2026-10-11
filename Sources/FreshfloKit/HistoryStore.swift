import Foundation
import Combine

final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()
    private static let limit = 500

    @Published private(set) var items: [HistoryItem] = []
    private let fileURL: URL

    private init() {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Freshflo", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("history.json")
        if let data = try? Data(contentsOf: fileURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            items = (try? decoder.decode([HistoryItem].self, from: data)) ?? []
        }
    }

    var last: HistoryItem? { items.first }

    func add(_ item: HistoryItem) {
        UsageStats.shared.record(words: item.wordCount, seconds: item.duration, on: item.date)
        items.insert(item, at: 0)
        if items.count > Self.limit { items.removeLast(items.count - Self.limit) }
        persist()
    }

    func delete(_ item: HistoryItem) {
        items.removeAll { $0.id == item.id }
        persist()
    }

    func clear() {
        items.removeAll()
        persist()
    }

    private func persist() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(items) else { return }
        try? data.write(to: fileURL, options: [.atomic])
    }
}
