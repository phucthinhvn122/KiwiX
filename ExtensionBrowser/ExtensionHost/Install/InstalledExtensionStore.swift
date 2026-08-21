import Foundation

/// One installed extension, as recorded on disk.
///
/// The granted sets are stored as sorted arrays rather than `Set`. `JSONEncoder` writes a set as an
/// array in whatever order hashing produced, so two saves of identical state would emit different
/// bytes — which defeats `.sortedKeys` and makes a diff of the catalog meaningless.
public struct InstalledExtensionRecord: Codable, Equatable, Sendable {
    /// The content-digest identifier. Also the name of the directory holding the unpacked files.
    public let identifier: String
    public var displayName: String
    /// `ExtensionPackage.Format.rawValue`, deliberately a `String` and not the enum: decoding an
    /// unknown case throws, and one unreadable record must not take the whole catalog with it.
    public let format: String
    /// Chromium a-p id of the signing key, when there was a signature to check.
    public let publisherIdentifier: String?
    public let isSignatureVerified: Bool
    public let installedAt: Date
    public var isEnabled: Bool
    public var grantedPermissions: [String]
    public var grantedMatchPatterns: [String]

    public init(
        identifier: String,
        displayName: String,
        format: String,
        publisherIdentifier: String?,
        isSignatureVerified: Bool,
        installedAt: Date,
        isEnabled: Bool,
        grantedPermissions: [String],
        grantedMatchPatterns: [String]
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.format = format
        self.publisherIdentifier = publisherIdentifier
        self.isSignatureVerified = isSignatureVerified
        self.installedAt = installedAt
        self.isEnabled = isEnabled
        self.grantedPermissions = grantedPermissions
        self.grantedMatchPatterns = grantedMatchPatterns
    }

    /// - Parameter installedAt: injected rather than read from the clock, so a test can assert on
    ///   the encoded bytes.
    public static func make(
        staged: StagedExtensionPackage,
        displayName: String,
        grantedPermissions: Set<String>,
        grantedMatchPatterns: Set<String>,
        installedAt: Date,
        isEnabled: Bool = true
    ) -> InstalledExtensionRecord {
        let publisher: String?
        switch staged.signature {
        case .verified(let publisherIdentifier):
            publisher = publisherIdentifier
        case .unsigned:
            publisher = nil
        }
        return InstalledExtensionRecord(
            identifier: staged.identity.identifier.rawValue,
            displayName: displayName,
            format: staged.format.rawValue,
            publisherIdentifier: publisher,
            isSignatureVerified: staged.signature.isVerified,
            installedAt: installedAt,
            isEnabled: isEnabled,
            grantedPermissions: grantedPermissions.sorted(),
            grantedMatchPatterns: grantedMatchPatterns.sorted()
        )
    }
}

extension InstalledExtensionRecord {
    /// What this record means to the host. Never `trustFirstPartyBundle`: that policy exists for
    /// bundles the app ships, and nothing installed from a file can reach it.
    var permissionPolicy: WebExtensionPermissionPolicy {
        .userGranted(
            permissions: Set(grantedPermissions),
            matchPatterns: Set(grantedMatchPatterns)
        )
    }
}

struct InstalledExtensionCatalog: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    var schemaVersion: Int
    var extensions: [InstalledExtensionRecord]

    init(
        schemaVersion: Int = InstalledExtensionCatalog.currentSchemaVersion,
        extensions: [InstalledExtensionRecord]
    ) {
        self.schemaVersion = schemaVersion
        self.extensions = extensions
    }
}

enum InstalledExtensionStoreError: LocalizedError, Equatable {
    case unsupportedSchema(Int)
    case catalogTooLarge
    case notInstalled(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedSchema(let version):
            return "The installed-extension catalog uses unsupported schema version \(version)."
        case .catalogTooLarge:
            return "The installed-extension catalog exceeds its safety limit."
        case .notInstalled(let identifier):
            return "Extension \(identifier) is not installed."
        }
    }
}

