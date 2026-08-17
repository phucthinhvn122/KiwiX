import Foundation

enum DownloadStoreError: LocalizedError {
    case unsupportedSchema(Int)
    case metadataTooLarge
    case invalidSourceURL
    case invalidLocalFileURL

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "The saved downloads use unsupported schema version \(version)."
        case .metadataTooLarge:
            return "The downloads metadata exceeds its size limit."
        case .invalidSourceURL:
            return "The download source URL is invalid or too long."
        case .invalidLocalFileURL:
            return "The downloaded file is outside the Downloads directory."
        }
    }
}

private struct DownloadStoreDocument: Codable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var items: [DownloadItem]
}

actor DownloadStore {
    private let explicitFileURL: URL?
    private let explicitDownloadsDirectoryURL: URL?
    private let fileManager: FileManager
    private let maximumItemCount: Int
    private let maximumMetadataByteCount: Int
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        fileURL: URL? = nil,
        downloadsDirectoryURL: URL? = nil,
        fileManager: FileManager = .default,
        maximumItemCount: Int = 500,
        maximumMetadataByteCount: Int = 1_048_576
    ) {
        explicitFileURL = fileURL
        explicitDownloadsDirectoryURL = downloadsDirectoryURL
        self.fileManager = fileManager
        self.maximumItemCount = max(1, maximumItemCount)
        self.maximumMetadataByteCount = max(1_024, maximumMetadataByteCount)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func items() throws -> [DownloadItem] {
        try loadItems().sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    func upsert(_ item: DownloadItem, isPrivate: Bool) throws {
        guard !isPrivate, !item.isPrivate else { return }
        let normalized = try normalizedItem(item)
        var current = try loadItems()

        if let index = current.firstIndex(where: { $0.id == normalized.id }) {
            // Ignore a late progress write that arrived after a newer terminal update.
            guard current[index].updatedAt <= normalized.updatedAt else { return }
            current[index] = normalized
        } else {
            current.append(normalized)
        }

        current.sort { $0.createdAt > $1.createdAt }
        if current.count > maximumItemCount {
            current.removeLast(current.count - maximumItemCount)
        }
        try saveItems(current)
    }

    @discardableResult
    func remove(id: UUID) throws -> DownloadItem? {
        var current = try loadItems()
        guard let index = current.firstIndex(where: { $0.id == id }) else { return nil }
        let removed = current.remove(at: index)
        try saveItems(current)
        return removed
    }

    @discardableResult
    func clearFinished() throws -> [DownloadItem] {
        let current = try loadItems()
        let removed = current.filter { $0.status.isFinished }
        try saveItems(current.filter { !$0.status.isFinished })
        return removed
    }

    @discardableResult
    func clear() throws -> [DownloadItem] {
        let current = try loadItems()
        let fileURL = try metadataFileURL(createDirectory: false)
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
        return current
    }

    private func loadItems() throws -> [DownloadItem] {
        let fileURL = try metadataFileURL(createDirectory: false)
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }

        let attributes = try fileManager.attributesOfItem(atPath: fileURL.path)
        if let byteCount = (attributes[.size] as? NSNumber)?.intValue,
           byteCount > maximumMetadataByteCount {
            throw DownloadStoreError.metadataTooLarge
        }

        let data = try Data(contentsOf: fileURL, options: [.mappedIfSafe])
        guard data.count <= maximumMetadataByteCount else {
            throw DownloadStoreError.metadataTooLarge
        }
        let document = try decoder.decode(DownloadStoreDocument.self, from: data)
        guard document.schemaVersion == DownloadStoreDocument.currentSchemaVersion else {
            throw DownloadStoreError.unsupportedSchema(document.schemaVersion)
        }

        var seenIDs = Set<UUID>()
        return document.items.compactMap { item in
            guard !item.isPrivate,
                  seenIDs.insert(item.id).inserted,
                  let normalized = try? normalizedItem(item) else {
                return nil
            }
            return normalized
        }
    }

    private func saveItems(_ items: [DownloadItem]) throws {
        var boundedItems = Array(items.prefix(maximumItemCount))
        var data = try encodedDocument(items: boundedItems)
        while data.count > maximumMetadataByteCount, !boundedItems.isEmpty {
            boundedItems.removeLast()
            data = try encodedDocument(items: boundedItems)
        }
        guard data.count <= maximumMetadataByteCount else {
            throw DownloadStoreError.metadataTooLarge
        }

        let fileURL = try metadataFileURL(createDirectory: true)
        try data.write(to: fileURL, options: [.atomic])
    }

    private func encodedDocument(items: [DownloadItem]) throws -> Data {
        try encoder.encode(
            DownloadStoreDocument(
                schemaVersion: DownloadStoreDocument.currentSchemaVersion,
                items: items
            )
        )
    }

    private func normalizedItem(_ item: DownloadItem) throws -> DownloadItem {
        var normalized = item
        normalized.fileName = DownloadFilePath.sanitizedFilename(item.fileName)
        normalized.bytesReceived = max(0, item.bytesReceived)
        normalized.totalBytesExpected = item.totalBytesExpected.flatMap { $0 > 0 ? $0 : nil }

        if let sourceURL = item.sourceURL {
            guard sourceURL.absoluteString.utf8.count <= 4_096 else {
                throw DownloadStoreError.invalidSourceURL
            }
            var components = URLComponents(url: sourceURL, resolvingAgainstBaseURL: false)
            components?.user = nil
            components?.password = nil
            normalized.sourceURL = components?.url ?? sourceURL
        }

        normalized.mimeType = boundedText(item.mimeType, maximumUTF8Count: 255)
        normalized.errorDescription = boundedText(item.errorDescription, maximumUTF8Count: 512)

        if let localFileURL = item.localFileURL {
            let downloadsDirectory = try downloadsDirectoryURL()
            guard DownloadFilePath.isDirectChild(localFileURL, of: downloadsDirectory) else {
                throw DownloadStoreError.invalidLocalFileURL
            }
            normalized.localFileURL = localFileURL.standardizedFileURL
        }
        return normalized
    }

    private func boundedText(_ value: String?, maximumUTF8Count: Int) -> String? {
        guard let value else { return nil }
        let clean = String(value.unicodeScalars.filter {
            !CharacterSet.controlCharacters.contains($0) || $0 == "\n"
        })
        var result = ""
        for character in clean {
            let candidate = result + String(character)
            guard candidate.utf8.count <= maximumUTF8Count else { break }
            result = candidate
        }
        return result.isEmpty ? nil : result
    }

    private func metadataFileURL(createDirectory: Bool) throws -> URL {
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
        return directory.appendingPathComponent("Downloads-v1.json", isDirectory: false)
    }

    private func downloadsDirectoryURL() throws -> URL {
        if let explicitDownloadsDirectoryURL {
            return explicitDownloadsDirectoryURL.standardizedFileURL
        }
        return try DownloadFilePath.defaultDirectory(fileManager: fileManager).standardizedFileURL
    }
}
