import UIKit
import WebKit

/// Everything the WebKit runtime asks the app for.
///
/// The protocol is entirely optional-method based, so a signature typo silently disables a
/// callback instead of failing the build. `WebExtensionHostCallCounter` records what actually
/// fired, and the harness test asserts on it — that is the only reliable guard.
extension WebExtensionHost: WKWebExtensionControllerDelegate {
    // MARK: - Windows and tabs

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor extensionContext: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        delegateCalls.record("openWindowsFor")
        return [windowAdapter]
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        focusedWindowFor extensionContext: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        delegateCalls.record("focusedWindowFor")
        return windowAdapter
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        delegateCalls.record("openNewTabUsing")

        // The harness reports over chunked tab URLs when native messaging is unavailable. Those
        // never become real tabs.
        if let url = configuration.url, harnessChannel.ingestBeacon(url: url) {
            completionHandler(nil, nil)
            return
        }

        do {
            let adapter = try openTab(
                url: configuration.url,
                activate: configuration.shouldBeActive,
                for: extensionContext
            )
            completionHandler(adapter, nil)
        } catch {
            completionHandler(nil, error)
        }
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewWindowUsing configuration: WKWebExtension.WindowConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionWindow)?, (any Error)?) -> Void
    ) {
        delegateCalls.record("openNewWindowUsing")
        completionHandler(nil, WebExtensionHostError.additionalWindowsUnsupported)
    }

    // MARK: - UI surfaces (M3)

    func webExtensionController(
        _ controller: WKWebExtensionController,
        openOptionsPageFor extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        delegateCalls.record("openOptionsPageFor")
        completionHandler(WebExtensionHostError.optionsPageUnsupported)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        delegateCalls.record("presentActionPopup")
        completionHandler(WebExtensionHostError.actionPopupUnsupported)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        didUpdate action: WKWebExtension.Action,
        forExtensionContext extensionContext: WKWebExtensionContext
    ) {
        delegateCalls.record("didUpdateAction")
        latestActionBadgeText = action.badgeText
    }

    // MARK: - Permissions

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        delegateCalls.record("promptForPermissions")
        completionHandler(policy(for: extensionContext).autoGrantsRuntimePrompts ? permissions : [], nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionToAccess urls: Set<URL>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<URL>, Date?) -> Void
    ) {
        delegateCalls.record("promptForPermissionToAccess")
        completionHandler(policy(for: extensionContext).autoGrantsRuntimePrompts ? urls : [], nil)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        delegateCalls.record("promptForPermissionMatchPatterns")
        completionHandler(
            policy(for: extensionContext).autoGrantsRuntimePrompts ? matchPatterns : [],
            nil
        )
    }

    // MARK: - Native messaging

    func webExtensionController(
        _ controller: WKWebExtensionController,
        sendMessage message: Any,
        toApplicationWithIdentifier applicationIdentifier: String?,
        for extensionContext: WKWebExtensionContext,
        replyHandler: @escaping (Any?, (any Error)?) -> Void
    ) {
        delegateCalls.record("sendMessage")
        if harnessChannel.ingestNativeMessage(message) {
            replyHandler(["received": true], nil)
            return
        }
        replyHandler(nil, WebExtensionHostError.nativeMessagingUnavailable)
    }

    func webExtensionController(
        _ controller: WKWebExtensionController,
        connectUsing port: WKWebExtension.MessagePort,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        delegateCalls.record("connectUsing")
        completionHandler(WebExtensionHostError.messagePortUnsupported)
    }
}

/// Records which delegate callbacks the runtime actually invoked.
@MainActor
final class WebExtensionHostCallCounter {
    private(set) var counts: [String: Int] = [:]

    func record(_ name: String) {
        counts[name, default: 0] += 1
    }

    func called(_ name: String) -> Bool {
        (counts[name] ?? 0) > 0
    }

    var summary: String {
        counts.keys.sorted().map { "\($0)=\(counts[$0] ?? 0)" }.joined(separator: " ")
    }
}
