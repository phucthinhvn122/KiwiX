import Foundation

public actor ExtensionRepository {
    public static let didChangeNotification = Notification.Name("ExtensionRepository.didChange")

    public let baseDirectoryURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(baseDirectoryURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let baseDirectoryURL {
            self.baseDirectoryURL = baseDirectoryURL
        } else {
            let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.baseDirectoryURL = applicationSupport
                .appendingPathComponent("ExtensionBrowser", isDirectory: true)
                .appendingPathComponent("Extensions", isDirectory: true)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    public func installedExtensions() throws -> [InstalledExtension] {
        try ensureBaseDirectory()
        let children = try fileManager.contentsOfDirectory(
            at: baseDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsSubdirectoryDescendants]
        )
        return try children.compactMap { directory in
            guard !directory.lastPathComponent.hasPrefix("."),
                  (try? directory.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
            else { return nil }
            return try loadExtension(at: directory)
        }.sorted { $0.metadata.name.localizedCaseInsensitiveCompare($1.metadata.name) == .orderedAscending }
    }

    public func extensionWithID(_ identifier: ExtensionIdentifier) throws -> InstalledExtension? {
        try ensureBaseDirectory()
        let directory = directoryURL(for: identifier)
        guard fileManager.fileExists(atPath: directory.path) else { return nil }
        return try loadExtension(at: directory)
    }

    public func install(_ preview: ExtensionPackagePreview) throws -> InstalledExtension {
        try ensureBaseDirectory()
        let finalDirectory = directoryURL(for: preview.id)
        if fileManager.fileExists(atPath: finalDirectory.path) {
            if let existing = try? loadExtension(at: finalDirectory),
               existing.metadata.packageDigest != preview.packageDigest {
                throw ExtensionInstallError.identifierCollision(preview.id.rawValue)
            }
            throw ExtensionInstallError.packageAlreadyInstalled(preview.id.rawValue)
        }

        let transaction = baseDirectoryURL.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        let filesURL = transaction.appendingPathComponent("files", isDirectory: true)
        let storageURL = transaction.appendingPathComponent("storage", isDirectory: true)
        do {
            try fileManager.createDirectory(at: filesURL, withIntermediateDirectories: true, attributes: nil)
            try fileManager.createDirectory(at: storageURL, withIntermediateDirectories: true, attributes: nil)
            for item in try fileManager.contentsOfDirectory(
                at: preview.stagedDirectoryURL,
                includingPropertiesForKeys: nil,
                options: []
            ) {
                try fileManager.copyItem(at: item, to: filesURL.appendingPathComponent(item.lastPathComponent))
            }

            let manifestSource = preview.stagedDirectoryURL.appendingPathComponent("manifest.json", isDirectory: false)
            try fileManager.copyItem(at: manifestSource, to: transaction.appendingPathComponent("manifest.json"))
            let metadata = ExtensionMetadata(
                id: preview.id,
                manifest: preview.manifest,
                packageDigest: preview.packageDigest
            )
            try write(metadata, to: transaction.appendingPathComponent("metadata.json"))
            try write([String: JSONValue](), to: storageURL.appendingPathComponent("local.json"))
            try fileManager.moveItem(at: transaction, to: finalDirectory)
            postChange()
            return InstalledExtension(metadata: metadata, manifest: preview.manifest, directoryURL: finalDirectory)
        } catch {
            try? fileManager.removeItem(at: transaction)
            throw error
        }
    }

    public func setEnabled(_ enabled: Bool, extensionID: ExtensionIdentifier) throws -> InstalledExtension {
        guard var installed = try extensionWithID(extensionID) else {
            throw ExtensionRuntimeError.extensionNotFound(extensionID.rawValue)
        }
        var metadata = installed.metadata
        metadata.isEnabled = enabled
        metadata.updatedAt = Date()
        try write(metadata, to: installed.directoryURL.appendingPathComponent("metadata.json"))
        installed = InstalledExtension(metadata: metadata, manifest: installed.manifest, directoryURL: installed.directoryURL)
        postChange()
        return installed
    }

    public func setPrivateBrowsingAllowed(_ allowed: Bool, extensionID: ExtensionIdentifier) throws -> InstalledExtension {
        guard var installed = try extensionWithID(extensionID) else {
            throw ExtensionRuntimeError.extensionNotFound(extensionID.rawValue)
        }
        var metadata = installed.metadata
        metadata.allowInPrivateBrowsing = allowed
        metadata.updatedAt = Date()
        try write(metadata, to: installed.directoryURL.appendingPathComponent("metadata.json"))
        installed = InstalledExtension(metadata: metadata, manifest: installed.manifest, directoryURL: installed.directoryURL)
        postChange()
        return installed
    }

    public func remove(extensionID: ExtensionIdentifier) throws {
        let directory = directoryURL(for: extensionID)
        guard fileManager.fileExists(atPath: directory.path) else {
            throw ExtensionRuntimeError.extensionNotFound(extensionID.rawValue)
        }
        try fileManager.removeItem(at: directory)
        postChange()
    }

    public func resourceData(
        extensionID: ExtensionIdentifier,
        path: String,
        maximumBytes: Int = 16 * 1_024 * 1_024
    ) throws -> Data {
        guard let installed = try extensionWithID(extensionID) else {
            throw ExtensionRuntimeError.extensionNotFound(extensionID.rawValue)
        }
        let url = try ExtensionResourcePath.containedURL(for: path, under: installed.filesURL)
        let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values?.isRegularFile == true else { throw ExtensionRuntimeError.resourceNotFound(path) }
        guard (values?.fileSize ?? 0) <= maximumBytes else {
            throw ExtensionRuntimeError.unavailable("resource exceeds the read limit")
        }
        return try Data(contentsOf: url, options: [.mappedIfSafe])
    }

    private func directoryURL(for identifier: ExtensionIdentifier) -> URL {
        baseDirectoryURL.appendingPathComponent(identifier.rawValue, isDirectory: true)
    }

    private func ensureBaseDirectory() throws {
        try fileManager.createDirectory(at: baseDirectoryURL, withIntermediateDirectories: true, attributes: nil)
    }

    private func loadExtension(at directory: URL) throws -> InstalledExtension {
        let metadataData = try Data(contentsOf: directory.appendingPathComponent("metadata.json"))
        let manifestData = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        let metadata = try decoder.decode(ExtensionMetadata.self, from: metadataData)
        let manifest = try ManifestParser().parse(data: manifestData)
        return InstalledExtension(metadata: metadata, manifest: manifest, directoryURL: directory)
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic])
    }

    private func postChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}
