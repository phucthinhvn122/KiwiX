import Foundation
import UIKit
import WebKit

struct BrowserExtensionTabContext: Sendable, Equatable {
    let tabID: UUID
    let isPrivate: Bool
}

struct BrowserTabDescriptor: Sendable, Equatable {
    let id: UUID
    let title: String
    let url: URL?
    let isPrivate: Bool
    let isActive: Bool
}

/// Browser-facing action metadata. Keeping the icon as bounded encoded data avoids
/// leaking an extension filesystem URL across the ExtensionKit boundary.
struct BrowserExtensionActionDescriptor: Identifiable, Sendable, Equatable {
    let extensionID: String
    let title: String
    let iconData: Data?
    let hasPopup: Bool

    var id: String { extensionID }
}

/// Result of an explicit toolbar/menu action invocation.
///
/// A popup controller is created by ExtensionUI with its restricted WebKit
/// configuration. `noPopup` deliberately does not imply a background worker or
/// callback-style Chrome event; those APIs are outside the current runtime.
@MainActor
enum BrowserExtensionActionInvocation {
    case noPopup
    case presentPopup(UIViewController)
}

/// The narrow boundary between the browser target and ExtensionKit.
///
/// ExtensionKit installs its script handlers in `configure` before the first
/// navigation. Private tabs deliberately never reach this integration point.
@MainActor
protocol BrowserExtensionIntegrating: AnyObject {
    func configure(
        userContentController: WKUserContentController,
        context: BrowserExtensionTabContext
    )

    func navigationDidCommit(
        url: URL?,
        in webView: WKWebView,
        context: BrowserExtensionTabContext
    )

    func navigationDidFinish(
        url: URL?,
        in webView: WKWebView,
        context: BrowserExtensionTabContext
    )

    func navigationDidFail(
        url: URL?,
        error: Error,
        context: BrowserExtensionTabContext
    )

    /// Returns enabled actions for the current non-private tab without granting
    /// `activeTab` or any other capability.
    func availableActions(
        for tab: BrowserTabDescriptor
    ) async -> [BrowserExtensionActionDescriptor]

    /// This is the sole user-gesture boundary that may grant `activeTab`.
    /// Call it only from a direct browser UI action for `tab`.
    func invokeAction(
        extensionID: String,
        for tab: BrowserTabDescriptor
    ) async throws -> BrowserExtensionActionInvocation

    /// Lets the runtime discard tab-scoped grants and action state on close.
    func extensionTabDidClose(id: UUID)

    var debugInformation: [String: String] { get }
}

extension BrowserExtensionIntegrating {
    func navigationDidCommit(
        url: URL?,
        in webView: WKWebView,
        context: BrowserExtensionTabContext
    ) {}

    func navigationDidFinish(
        url: URL?,
        in webView: WKWebView,
        context: BrowserExtensionTabContext
    ) {}

    func navigationDidFail(
        url: URL?,
        error: Error,
        context: BrowserExtensionTabContext
    ) {}

    func availableActions(
        for tab: BrowserTabDescriptor
    ) async -> [BrowserExtensionActionDescriptor] { [] }

    func invokeAction(
        extensionID: String,
        for tab: BrowserTabDescriptor
    ) async throws -> BrowserExtensionActionInvocation { .noPopup }

    func extensionTabDidClose(id: UUID) {}

    var debugInformation: [String: String] { [:] }
}

@MainActor
protocol BrowserExtensionHost: AnyObject {
    var extensionVisibleTabs: [BrowserTabDescriptor] { get }
    var extensionActiveTab: BrowserTabDescriptor? { get }

    @discardableResult
    func openTabFromExtension(url: URL?, activate: Bool) throws -> UUID
}

@MainActor
final class BrowserExtensionBridge {
    static let shared = BrowserExtensionBridge()

    /// Held strongly so a runtime registered during app bootstrap stays alive.
    var integration: BrowserExtensionIntegrating?
    weak var browserHost: BrowserExtensionHost?

    private init() {}
}

enum BrowserExtensionNotifications {
    static let requestCreateTab = Notification.Name(
        "ExtensionBrowser.ExtensionRuntime.RequestCreateTab"
    )
    static let requestPresentManager = Notification.Name(
        "ExtensionBrowser.ExtensionUI.RequestPresentManager"
    )

    enum UserInfoKey {
        static let url = "url"
        static let activate = "activate"
    }

    @MainActor
    static func postCreateTabRequest(url: URL?, activate: Bool = true) {
        var userInfo: [String: Any] = [UserInfoKey.activate: activate]
        if let url {
            userInfo[UserInfoKey.url] = url
        }
        NotificationCenter.default.post(name: requestCreateTab, object: nil, userInfo: userInfo)
    }

    @MainActor
    static func postPresentManagerRequest() {
        NotificationCenter.default.post(name: requestPresentManager, object: nil)
    }
}
