import Foundation
import WebKit

public struct ExtensionAPIContext: Sendable {
    public let extensionID: ExtensionIdentifier
    public let tabID: UUID
    public let pageURL: URL?

    public init(extensionID: ExtensionIdentifier, tabID: UUID, pageURL: URL?) {
        self.extensionID = extensionID
        self.tabID = tabID
        self.pageURL = pageURL
    }
}

public struct ExtensionTabSnapshot: Equatable, Sendable {
    public let id: UUID
    public let title: String
    public let url: URL?
    public let isActive: Bool

    public init(id: UUID, title: String, url: URL?, isActive: Bool) {
        self.id = id
        self.title = title
        self.url = url
        self.isActive = isActive
    }

    public var jsonValue: JSONValue {
        .object([
            "id": .string(id.uuidString),
            "title": .string(title),
            "url": url.map { .string($0.absoluteString) } ?? .null,
            "active": .bool(isActive),
            "incognito": .bool(false)
        ])
    }
}

@MainActor
public protocol ExtensionTabProviding: AnyObject {
    func visibleTabs() -> [ExtensionTabSnapshot]
    func activeTab() -> ExtensionTabSnapshot?
    func createTab(url: URL?, active: Bool) throws -> ExtensionTabSnapshot
}

@MainActor
public protocol ExtensionScriptExecuting: AnyObject {
    func executeScript(
        _ source: String,
        inTab tabID: UUID?,
        extensionID: ExtensionIdentifier
    ) async throws -> JSONValue
}

@MainActor
final class BrowserHostExtensionTabProvider: ExtensionTabProviding {
    func visibleTabs() -> [ExtensionTabSnapshot] {
        BrowserExtensionBridge.shared.browserHost?.extensionVisibleTabs.map {
            ExtensionTabSnapshot(id: $0.id, title: $0.title, url: $0.url, isActive: $0.isActive)
        } ?? []
    }

    func activeTab() -> ExtensionTabSnapshot? {
        guard let tab = BrowserExtensionBridge.shared.browserHost?.extensionActiveTab else { return nil }
        return ExtensionTabSnapshot(id: tab.id, title: tab.title, url: tab.url, isActive: tab.isActive)
    }

    func createTab(url: URL?, active: Bool) throws -> ExtensionTabSnapshot {
        guard let host = BrowserExtensionBridge.shared.browserHost else {
            throw ExtensionRuntimeError.unavailable("no browser window is active")
        }
        let id: UUID
        do {
            id = try host.openTabFromExtension(url: url, activate: active)
        } catch {
            throw ExtensionRuntimeError.resourceLimitExceeded("tab limit reached")
        }
        return ExtensionTabSnapshot(id: id, title: "New Tab", url: url, isActive: active)
    }
}
