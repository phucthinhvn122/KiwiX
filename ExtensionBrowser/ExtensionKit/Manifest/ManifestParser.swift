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
        do {
            try BoundedJSONPreflight.validate(
                data,
                maximumDepth: 32,
                maximumStringBytes: 64 * 1_024,
                maximumStructuralTokens: 50_000
            )
        } catch let error as BoundedJSONPreflightError {
            // `BoundedJSONPreflightError` is internal; a public parser must not leak it. Callers
            // contract on `ExtensionManifestError` and were seeing an untranslated preflight error.
            switch error {
            case .nestingLimit:
                throw ExtensionManifestError.manifestLimitExceeded("maximum JSON nesting depth is 32")
            case .stringLimit:
                throw ExtensionManifestError.manifestLimitExceeded("a JSON string exceeds 64 KiB")
            case .structuralLimit:
                throw ExtensionManifestError.manifestLimitExceeded("too many JSON structural tokens")
            case .malformedStructure:
                throw ExtensionManifestError.invalidJSON("malformed JSON structure")
            }
        }
        try Self.validateJSONStructure(data)
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
        guard let data = try? BoundedFileReader.read(
            from: fileURL,
            maximumByteCount: Self.maximumManifestBytes
        ) else {
            throw ExtensionManifestError.unreadableManifest
        }
        return try parse(data: data)
    }

    private static func validateJSONStructure(_ data: Data) throws {
        var depth = 0
        var inString = false
        var escaped = false
        var stringBytes = 0
        for byte in data {
            if inString {
                if escaped {
                    escaped = false
                } else if byte == 0x5C {
                    escaped = true
                } else if byte == 0x22 {
                    inString = false
                } else {
                    stringBytes += 1
                    guard stringBytes <= 64 * 1_024 else {
                        throw ExtensionManifestError.manifestLimitExceeded("a JSON string exceeds 65536 bytes")
                    }
                }
            } else if byte == 0x22 {
                inString = true
                stringBytes = 0
            } else if byte == 0x7B || byte == 0x5B {
                depth += 1
                guard depth <= 32 else {
                    throw ExtensionManifestError.manifestLimitExceeded("JSON nesting exceeds 32 levels")
                }
            } else if byte == 0x7D || byte == 0x5D {
                depth -= 1
                guard depth >= 0 else { throw ExtensionManifestError.invalidJSON("unbalanced JSON") }
            }
        }
        guard depth == 0, !inString, !escaped else {
            throw ExtensionManifestError.invalidJSON("unterminated or unbalanced JSON")
        }
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
        guard SafeInput.isSafeDisplayText(manifest.name) else {
            throw ExtensionManifestError.manifestLimitExceeded("name contains unsafe formatting characters")
        }
        guard manifest.name.utf8.count <= maximumNameBytes else {
            throw ExtensionManifestError.manifestLimitExceeded(
                "name may contain at most \(maximumNameBytes) UTF-8 bytes"
            )
        }
        if let description = manifest.description {
            guard description.utf8.count <= maximumDescriptionBytes,
                  SafeInput.isSafeDisplayText(description, allowsNewlines: true) else {
                throw ExtensionManifestError.manifestLimitExceeded(
                    "description is unsafe or exceeds \(maximumDescriptionBytes) UTF-8 bytes"
                )
            }
        }
        guard manifest.version.utf8.count <= 64, isValidVersion(manifest.version) else {
            throw ExtensionManifestError.invalidVersion(manifest.version)
        }

        guard manifest.permissions.count <= maximumAPIPermissionCount else {
            throw ExtensionManifestError.manifestLimitExceeded(
                "at most \(maximumAPIPermissionCount) API permissions are allowed"
            )
        }
        for permission in manifest.permissions {
            guard permission.utf8.count <= 128 else {
                throw ExtensionManifestError.manifestLimitExceeded(
                    "an API permission exceeds 128 UTF-8 bytes"
                )
            }
            guard supportedAPIPermissions.contains(permission) else {
            // Unknown permissions are rejected rather than silently creating a false sense of compatibility.
            throw ExtensionManifestError.unsupportedPermission(permission)
            }
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
           (title.utf8.count > maximumActionTitleBytes || !SafeInput.isSafeDisplayText(title)) {
            throw ExtensionManifestError.manifestLimitExceeded(
                "action.default_title is unsafe or exceeds \(maximumActionTitleBytes) UTF-8 bytes"
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
