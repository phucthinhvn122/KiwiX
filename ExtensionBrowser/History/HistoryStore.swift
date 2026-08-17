import Foundation

actor HistoryStore {
    private let explicitFileURL: URL?
    private let fileManager: FileManager
    private let maximumEntryCount: Int
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        fileURL: URL? = nil,
        fileManager: FileManager = .default,
        maximumEntryCount: Int = 2_000
    ) {
        explicitFileURL = fileURL
        self.fileManager = fileManager
        self.maximumEntryCount = max(1, maximumEntryCount)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func entries() throws -> [HistoryEntry] {
        try loadEntries().sorted { $0.visitedAt > $1.visitedAt }
    }

    func recordVisit(url: URL, title: String, at date: Date = Date()) throws {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return }
        var current = try loadEntries()
        current.insert(HistoryEntry(title: title, url: url, visitedAt: date), at: 0)
        if current.count > maximumEntryCount {
            current.removeLast(current.count - maximumEntryCount)
        }
        try saveEntries(current)
    }

    func clear() throws {
        let fileURL = try historyFileURL(createDirectory: false)
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL)
    }

    func remove(id: UUID) throws {
        var current = try loadEntries()
        let previousCount = current.count
        current.removeAll { $0.id == id }
        guard current.count != previousCount else { return }
        if current.isEmpty {
            try clear()
        } else {
            try saveEntries(current)
        }
    }

    private func loadEntries() throws -> [HistoryEntry] {
        let fileURL = try historyFileURL(createDirectory: false)
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        return try decoder.decode([HistoryEntry].self, from: Data(contentsOf: fileURL))
    }

    private func saveEntries(_ entries: [HistoryEntry]) throws {
        let fileURL = try historyFileURL(createDirectory: true)
        try encoder.encode(entries).write(to: fileURL, options: [.atomic])
    }

    private func historyFileURL(createDirectory: Bool) throws -> URL {
        if let explicitFileURL {
            if createDirectory {
                try fileManager.createDirectory(
                    at: explicitFileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            }
            return explicitFileURL
        }

        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: createDirectory
        )
        let directory = applicationSupport.appendingPathComponent("ExtensionBrowser", isDirectory: true)
        if createDirectory {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory.appendingPathComponent("History-v1.json")
    }
}
