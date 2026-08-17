import Foundation

public struct ManifestParser: Sendable {
    public static let maximumManifestBytes = 1 * 1_024 * 1_024

    public init() {}

    public func parse(data: Data) throws -> WebExtensionManifest {
        guard data.count <= Self.maximumManifestBytes else {
            throw ExtensionManifestError.manifestLimitExceeded(
                "maximum size is \(Self.maximumManifestBytes) bytes"
            )
        }
        let manifest: WebExtensionManifest
        do {
            manifest = try JSONDecoder().decode(WebExtensionManifest.self, from: data)
        } catch {
            throw ExtensionManifestError.invalidJSON(error.localizedDescription)
        }
        try ManifestValidator.validate(manifest)
        return manifest
    }

    public func parse(fileURL: URL) throws -> WebExtensionManifest {
        guard fileURL.isFileURL, let data = try? Data(contentsOf: fileURL, options: [.mappedIfSafe]) else {
            throw ExtensionManifestError.unreadableManifest
        }
        return try parse(data: data)
    }
}

public enum ManifestValidator {
    public static let maximumNameBytes = 256
    public static let maximumDescriptionBytes = 4 * 1_024
    public static let maximumActionTitleBytes = 1_024
    public static let maximumAPIPermissionCount = 32
    public static let maximumHostPermissionCount = 256
    public static let maximumIconCount = 64
    public static let maximumContentScriptCount = 128
    public static let maximumMatchPatternsPerContentScript = 256
    public static let maximumResourceReferencesPerContentScript = 32
    public static let maximumTotalContentScriptResourceReferences = 256

    public static let supportedAPIPermissions: Set<String> = [
        "activeTab", "storage", "tabs", "scripting"
    ]

    public static func validate(_ manifest: WebExtensionManifest) throws {
        guard manifest.manifestVersion == 3 else {
            throw ExtensionManifestError.unsupportedManifestVersion(manifest.manifestVersion)
        }
        guard !manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ExtensionManifestError.missingName
        }
        guard manifest.name.utf8.count <= maximumNameBytes else {
            throw ExtensionManifestError.manifestLimitExceeded(
                "name may contain at most \(maximumNameBytes) UTF-8 bytes"
            )
        }
        if let description = manifest.description,
           description.utf8.count > maximumDescriptionBytes {
            throw ExtensionManifestError.manifestLimitExceeded(
                "description may contain at most \(maximumDescriptionBytes) UTF-8 bytes"
            )
        }
        guard isValidVersion(manifest.version) else {
            throw ExtensionManifestError.invalidVersion(manifest.version)
        }

        guard manifest.permissions.count <= maximumAPIPermissionCount else {
            throw ExtensionManifestError.manifestLimitExceeded(
                "at most \(maximumAPIPermissionCount) API permissions are allowed"
            )
        }
        for permission in manifest.permissions where !supportedAPIPermissions.contains(permission) {
            // Unknown permissions are rejected rather than silently creating a false sense of compatibility.
            throw ExtensionManifestError.unsupportedPermission(permission)
        }
        guard manifest.hostPermissions.count <= maximumHostPermissionCount else {
            throw ExtensionManifestError.manifestLimitExceeded(
                "at most \(maximumHostPermissionCount) host permissions are allowed"
            )
        }
        for hostPermission in manifest.hostPermissions {
            _ = try WebExtensionMatchPattern(hostPermission)
        }
        guard manifest.icons.count <= maximumIconCount else {
            throw ExtensionManifestError.manifestLimitExceeded(
                "at most \(maximumIconCount) extension icons are allowed"
            )
        }
        if let title = manifest.action?.defaultTitle,
           title.utf8.count > maximumActionTitleBytes {
            throw ExtensionManifestError.manifestLimitExceeded(
                "action.default_title may contain at most \(maximumActionTitleBytes) UTF-8 bytes"
            )
        }

        guard manifest.contentScripts.count <= maximumContentScriptCount else {
            throw ExtensionManifestError.contentScriptLimitExceeded(
                "at most \(maximumContentScriptCount) content_scripts entries are allowed"
            )
        }
        var totalResourceReferences = 0
        for (index, script) in manifest.contentScripts.enumerated() {
            guard !script.matches.isEmpty else {
                throw ExtensionManifestError.missingContentScriptMatches(index: index)
            }
            let patternCount = script.matches.count + script.excludeMatches.count
            guard patternCount <= maximumMatchPatternsPerContentScript else {
                throw ExtensionManifestError.contentScriptLimitExceeded(
                    "content script \(index + 1) may contain at most "
                        + "\(maximumMatchPatternsPerContentScript) match patterns"
                )
            }
            let resourceCount = script.javascript.count + script.css.count
            guard resourceCount <= maximumResourceReferencesPerContentScript else {
                throw ExtensionManifestError.contentScriptLimitExceeded(
                    "content script \(index + 1) may reference at most "
                        + "\(maximumResourceReferencesPerContentScript) JavaScript and CSS files"
                )
            }
            totalResourceReferences += resourceCount
            guard totalResourceReferences <= maximumTotalContentScriptResourceReferences else {
                throw ExtensionManifestError.contentScriptLimitExceeded(
                    "at most \(maximumTotalContentScriptResourceReferences) content script file references are allowed"
                )
            }
            for pattern in script.matches + script.excludeMatches {
                _ = try WebExtensionMatchPattern(pattern)
            }
            for path in script.javascript + script.css {
                _ = try ExtensionResourcePath.normalize(path)
            }
        }
        if let popup = manifest.action?.defaultPopup, !popup.isEmpty {
            _ = try ExtensionResourcePath.normalize(popup)
        }
        for path in manifest.icons.values {
            _ = try ExtensionResourcePath.normalize(path)
        }
        if let icon = manifest.action?.defaultIcon {
            switch icon {
            case .path(let path): _ = try ExtensionResourcePath.normalize(path)
            case .sized(let paths):
                guard paths.count <= maximumIconCount else {
                    throw ExtensionManifestError.manifestLimitExceeded(
                        "at most \(maximumIconCount) action icons are allowed"
                    )
                }
                for path in paths.values { _ = try ExtensionResourcePath.normalize(path) }
            }
        }
    }

    private static func isValidVersion(_ version: String) -> Bool {
        let components = version.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...4).contains(components.count) else { return false }
        return components.allSatisfy { component in
            guard !component.isEmpty,
                  component.allSatisfy(\.isNumber),
                  component.count == 1 || component.first != "0",
                  UInt16(component) != nil
            else { return false }
            return true
        }
    }
}
