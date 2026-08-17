import Foundation

public enum ExtensionCapability: String, Codable, CaseIterable, Hashable, Sendable {
    case activeTab
    case storage
    case tabs
    case scripting
}

public struct ExtensionPermissionSnapshot: Equatable, Sendable {
    public let extensionID: ExtensionIdentifier
    public let capabilities: Set<ExtensionCapability>
    public let hostPatterns: [WebExtensionMatchPattern]
    public let isEnabled: Bool
}

public actor ExtensionPermissionManager {
    private struct ContentScriptHostRule: Sendable {
        let includes: [WebExtensionMatchPattern]
        let excludes: [WebExtensionMatchPattern]

        func matches(_ url: URL) -> Bool {
            includes.contains(where: { $0.matches(url) })
                && !excludes.contains(where: { $0.matches(url) })
        }
    }

    private struct PermissionState: Sendable {
        var declaredCapabilities: Set<ExtensionCapability>
        var grantedCapabilities: Set<ExtensionCapability>
        /// Explicit `host_permissions`; used by programmatic APIs such as executeScript.
        var grantedHostPatterns: [WebExtensionMatchPattern]
        /// Implicit access belonging only to the corresponding declarative content scripts.
        var contentScriptHostRules: [ContentScriptHostRule]
        /// Transient user-gesture grants. The tab identifier is part of the
        /// capability so invoking an action in one tab never authorizes another
        /// tab that happens to have the same origin.
        var activeTabOrigins: [UUID: String]
        var isEnabled: Bool
    }

    private var states: [ExtensionIdentifier: PermissionState] = [:]

    public init() {}

    public func register(
        extensionID: ExtensionIdentifier,
        manifest: WebExtensionManifest,
        isEnabled: Bool,
        grantDeclaredPermissions: Bool = true
    ) throws {
        let capabilities = Set(manifest.permissions.compactMap(ExtensionCapability.init(rawValue:)))
        let hostPatterns = try Set(manifest.hostPermissions).sorted().map(WebExtensionMatchPattern.init)
        let contentScriptHostRules = try manifest.contentScripts.map { script in
            ContentScriptHostRule(
                includes: try script.matches.map(WebExtensionMatchPattern.init),
                excludes: try script.excludeMatches.map(WebExtensionMatchPattern.init)
            )
        }
        states[extensionID] = PermissionState(
            declaredCapabilities: capabilities,
            grantedCapabilities: grantDeclaredPermissions ? capabilities : [],
            grantedHostPatterns: grantDeclaredPermissions ? hostPatterns : [],
            contentScriptHostRules: grantDeclaredPermissions ? contentScriptHostRules : [],
            activeTabOrigins: [:],
            isEnabled: isEnabled
        )
    }

    public func unregister(extensionID: ExtensionIdentifier) {
        states.removeValue(forKey: extensionID)
    }

    public func setEnabled(_ enabled: Bool, extensionID: ExtensionIdentifier) throws {
        guard states[extensionID] != nil else {
            throw ExtensionRuntimeError.extensionNotFound(extensionID.rawValue)
        }
        states[extensionID]?.isEnabled = enabled
        if !enabled { states[extensionID]?.activeTabOrigins.removeAll() }
    }

    public func setCapability(
        _ capability: ExtensionCapability,
        granted: Bool,
        extensionID: ExtensionIdentifier
    ) throws {
        guard var state = states[extensionID] else {
            throw ExtensionRuntimeError.extensionNotFound(extensionID.rawValue)
        }
        guard state.declaredCapabilities.contains(capability) else {
            throw ExtensionRuntimeError.permissionDenied(capability.rawValue)
        }
        if granted {
            state.grantedCapabilities.insert(capability)
        } else {
            state.grantedCapabilities.remove(capability)
        }
        states[extensionID] = state
    }

    public func grantActiveTab(
        _ url: URL,
        tabID: UUID,
        extensionID: ExtensionIdentifier
    ) throws {
        guard var state = states[extensionID] else {
            throw ExtensionRuntimeError.extensionNotFound(extensionID.rawValue)
        }
        guard state.isEnabled else { throw ExtensionRuntimeError.extensionDisabled(extensionID.rawValue) }
        guard state.grantedCapabilities.contains(.activeTab), let origin = Self.origin(of: url) else {
            throw ExtensionRuntimeError.permissionDenied(ExtensionCapability.activeTab.rawValue)
        }
        state.activeTabOrigins[tabID] = origin
        states[extensionID] = state
    }

    public func revokeActiveTabGrants(extensionID: ExtensionIdentifier) {
        states[extensionID]?.activeTabOrigins.removeAll()
    }

    public func revokeActiveTabGrant(tabID: UUID, extensionID: ExtensionIdentifier) {
        states[extensionID]?.activeTabOrigins.removeValue(forKey: tabID)
    }

    /// Revokes a tab across every extension. Navigation and tab-close boundaries
    /// use this overload so no stale action capability survives a document.
    public func revokeActiveTabGrant(tabID: UUID) {
        for extensionID in Array(states.keys) {
            states[extensionID]?.activeTabOrigins.removeValue(forKey: tabID)
        }
    }

    public func authorize(_ capability: ExtensionCapability, extensionID: ExtensionIdentifier) throws {
        guard let state = states[extensionID] else {
            throw ExtensionRuntimeError.extensionNotFound(extensionID.rawValue)
        }
        guard state.isEnabled else { throw ExtensionRuntimeError.extensionDisabled(extensionID.rawValue) }
        guard state.grantedCapabilities.contains(capability) else {
            throw ExtensionRuntimeError.permissionDenied(capability.rawValue)
        }
    }

    public func authorizeHost(
        _ url: URL,
        tabID: UUID?,
        extensionID: ExtensionIdentifier
    ) throws {
        guard let state = states[extensionID] else {
            throw ExtensionRuntimeError.extensionNotFound(extensionID.rawValue)
        }
        guard state.isEnabled else { throw ExtensionRuntimeError.extensionDisabled(extensionID.rawValue) }
        let matchesDeclaredHost = state.grantedHostPatterns.contains(where: { $0.matches(url) })
        let requestedOrigin = Self.origin(of: url)
        let matchesActiveTab = tabID.flatMap { state.activeTabOrigins[$0] } == requestedOrigin
            && requestedOrigin != nil
        guard matchesDeclaredHost || matchesActiveTab else {
            throw ExtensionRuntimeError.permissionDenied("host access for \(url.host ?? url.absoluteString)")
        }
    }

    public func canInject(
        into url: URL,
        tabID: UUID?,
        extensionID: ExtensionIdentifier
    ) -> Bool {
        guard let state = states[extensionID], state.isEnabled else { return false }
        let requestedOrigin = Self.origin(of: url)
        let matchesActiveTab = tabID.flatMap { state.activeTabOrigins[$0] } == requestedOrigin
            && requestedOrigin != nil
        return state.grantedHostPatterns.contains(where: { $0.matches(url) })
            || state.contentScriptHostRules.contains(where: { $0.matches(url) })
            || matchesActiveTab
    }

    public func snapshot(extensionID: ExtensionIdentifier) -> ExtensionPermissionSnapshot? {
        guard let state = states[extensionID] else { return nil }
        return ExtensionPermissionSnapshot(
            extensionID: extensionID,
            capabilities: state.grantedCapabilities,
            hostPatterns: state.grantedHostPatterns,
            isEnabled: state.isEnabled
        )
    }

    public static func displayText(for permission: String) -> String {
        switch permission {
        case ExtensionCapability.activeTab.rawValue: return "Access the current tab after you invoke the extension"
        case ExtensionCapability.storage.rawValue: return "Store extension settings on this device"
        case ExtensionCapability.tabs.rawValue: return "View and create browser tabs"
        case ExtensionCapability.scripting.rawValue: return "Run scripts on permitted websites"
        case _ where permission.contains("://") || permission == "<all_urls>":
            return "Read and change data on \(permission)"
        default: return permission
        }
    }

    private static func origin(of url: URL) -> String? {
        guard let scheme = url.scheme?.lowercased() else { return nil }
        if scheme == "file" { return "file://" }
        guard let host = url.host?.lowercased() else { return nil }
        let defaultPort = (scheme == "http" && url.port == 80) || (scheme == "https" && url.port == 443)
        let port = defaultPort ? nil : url.port
        return scheme + "://" + host + (port.map { ":\($0)" } ?? "")
    }
}