/// Where installed extensions and their catalog live.
///
/// Both sit under the Application Support directory the tab session already uses, so one data
/// protection policy and one "delete my data" path cover everything the browser keeps.
enum ExtensionStorageLocation {
    static func container(fileManager: FileManager = .default, create: Bool) throws -> URL {
        let applicationSupport = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: create
        )
        let directory = applicationSupport.appendingPathComponent("ExtensionBrowser", isDirectory: true)
        if create {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }

    /// Parent of the per-extension resource directories. `ExtensionPackageInstaller.commit` names
    /// each child after the extension identifier.
    static func installRoot(fileManager: FileManager = .default, create: Bool) throws -> URL {
        let root = try container(fileManager: fileManager, create: create)
            .appendingPathComponent("Extensions", isDirectory: true)
        if create {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        }
        return root
    }

    static func catalogURL(fileManager: FileManager = .default, create: Bool) throws -> URL {
        try container(fileManager: fileManager, create: create)
            .appendingPathComponent("Extensions-v1.json", isDirectory: false)
    }
}

/// The record of what is installed and what the user agreed to.
///
/// This file is the authority on permissions, not the loaded contexts: every context is rebuilt from
/// it at launch. Corrupt input is quarantined and rethrown rather than repaired, because the
/// alternative — salvaging a partly-readable permission list — could silently widen a grant.
actor InstalledExtensionStore {
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

    // MARK: - Reading

    /// - Returns: an empty array when nothing has ever been installed. Throws only when a catalog
    ///   exists and cannot be trusted.
    func load() throws -> [InstalledExtensionRecord] {
        let url = try catalogURL(createDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        do {
            let data: Data
            do {
                data = try BoundedFileReader.read(
                    from: url,
                    maximumByteCount: SafePersistence.maximumExtensionCatalogBytes,
                    fileManager: fileManager
                )
            } catch {
                throw InstalledExtensionStoreError.catalogTooLarge
            }
            // A record carries *two* bounded lists — permissions and match patterns — plus its own
            // keys, so the budget has to be `2 × entries + overhead` per extension. Counting one
            // list put the ceiling at half of what `normalized(_:)` accepts: a catalog this store
            // had itself written could fail preflight on the next launch, get quarantined, and take
            // every installed extension with it while leaving the unpacked files as orphans.
            let tokensPerRecord = SafePersistence.maximumGrantedEntryCount * 2 + 32
            try BoundedJSONPreflight.validate(
                data,
                maximumStructuralTokens: SafePersistence.maximumInstalledExtensionCount * tokensPerRecord
            )
            let catalog = try decoder.decode(InstalledExtensionCatalog.self, from: data)
            guard catalog.schemaVersion == InstalledExtensionCatalog.currentSchemaVersion else {
                throw InstalledExtensionStoreError.unsupportedSchema(catalog.schemaVersion)
            }
            return normalized(catalog.extensions)
        } catch {
            quarantineCorruptCatalog(at: url)
            throw error
        }
    }

    // MARK: - Writing

    func replaceAll(_ records: [InstalledExtensionRecord]) throws {
        try save(normalized(records))
    }

    /// Adds a record, or replaces the one with the same identifier.
    ///
    /// Replacing is how reinstall works: the identifier is a content digest, so the same bytes
    /// arriving twice must not produce two entries pointing at one directory.
    @discardableResult
    func upsert(_ record: InstalledExtensionRecord) throws -> [InstalledExtensionRecord] {
        var records = try loadTolerantly()
        if let index = records.firstIndex(where: { $0.identifier == record.identifier }) {
            records[index] = record
        } else {
            guard records.count < SafePersistence.maximumInstalledExtensionCount else {
                throw ExtensionInstallError.tooManyInstalledExtensions(
                    limit: SafePersistence.maximumInstalledExtensionCount
                )
            }
            records.append(record)
        }
        let normalizedRecords = normalized(records)
        try save(normalizedRecords)
        return normalizedRecords
    }

    @discardableResult
    func remove(identifier: String) throws -> [InstalledExtensionRecord] {
        var records = try loadTolerantly()
        guard records.contains(where: { $0.identifier == identifier }) else {
            throw InstalledExtensionStoreError.notInstalled(identifier)
        }
        records.removeAll { $0.identifier == identifier }
        let normalizedRecords = normalized(records)
        try save(normalizedRecords)
        return normalizedRecords
    }

    @discardableResult
    func setEnabled(_ isEnabled: Bool, for identifier: String) throws -> [InstalledExtensionRecord] {
        var records = try loadTolerantly()
        guard let index = records.firstIndex(where: { $0.identifier == identifier }) else {
            throw InstalledExtensionStoreError.notInstalled(identifier)
        }
        records[index].isEnabled = isEnabled
        let normalizedRecords = normalized(records)
        try save(normalizedRecords)
        return normalizedRecords
    }

    func clear() throws {
        let url = try catalogURL(createDirectory: false)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    // MARK: - Internals

    /// A mutation must not be blocked forever by a catalog that failed to decode once. `load()` has
    /// already quarantined the bad file by the time this returns, so the write lands on a clean
    /// slate instead of on top of something unreadable.
    private func loadTolerantly() throws -> [InstalledExtensionRecord] {
        do {
            return try load()
        } catch {
            AppLog.extensions.error("Installed-extension catalog was unreadable; starting a new one")
            return []
        }
    }

    private func save(_ records: [InstalledExtensionRecord]) throws {
        let url = try catalogURL(createDirectory: true)
        let data = try encoder.encode(InstalledExtensionCatalog(extensions: records))
        guard data.count <= SafePersistence.maximumExtensionCatalogBytes else {
            throw InstalledExtensionStoreError.catalogTooLarge
        }
        try data.write(to: url, options: [.atomic])
        try AppDataProtectionPolicy.apply(to: url, category: .browserState, fileManager: fileManager)
    }

    /// Enforces every bound the type system cannot. Anything failing a structural check is dropped
    /// rather than corrected: a record whose identifier is not a real identifier has no directory to
    /// point at, and a permission string nobody can display is not a grant worth keeping.
    private func normalized(_ records: [InstalledExtensionRecord]) -> [InstalledExtensionRecord] {
        var seen = Set<String>()
        var result: [InstalledExtensionRecord] = []
        for record in records {
            guard result.count < SafePersistence.maximumInstalledExtensionCount else { break }
            guard ExtensionIdentifier(rawValue: record.identifier) != nil else { continue }
            guard seen.insert(record.identifier).inserted else { continue }

            var normalizedRecord = record
            normalizedRecord.displayName = displayName(record.displayName, fallback: record.identifier)
            normalizedRecord.grantedPermissions = grantedEntries(record.grantedPermissions)
            normalizedRecord.grantedMatchPatterns = grantedEntries(record.grantedMatchPatterns)
            result.append(normalizedRecord)
        }
        return result
    }

    private func displayName(_ value: String, fallback: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let safe = SafeInput.displayText(
            trimmed,
            maximumByteCount: SafePersistence.maximumExtensionNameBytes,
            allowsNewlines: false
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return safe.isEmpty ? fallback : safe
    }

    /// Permission and match-pattern strings originate in a manifest, which is attacker-controlled
    /// text. They are compared against runtime values, so each one is kept verbatim or dropped —
    /// never rewritten, because a truncated match pattern is a different match pattern.
    private func grantedEntries(_ values: [String]) -> [String] {
        var unique = Set<String>()
        for value in values where !value.isEmpty {
            guard value.utf8.count <= SafePersistence.maximumGrantedEntryBytes,
                  SafeInput.isSafeDisplayText(value, allowsNewlines: false) else { continue }
            unique.insert(value)
            if unique.count >= SafePersistence.maximumGrantedEntryCount { break }
        }
        return unique.sorted()
    }

    private func catalogURL(createDirectory: Bool) throws -> URL {
        if let explicitFileURL {
            if createDirectory {
                try fileManager.createDirectory(
                    at: explicitFileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
            }
            return explicitFileURL
        }
        return try ExtensionStorageLocation.catalogURL(fileManager: fileManager, create: createDirectory)
    }

    private func quarantineCorruptCatalog(at url: URL) {
        let target = url.deletingLastPathComponent().appendingPathComponent(
            "\(url.lastPathComponent).corrupt-\(UUID().uuidString)"
        )
        if (try? fileManager.moveItem(at: url, to: target)) != nil {
            try? AppDataProtectionPolicy.apply(to: target, category: .browserState, fileManager: fileManager)
        }
    }
}
