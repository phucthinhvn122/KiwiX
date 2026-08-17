import Foundation

public struct ExtensionIdentifier: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init?(rawValue: String) {
        guard rawValue.count == 32,
              rawValue.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { return nil }
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

public struct ExtensionMetadata: Codable, Equatable, Identifiable, Sendable {
    public let id: ExtensionIdentifier
    public let name: String
    public let version: String
    public let extensionDescription: String?
    public let installedAt: Date
    public var updatedAt: Date
    public var isEnabled: Bool
    public var allowInPrivateBrowsing: Bool
    public let packageDigest: String
    public let requestedPermissions: [String]
    public let hostPermissions: [String]

    enum CodingKeys: String, CodingKey {
        case id, name, version, installedAt, updatedAt, isEnabled, allowInPrivateBrowsing
        case extensionDescription = "description"
        case packageDigest, requestedPermissions, hostPermissions
    }

    public init(
        id: ExtensionIdentifier,
        manifest: WebExtensionManifest,
        installedAt: Date = Date(),
        isEnabled: Bool = true,
        allowInPrivateBrowsing: Bool = false,
        packageDigest: String
    ) {
        self.id = id
        name = manifest.name
        version = manifest.version
        extensionDescription = manifest.description
        self.installedAt = installedAt
        updatedAt = installedAt
        self.isEnabled = isEnabled
        self.allowInPrivateBrowsing = allowInPrivateBrowsing
        self.packageDigest = packageDigest
        requestedPermissions = manifest.permissions
        hostPermissions = manifest.hostPermissions
    }
}

public struct InstalledExtension: Equatable, Identifiable, Sendable {
    public let metadata: ExtensionMetadata
    public let manifest: WebExtensionManifest
    public let directoryURL: URL

    public var id: ExtensionIdentifier { metadata.id }
    public var filesURL: URL { directoryURL.appendingPathComponent("files", isDirectory: true) }
    public var storageURL: URL { directoryURL.appendingPathComponent("storage", isDirectory: true) }
}

public struct ExtensionPackagePreview: Identifiable, Equatable, Sendable {
    public let id: ExtensionIdentifier
    public let manifest: WebExtensionManifest
    public let packageDigest: String
    public let stagedDirectoryURL: URL
    public let stagingContainerURL: URL

    init(
        id: ExtensionIdentifier,
        manifest: WebExtensionManifest,
        packageDigest: String,
        stagedDirectoryURL: URL,
        stagingContainerURL: URL
    ) {
        self.id = id
        self.manifest = manifest
        self.packageDigest = packageDigest
        self.stagedDirectoryURL = stagedDirectoryURL
        self.stagingContainerURL = stagingContainerURL
    }

    public var requestedPermissions: [String] {
        Array(Set(
            manifest.permissions
                + manifest.hostPermissions
                + manifest.contentScripts.flatMap(\.matches)
        )).sorted()
    }
}
