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

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "The saved tab session uses unsupported schema version \(version)."
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
        let data = try Data(contentsOf: url)
        let session = try decoder.decode(TabSession.self, from: data)
        guard session.schemaVersion == TabSession.currentSchemaVersion else {
            throw TabStoreError.unsupportedSchema(session.schemaVersion)
        }
        return session
    }

    func save(_ session: TabSession) throws {
        let url = try sessionFileURL(createDirectory: true)
        let data = try encoder.encode(session)
        try data.write(to: url, options: [.atomic])
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
}
