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
    public var grantedPermissions: [String]
    public var grantedHostPermissions: [String]

    enum CodingKeys: String, CodingKey {
        case id, name, version, installedAt, updatedAt, isEnabled, allowInPrivateBrowsing
        case extensionDescription = "description"
        case packageDigest, requestedPermissions, hostPermissions, grantedPermissions, grantedHostPermissions
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
        // `activeTab` is still inert until a direct user invocation; storage is namespaced and
        // quota-bound. Higher-risk tab/scripting and every website grant start denied.
        grantedPermissions = manifest.permissions.filter { $0 == "activeTab" || $0 == "storage" }
        grantedHostPermissions = []
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(ExtensionIdentifier.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        version = try container.decode(String.self, forKey: .version)
        extensionDescription = try container.decodeIfPresent(String.self, forKey: .extensionDescription)
        installedAt = try container.decode(Date.self, forKey: .installedAt)
        updatedAt = try container.decode(Date.self, forKey: .updatedAt)
        isEnabled = try container.decode(Bool.self, forKey: .isEnabled)
        allowInPrivateBrowsing = try container.decodeIfPresent(Bool.self, forKey: .allowInPrivateBrowsing) ?? false
        packageDigest = try container.decode(String.self, forKey: .packageDigest)
        requestedPermissions = try container.decode([String].self, forKey: .requestedPermissions)
        hostPermissions = try container.decode([String].self, forKey: .hostPermissions)
        // Legacy metadata is migrated fail-closed instead of inheriting the old auto-grant model.
        grantedPermissions = try container.decodeIfPresent([String].self, forKey: .grantedPermissions) ?? []
        grantedHostPermissions = try container.decodeIfPresent([String].self, forKey: .grantedHostPermissions) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(version, forKey: .version)
        try container.encodeIfPresent(extensionDescription, forKey: .extensionDescription)
        try container.encode(installedAt, forKey: .installedAt)
        try container.encode(updatedAt, forKey: .updatedAt)
        try container.encode(isEnabled, forKey: .isEnabled)
        try container.encode(allowInPrivateBrowsing, forKey: .allowInPrivateBrowsing)
        try container.encode(packageDigest, forKey: .packageDigest)
        try container.encode(requestedPermissions, forKey: .requestedPermissions)
        try container.encode(hostPermissions, forKey: .hostPermissions)
        try container.encode(grantedPermissions, forKey: .grantedPermissions)
        try container.encode(grantedHostPermissions, forKey: .grantedHostPermissions)
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
    public let sourceDescription: String

    init(
        id: ExtensionIdentifier,
        manifest: WebExtensionManifest,
        packageDigest: String,
        stagedDirectoryURL: URL,
        stagingContainerURL: URL,
        sourceDescription: String = "Local package"
    ) {
        self.id = id
        self.manifest = manifest
        self.packageDigest = packageDigest
        self.stagedDirectoryURL = stagedDirectoryURL
        self.stagingContainerURL = stagingContainerURL
        self.sourceDescription = SafeInput.displayText(sourceDescription, maximumByteCount: 256)
    }

    public var requestedPermissions: [String] {
        Array(Set(
            manifest.permissions
                + manifest.hostPermissions
                + manifest.contentScripts.flatMap(\.matches)
        )).sorted()
    }
}
