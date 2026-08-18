import Foundation

struct TabSession: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var selectedTabID: UUID?
    var tabs: [TabRecord]

    init(
        schemaVersion: Int = TabSession.currentSchemaVersion,
        selectedTabID: UUID?,
        tabs: [TabRecord]
    ) {
        self.schemaVersion = schemaVersion
        self.selectedTabID = selectedTabID
        self.tabs = tabs
    }
}

enum TabStoreError: LocalizedError {
    case unsupportedSchema(Int)
    case sessionTooLarge
    case invalidRecord

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "The saved tab session uses unsupported schema version \(version)."
        case .sessionTooLarge:
            return "The saved tab session exceeds its safety limit."
        case .invalidRecord:
            return "The saved tab session contains invalid data."
        }
    }
}

actor TabStore {
    private let explicitFileURL: URL?
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        explicitFileURL = fileURL
        self.fileManager = fileManager

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func load() throws -> TabSession? {
        let url = try sessionFileURL(createDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let data: Data
            do {
                data = try BoundedFileReader.read(
                    from: url,
                    maximumByteCount: SafePersistence.maximumTabSessionBytes,
                    fileManager: fileManager
                )
            } catch {
                throw TabStoreError.sessionTooLarge
            }
            try BoundedJSONPreflight.validate(
                data,
                maximumStructuralTokens: SafePersistence.maximumTabCount * 32
            )
            let session = try decoder.decode(TabSession.self, from: data)
            guard session.schemaVersion == TabSession.currentSchemaVersion else {
                throw TabStoreError.unsupportedSchema(session.schemaVersion)
            }
            return normalized(session)
        } catch {
            quarantineCorruptSession(at: url)
            throw error
        }
    }

    func save(_ session: TabSession) throws {
        let url = try sessionFileURL(createDirectory: true)
        let data = try encoder.encode(normalized(session))
        guard data.count <= SafePersistence.maximumTabSessionBytes else {
            throw TabStoreError.sessionTooLarge
        }
        try data.write(to: url, options: [.atomic])
        try AppDataProtectionPolicy.apply(to: url, category: .browserState, fileManager: fileManager)
    }

    func clear() throws {
        let url = try sessionFileURL(createDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private func sessionFileURL(createDirectory: Bool) throws -> URL {
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
        return directory.appendingPathComponent("Tabs-v1.json", isDirectory: false)
    }

    private func normalized(_ session: TabSession) -> TabSession {
        let records = session.tabs.prefix(SafePersistence.maximumTabCount).compactMap { record -> TabRecord? in
            guard !record.isPrivate else { return nil }
            if let url = record.url, !SafePersistence.isSafePersistedURL(url) {
                return nil
            }
            var normalized = record
            normalized.title = SafePersistence.title(record.title)
            normalized.faviconURL = record.faviconURL.flatMap {
                FaviconURLPolicy.validatedRemoteURL($0, relativeTo: record.url)
            }
            normalized.snapshotFileName = record.snapshotFileName.flatMap(SafePersistence.snapshotFileName)
            return normalized
        }
        let selected = session.selectedTabID.flatMap { id in records.contains(where: { $0.id == id }) ? id : nil }
        return TabSession(selectedTabID: selected, tabs: records)
    }

    private func quarantineCorruptSession(at url: URL) {
        let target = url.deletingLastPathComponent().appendingPathComponent(
            "\(url.lastPathComponent).corrupt-\(UUID().uuidString)"
        )
        if (try? fileManager.moveItem(at: url, to: target)) != nil {
            try? AppDataProtectionPolicy.apply(to: target, category: .browserState, fileManager: fileManager)
        }
    }
}
