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

    func recordVisit(
        url: URL,
        title: String,
        at date: Date = Date(),
        isPrivate: Bool = false
    ) throws {
        guard !isPrivate,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              SafePersistence.isSafePersistedURL(url) else { return }
        var current = try loadEntries()
        let safeTitle = SafePersistence.title(title)

        // Revisiting the address that is already on top moves that row rather than adding one.
        // Without this, a page that reloads itself — a dashboard on a timer, a redirect loop, a user
        // holding the reload button — writes 2_000 identical rows and evicts every other site the
        // person actually visited. The row keeps its identifier so a swipe-to-delete already in
        // flight in `HistoryViewController` still refers to the same entry.
        if let newest = current.first, newest.url == url {
            current[0] = HistoryEntry(id: newest.id, title: safeTitle, url: url, visitedAt: date)
            try saveEntries(current)
            return
        }

        current.insert(HistoryEntry(title: safeTitle, url: url, visitedAt: date), at: 0)
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
        let data: Data
        do {
            data = try BoundedFileReader.read(
                from: fileURL,
                maximumByteCount: SafePersistence.maximumHistoryBytes,
                fileManager: fileManager
            )
        } catch {
            quarantineCorruptHistory(at: fileURL)
            return []
        }
        do {
            try BoundedJSONPreflight.validate(
                data,
                maximumStructuralTokens: maximumEntryCount * 16
            )
            let decoded = try decoder.decode([HistoryEntry].self, from: data)
            return decoded.prefix(maximumEntryCount).filter {
                SafePersistence.isSafePersistedURL($0.url) &&
                    $0.title.utf8.count <= SafePersistence.maximumTitleBytes
            }
        } catch {
            quarantineCorruptHistory(at: fileURL)
            return []
        }
    }

    private func saveEntries(_ entries: [HistoryEntry]) throws {
        let fileURL = try historyFileURL(createDirectory: true)
        let bounded = Array(entries.prefix(maximumEntryCount))

        // The common case by a wide margin: the whole list fits, and the binary search below would
        // spend ~log2(2_000) ≈ 11 full re-encodes of up to 8 MiB to rediscover that. This runs once
        // per page load, so paying for the search unconditionally is eleven encodes and eleven
        // allocations of the entire history on every navigation.
        var best = try encoder.encode(bounded)
        if best.count > SafePersistence.maximumHistoryBytes {
            var lower = 0
            var upper = bounded.count - 1
            best = Data("[]".utf8)
            while lower <= upper {
                let count = (lower + upper) / 2
                let data = try encoder.encode(Array(bounded.prefix(count)))
                if data.count <= SafePersistence.maximumHistoryBytes {
                    best = data
                    lower = count + 1
                } else {
                    upper = count - 1
                }
            }
        }
        try best.write(to: fileURL, options: [.atomic])
        try AppDataProtectionPolicy.apply(to: fileURL, category: .browserState, fileManager: fileManager)
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

    private func quarantineCorruptHistory(at url: URL) {
        let target = url.deletingLastPathComponent().appendingPathComponent(
            "\(url.lastPathComponent).corrupt-\(UUID().uuidString)"
        )
        if (try? fileManager.moveItem(at: url, to: target)) != nil {
            try? AppDataProtectionPolicy.apply(to: target, category: .browserState, fileManager: fileManager)
        }
    }
}
