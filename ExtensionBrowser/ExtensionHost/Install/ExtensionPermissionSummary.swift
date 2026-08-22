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
    /// Permissions this build accepts and the platform then does nothing with.
    ///
    /// Not a guess and not a compatibility table copied from somewhere: R-21 in `RISKS.md` records
    /// that `WebExtensionNetworkEnforcementTests` runs a real HTTP server on loopback on every CI
    /// run and measures that `declarativeNetRequest` rules install, report themselves installed, and
    /// stop nothing — `getMatchedRules()` empty, every request arriving — while a `WKContentRuleList`
    /// compiled by the same test blocks the same URL on the same server. `webRequest` listeners
    /// register and never fire.
    ///
    /// The install therefore succeeds, the switch turns on, and a content blocker does nothing at
    /// all. That is worth a sentence before the user installs it, not a support question afterwards.
    let inertPermissions: [String]
    /// The manifest name carried something a display string should not — a bidi override, a
    /// zero-width joiner. `displayName` is already sanitised; this says it needed sanitising, which
    /// is worth showing the user because name spoofing is how a fake uBlock gets installed.
    let hasUnsafeDisplayName: Bool

    var requestsNothing: Bool { permissions.isEmpty && matchPatterns.isEmpty }
}

/// Capabilities this build accepts from a manifest and the platform then does not honour.
///
/// Deliberately not inside `ExtensionPermissionSummaryReader`: that type is `@MainActor` because it
/// touches `WKWebExtension`, and this list is also needed by `InstalledExtensionRecord`, which is a
/// plain value read from disk on whatever thread the catalog was loaded on.
enum UnenforcedExtensionCapability {
    /// Measured, not assumed. `WebExtensionNetworkEnforcementTests` runs a real HTTP server on
    /// loopback on every CI run: `declarativeNetRequest` rules install, report themselves installed,
    /// and stop nothing, while a `WKContentRuleList` compiled by the same test blocks the same URL
    /// on the same server. `webRequest` listeners register and never fire. See R-21 in `RISKS.md`.
    static let permissions: Set<String> = [
        "declarativeNetRequest",
        "declarativeNetRequestWithHostAccess",
        "declarativeNetRequestFeedback",
        "webRequest",
        "webRequestBlocking"
    ]
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
        let requested = webExtension.requestedPermissions.map(\.rawValue)
        let inert = requested.filter { UnenforcedExtensionCapability.permissions.contains($0) }.sorted()

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
            inertPermissions: inert,
            hasUnsafeDisplayName: !rawName.isEmpty
                && !SafeInput.isSafeDisplayText(rawName, allowsNewlines: false)
        )
    }
}
