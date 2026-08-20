import WebKit

/// What an extension asks for, as the runtime resolved it.
///
/// ADR-001 keeps manifest interpretation inside WebKit, so the install sheet is filled by building a
/// `WKWebExtension` over the staged directory and reading back what it parsed — not by opening
/// `manifest.json`. That matters beyond tidiness: the strings shown to the user are the same strings
/// written to the catalog and later compared against `WKWebExtension.Permission`, so a sheet that
/// spelled them differently from the runtime would be describing a grant that never happens.
struct ExtensionPermissionSummary: Sendable, Equatable {
    let displayName: String
    let version: String?
    let permissions: [String]
    let optionalPermissions: [String]
    let matchPatterns: [String]
    let optionalMatchPatterns: [String]
    /// Spec §7: any pattern that reaches every site earns the bold warning, whether it is spelled
    /// `<all_urls>` or `*://*/*`.
    let requestsAllURLs: Bool
    /// The manifest name carried something a display string should not — a bidi override, a
    /// zero-width joiner. `displayName` is already sanitised; this says it needed sanitising, which
    /// is worth showing the user because name spoofing is how a fake uBlock gets installed.
    let hasUnsafeDisplayName: Bool

    var requestsNothing: Bool { permissions.isEmpty && matchPatterns.isEmpty }
}

@MainActor
enum ExtensionPermissionSummaryReader {
    static func summary(
        for webExtension: WKWebExtension,
        fallbackName: String
    ) -> ExtensionPermissionSummary {
        let rawName = (webExtension.displayName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let safeName = SafeInput.displayText(
            rawName,
            maximumByteCount: SafePersistence.maximumExtensionNameBytes,
            allowsNewlines: false
        ).trimmingCharacters(in: .whitespacesAndNewlines)

        let patterns = webExtension.allRequestedMatchPatterns

        return ExtensionPermissionSummary(
            displayName: safeName.isEmpty ? fallbackName : safeName,
            version: webExtension.displayVersion.map {
                SafeInput.displayText($0, maximumByteCount: 64, allowsNewlines: false)
            },
            permissions: webExtension.requestedPermissions.map(\.rawValue).sorted(),
            optionalPermissions: webExtension.optionalPermissions.map(\.rawValue).sorted(),
            matchPatterns: patterns.map(\.string).sorted(),
            optionalMatchPatterns: webExtension.optionalPermissionMatchPatterns.map(\.string).sorted(),
            requestsAllURLs: patterns.contains { $0.matchesAllURLs || $0.matchesAllHosts },
            hasUnsafeDisplayName: !rawName.isEmpty
                && !SafeInput.isSafeDisplayText(rawName, allowsNewlines: false)
        )
    }
}
