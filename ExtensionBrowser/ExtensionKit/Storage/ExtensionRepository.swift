import Foundation

public actor ExtensionRepository {
    public static let didChangeNotification = Notification.Name("ExtensionRepository.didChange")

    public let baseDirectoryURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let maximumMetadataBytes = 256 * 1_024
    private let maximumInstalledExtensionCount: Int
    private let maximumDirectoryEntriesToInspect: Int
    /// Full verification runs on repository scans. Resource reads reuse the verified
    /// snapshot so a multi-file extension is not rehashed once per resource.
    private var verifiedExtensions: [ExtensionIdentifier: InstalledExtension] = [:]
    private var hasVerifiedSnapshot = false

    public init(
        baseDirectoryURL: URL? = nil,
        fileManager: FileManager = .default,
        maximumInstalledExtensionCount: Int = 128
    ) {
        self.fileManager = fileManager
        let boundedExtensionCount = min(max(1, maximumInstalledExtensionCount), 512)
        self.maximumInstalledExtensionCount = boundedExtensionCount
        maximumDirectoryEntriesToInspect = min(2_048, max(256, boundedExtensionCount * 4))
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
        let listing = try BoundedDirectoryReader.directChildren(
            of: baseDirectoryURL,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles],
            maximumEntryCount: maximumDirectoryEntriesToInspect,
            fileManager: fileManager
        )
        if listing.wasTruncated {
            AppLog.extensions.warning("Extension directory inspection was truncated at the safety limit")
            throw ExtensionRuntimeError.unavailable("extension repository contains too many entries")
        }
        var installed: [InstalledExtension] = []
        var nextVerified: [ExtensionIdentifier: InstalledExtension] = [:]
        for directory in listing.entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard installed.count < maximumInstalledExtensionCount else { break }
            guard !directory.lastPathComponent.hasPrefix("."),
                  (try? directory.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]))
                    .map({ $0.isDirectory == true && $0.isSymbolicLink != true }) == true
            else { continue }
            do {
                let item = try loadExtension(at: directory)
                installed.append(item)
                nextVerified[item.id] = item
            } catch {
                quarantine(directory, reason: error)
            }
        }
        verifiedExtensions = nextVerified
        hasVerifiedSnapshot = true
        return installed.sorted {
            $0.metadata.name.localizedCaseInsensitiveCompare($1.metadata.name) == .orderedAscending
        }
    }

    public func extensionWithID(_ identifier: ExtensionIdentifier) throws -> InstalledExtension? {
        try ensureBaseDirectory()
        let directory = directoryURL(for: identifier)
        guard fileManager.fileExists(atPath: directory.path) else { return nil }
        if let verified = verifiedExtensions[identifier] { return verified }
        let installed = try loadExtension(at: directory)
        verifiedExtensions[identifier] = installed
        hasVerifiedSnapshot = true
        return installed
    }

    /// Fast path for high-frequency browser chrome refreshes. The cache is populated by a
    /// full verified scan and replaced on every repository mutation/runtime reload.
    public func verifiedExtensionsSnapshot() throws -> [InstalledExtension] {
        if !hasVerifiedSnapshot {
            return try installedExtensions()
        }
        return verifiedExtensions.values.sorted {
            $0.metadata.name.localizedCaseInsensitiveCompare($1.metadata.name) == .orderedAscending
        }
    }

    public func install(_ preview: ExtensionPackagePreview) throws -> InstalledExtension {
        try ensureBaseDirectory()
        let stagedIdentity = try ExtensionIdentityGenerator.identity(forDirectory: preview.stagedDirectoryURL)
        guard stagedIdentity.identifier == preview.id, stagedIdentity.digest == preview.packageDigest else {
            throw ExtensionRuntimeError.integrityCheckFailed("staged package identity does not match its preview")
        }
        let finalDirectory = directoryURL(for: preview.id)
        if fileManager.fileExists(atPath: finalDirectory.path) {
            do {
                let existing = try loadExtension(at: finalDirectory)
                if existing.metadata.packageDigest != preview.packageDigest {
                    throw ExtensionInstallError.identifierCollision(preview.id.rawValue)
                }
                throw ExtensionInstallError.packageAlreadyInstalled(preview.id.rawValue)
            } catch let error as ExtensionInstallError {
                throw error
            } catch {
                quarantine(finalDirectory, reason: error)
                guard !fileManager.fileExists(atPath: finalDirectory.path) else {
                    throw ExtensionRuntimeError.integrityCheckFailed(
                        "corrupt installed extension could not be quarantined for reinstall"
                    )
                }
                verifiedExtensions.removeValue(forKey: preview.id)
            }
        }
        guard try installedExtensions().count < maximumInstalledExtensionCount else {
            throw ExtensionInstallError.tooManyInstalledExtensions(limit: maximumInstalledExtensionCount)
        }

        let transaction = baseDirectoryURL.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        let filesURL = transaction.appendingPathComponent("files", isDirectory: true)
        let storageURL = transaction.appendingPathComponent("storage", isDirectory: true)
        do {
            try fileManager.createDirectory(at: storageURL, withIntermediateDirectories: true, attributes: nil)
            try SafeZIPExtractor().copyDirectory(
                from: preview.stagedDirectoryURL,
                to: filesURL,
                fileManager: fileManager
            )

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
            try AppDataProtectionPolicy.protectRecursively(
                finalDirectory,
                category: .browserState,
                fileManager: fileManager
            )
            let installed = try loadExtension(at: finalDirectory)
            verifiedExtensions[installed.id] = installed
            hasVerifiedSnapshot = true
            postChange()
            return installed
        } catch {
            try? fileManager.removeItem(at: transaction)
            if fileManager.fileExists(atPath: finalDirectory.path) {
                try? fileManager.removeItem(at: finalDirectory)
            }
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
        return finishMetadataMutation(installed)
    }

    public func setPrivateBrowsingAllowed(_ allowed: Bool, extensionID: ExtensionIdentifier) throws -> InstalledExtension {
        guard !allowed else {
            throw ExtensionRuntimeError.permissionDenied("extensions are disabled in private browsing")
        }
        guard var installed = try extensionWithID(extensionID) else {
            throw ExtensionRuntimeError.extensionNotFound(extensionID.rawValue)
        }
        var metadata = installed.metadata
        metadata.allowInPrivateBrowsing = allowed
        metadata.updatedAt = Date()
        try write(metadata, to: installed.directoryURL.appendingPathComponent("metadata.json"))
        installed = InstalledExtension(metadata: metadata, manifest: installed.manifest, directoryURL: installed.directoryURL)
        return finishMetadataMutation(installed)
    }

    public func setCapability(
        _ capability: ExtensionCapability,
        granted: Bool,
        extensionID: ExtensionIdentifier
    ) throws -> InstalledExtension {
        guard var installed = try extensionWithID(extensionID),
              installed.manifest.permissions.contains(capability.rawValue) else {
            throw ExtensionRuntimeError.permissionDenied(capability.rawValue)
        }
        var metadata = installed.metadata
        var grants = Set(metadata.grantedPermissions).intersection(installed.manifest.permissions)
        if granted { grants.insert(capability.rawValue) } else { grants.remove(capability.rawValue) }
        metadata.grantedPermissions = grants.sorted()
        metadata.updatedAt = Date()
        try write(metadata, to: installed.directoryURL.appendingPathComponent("metadata.json"))
        installed = InstalledExtension(metadata: metadata, manifest: installed.manifest, directoryURL: installed.directoryURL)
        return finishMetadataMutation(installed)
    }

    public func setHostPermission(
        _ pattern: String,
        granted: Bool,
        extensionID: ExtensionIdentifier
    ) throws -> InstalledExtension {
        guard var installed = try extensionWithID(extensionID) else {
            throw ExtensionRuntimeError.extensionNotFound(extensionID.rawValue)
        }
        let declared = try declaredHostPatterns(for: installed.manifest)
        let requested = try WebExtensionMatchPattern(pattern)
        guard declared.contains(where: { $0.encompasses(requested) }) else {
            throw ExtensionRuntimeError.permissionDenied(pattern)
        }
        var metadata = installed.metadata
        var grants = Set(metadata.grantedHostPermissions.filter { source in
            guard let existing = try? WebExtensionMatchPattern(source) else { return false }
            return declared.contains(where: { $0.encompasses(existing) })
        })
        if granted { grants.insert(pattern) } else { grants.remove(pattern) }
        metadata.grantedHostPermissions = grants.sorted()
        metadata.updatedAt = Date()
        try write(metadata, to: installed.directoryURL.appendingPathComponent("metadata.json"))
        installed = InstalledExtension(metadata: metadata, manifest: installed.manifest, directoryURL: installed.directoryURL)
        return finishMetadataMutation(installed)
    }

    /// Adds or removes the narrow grants corresponding to one concrete website. Broad
    /// manifest patterns are never persisted for this operation.
    public func setWebsitePermission(
        hostname rawHostname: String,
        granted: Bool,
        extensionID: ExtensionIdentifier
    ) throws -> InstalledExtension {
        guard var installed = try extensionWithID(extensionID) else {
            throw ExtensionRuntimeError.extensionNotFound(extensionID.rawValue)
        }
        let hostname = rawHostname
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        let declared = try declaredHostPatterns(for: installed.manifest)
        let narrowed = Set(declared.compactMap { $0.narrowed(toHostname: hostname)?.source })
        guard !narrowed.isEmpty else {
            throw ExtensionRuntimeError.permissionDenied("website \(SafeInput.utf8Prefix(hostname, maximumByteCount: 253))")
        }

        var metadata = installed.metadata
        var grants = Set(metadata.grantedHostPermissions)
        if granted {
            grants.formUnion(narrowed)
        } else {
            grants = Set(grants.filter { source in
                guard let existing = try? WebExtensionMatchPattern(source) else { return false }
                return existing.exactHostname != hostname
            })
        }
        metadata.grantedHostPermissions = grants.sorted()
        metadata.updatedAt = Date()
        try write(metadata, to: installed.directoryURL.appendingPathComponent("metadata.json"))
        installed = InstalledExtension(metadata: metadata, manifest: installed.manifest, directoryURL: installed.directoryURL)
        return finishMetadataMutation(installed)
    }

    public func replaceHostPermissions(
        withDeclaredPermissions grantAll: Bool,
        extensionID: ExtensionIdentifier
    ) throws -> InstalledExtension {
        guard var installed = try extensionWithID(extensionID) else {
            throw ExtensionRuntimeError.extensionNotFound(extensionID.rawValue)
        }
        var metadata = installed.metadata
        metadata.grantedHostPermissions = grantAll
            ? Array(Set(installed.manifest.hostPermissions + installed.manifest.contentScripts.flatMap(\.matches))).sorted()
            : []
        metadata.updatedAt = Date()
        try write(metadata, to: installed.directoryURL.appendingPathComponent("metadata.json"))
        installed = InstalledExtension(metadata: metadata, manifest: installed.manifest, directoryURL: installed.directoryURL)
        return finishMetadataMutation(installed)
    }

    public func replaceHostPermissions(
        withWebsiteHostname rawHostname: String,
        extensionID: ExtensionIdentifier
    ) throws -> InstalledExtension {
        guard var installed = try extensionWithID(extensionID) else {
            throw ExtensionRuntimeError.extensionNotFound(extensionID.rawValue)
        }
        let hostname = rawHostname
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        let grants = Set(try declaredHostPatterns(for: installed.manifest).compactMap {
            $0.narrowed(toHostname: hostname)?.source
        })
        guard !grants.isEmpty else {
            throw ExtensionRuntimeError.permissionDenied("website \(SafeInput.utf8Prefix(hostname, maximumByteCount: 253))")
        }
        var metadata = installed.metadata
        metadata.grantedHostPermissions = grants.sorted()
        metadata.updatedAt = Date()
        try write(metadata, to: installed.directoryURL.appendingPathComponent("metadata.json"))
        installed = InstalledExtension(metadata: metadata, manifest: installed.manifest, directoryURL: installed.directoryURL)
        return finishMetadataMutation(installed)
    }

    public func remove(extensionID: ExtensionIdentifier) throws {
        let directory = directoryURL(for: extensionID)
        guard fileManager.fileExists(atPath: directory.path) else {
            throw ExtensionRuntimeError.extensionNotFound(extensionID.rawValue)
        }
        try fileManager.removeItem(at: directory)
        verifiedExtensions.removeValue(forKey: extensionID)
        hasVerifiedSnapshot = true
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
        do {
            return try BoundedFileReader.read(
                from: url,
                maximumByteCount: maximumBytes,
                fileManager: fileManager
            )
        } catch BoundedFileReadError.tooLarge {
            throw ExtensionRuntimeError.unavailable("resource exceeds the read limit")
        } catch {
            throw ExtensionRuntimeError.resourceNotFound(path)
        }
    }

    private func directoryURL(for identifier: ExtensionIdentifier) -> URL {
        baseDirectoryURL.appendingPathComponent(identifier.rawValue, isDirectory: true)
    }

    private func ensureBaseDirectory() throws {
        try fileManager.createDirectory(at: baseDirectoryURL, withIntermediateDirectories: true, attributes: nil)
    }

    private func loadExtension(at directory: URL) throws -> InstalledExtension {
        let root = baseDirectoryURL.standardizedFileURL
        let candidate = directory.standardizedFileURL
        let rootValues = try candidate.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard candidate.deletingLastPathComponent() == root,
              rootValues.isDirectory == true,
              rootValues.isSymbolicLink != true else {
            throw ExtensionRuntimeError.integrityCheckFailed("extension directory is not a contained regular directory")
        }
        let directoryName = directory.lastPathComponent
        guard let directoryID = ExtensionIdentifier(rawValue: directoryName) else {
            throw ExtensionRuntimeError.integrityCheckFailed("invalid extension directory name")
        }
        let metadataURL = directory.appendingPathComponent("metadata.json")
        let manifestURL = directory.appendingPathComponent("manifest.json")
        let filesURL = directory.appendingPathComponent("files", isDirectory: true)
        let packagedManifestURL = filesURL.appendingPathComponent("manifest.json", isDirectory: false)
        let metadataData = try boundedFileData(at: metadataURL, maximumBytes: maximumMetadataBytes)
        let manifestData = try boundedFileData(at: manifestURL, maximumBytes: ManifestParser.maximumManifestBytes)
        let packagedManifestData = try boundedFileData(
            at: packagedManifestURL,
            maximumBytes: ManifestParser.maximumManifestBytes
        )
        guard manifestData == packagedManifestData else {
            throw ExtensionRuntimeError.integrityCheckFailed("installed manifest copies disagree")
        }
        try BoundedJSONPreflight.validate(metadataData, maximumStructuralTokens: 4_096)
        let metadata = try decoder.decode(ExtensionMetadata.self, from: metadataData)
        let manifest = try ManifestParser().parse(data: manifestData)
        let declaredHostPatterns = try declaredHostPatterns(for: manifest)
        let storedHostPatterns = try metadata.grantedHostPermissions.map(WebExtensionMatchPattern.init)
        guard metadata.id == directoryID,
              metadata.name == manifest.name,
              metadata.version == manifest.version,
              metadata.requestedPermissions == manifest.permissions,
              metadata.hostPermissions == manifest.hostPermissions,
              Set(metadata.grantedPermissions).isSubset(of: Set(manifest.permissions)),
              storedHostPatterns.allSatisfy({ grant in
                  declaredHostPatterns.contains(where: { $0.encompasses(grant) })
              }),
              metadata.packageDigest.utf8.count == 64,
              metadata.packageDigest.utf8.allSatisfy({
                  (48...57).contains($0) || (97...102).contains($0)
              }),
              metadata.packageDigest.hasPrefix(metadata.id.rawValue) else {
            throw ExtensionRuntimeError.integrityCheckFailed("metadata, manifest, and directory identity disagree")
        }
        let identity = try ExtensionIdentityGenerator.identity(forDirectory: filesURL)
        guard identity.identifier == metadata.id, identity.digest == metadata.packageDigest else {
            throw ExtensionRuntimeError.integrityCheckFailed("installed resources were modified")
        }
        return InstalledExtension(metadata: metadata, manifest: manifest, directoryURL: directory)
    }

    private func declaredHostPatterns(for manifest: WebExtensionManifest) throws -> [WebExtensionMatchPattern] {
        try Array(Set(manifest.hostPermissions + manifest.contentScripts.flatMap(\.matches)))
            .sorted()
            .map(WebExtensionMatchPattern.init)
    }

    private func boundedFileData(at url: URL, maximumBytes: Int) throws -> Data {
        do {
            return try BoundedFileReader.read(
                from: url,
                maximumByteCount: maximumBytes,
                fileManager: fileManager
            )
        } catch {
            throw ExtensionRuntimeError.integrityCheckFailed("metadata file is missing or exceeds its size limit")
        }
    }

    private func quarantine(_ directory: URL, reason: Error) {
        let quarantineRoot = baseDirectoryURL.appendingPathComponent(".quarantine", isDirectory: true)
        do {
            try fileManager.createDirectory(at: quarantineRoot, withIntermediateDirectories: true)
            let safeName = directory.lastPathComponent.prefix(64)
            let target = quarantineRoot.appendingPathComponent("\(safeName)-\(UUID().uuidString)", isDirectory: true)
            try fileManager.moveItem(at: directory, to: target)
            try AppDataProtectionPolicy.protectRecursively(
                target,
                category: .browserState,
                fileManager: fileManager
            )
            AppLog.extensions.error(
                "Quarantined corrupt extension \(String(safeName), privacy: .public): \(reason.localizedDescription, privacy: .private)"
            )
        } catch {
            AppLog.extensions.error(
                "Could not quarantine corrupt extension \(directory.lastPathComponent, privacy: .public)"
            )
        }
    }

    private func write<T: Encodable>(_ value: T, to url: URL) throws {
        let data = try encoder.encode(value)
        try data.write(to: url, options: [.atomic])
        try AppDataProtectionPolicy.apply(to: url, category: .browserState, fileManager: fileManager)
    }

    private func finishMetadataMutation(_ installed: InstalledExtension) -> InstalledExtension {
        verifiedExtensions[installed.id] = installed
        hasVerifiedSnapshot = true
        postChange()
        return installed
    }

    private func postChange() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }
}
