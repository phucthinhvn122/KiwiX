import UIKit
import WebKit

/// Bridges one browser tab to `WKWebExtensionTab`.
///
/// ADR-004: identity is 1:1 with `Tab.id` for the whole life of the tab. Suspending a tab frees
/// its `WKWebView` but never the adapter, so `tabs.*` ids stay stable across memory pressure.
/// Every accessor reads through to `TabManager` instead of caching, so a suspended tab reports
/// its persisted title/URL and simply has no web view.
@MainActor
final class WebExtensionTabAdapter: NSObject, WKWebExtensionTab {
    let tabID: UUID
    private weak var host: WebExtensionHost?

    init(tabID: UUID, host: WebExtensionHost) {
        self.tabID = tabID
        self.host = host
        super.init()
    }

    private var tabManager: TabManager? { host?.tabManager }
    private var tab: Tab? { tabManager?.tab(id: tabID) }

    // MARK: - Identity

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        guard tab != nil else { return nil }
        return host?.windowAdapter
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        host?.visibleIndex(of: tabID) ?? NSNotFound
    }

    func parentTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        nil
    }

    // MARK: - Content

    func webView(for context: WKWebExtensionContext) -> WKWebView? {
        tab?.webView
    }

    func title(for context: WKWebExtensionContext) -> String? {
        tab?.title
    }

    func url(for context: WKWebExtensionContext) -> URL? {
        tab?.url
    }

    func pendingURL(for context: WKWebExtensionContext) -> URL? {
        nil
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool {
        guard let webView = tab?.webView else { return true }
        return !webView.isLoading
    }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        tabManager?.selectedTabID == tabID
    }

    func size(for context: WKWebExtensionContext) -> CGSize {
        tab?.webView?.bounds.size ?? .zero
    }

    func zoomFactor(for context: WKWebExtensionContext) -> Double {
        Double(tab?.webView?.pageZoom ?? 1)
    }

    func setZoomFactor(
        _ zoomFactor: Double,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        tab?.webView?.pageZoom = CGFloat(zoomFactor)
        completionHandler(nil)
    }

    // MARK: - Navigation

    func loadURL(
        _ url: URL,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let host, let tabManager else {
            completionHandler(WebExtensionHostError.tabCreationFailed("No browser attached."))
            return
        }
        if host.loadInterceptedPageIfNeeded(url: url, tabID: tabID) {
            completionHandler(nil)
            return
        }
        tabManager.navigate(to: url, in: tabID)
        completionHandler(nil)
    }

    func reload(
        fromOrigin: Bool,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        if fromOrigin {
            tab?.webView?.reloadFromOrigin()
        } else {
            tab?.webView?.reload()
        }
        completionHandler(nil)
    }

    func goBack(
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        tab?.webView?.goBack()
        completionHandler(nil)
    }

    func goForward(
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        tab?.webView?.goForward()
        completionHandler(nil)
    }

    // MARK: - Lifecycle

    func activate(
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard tab != nil, let tabManager else {
            completionHandler(WebExtensionHostError.tabCreationFailed("Tab no longer exists."))
            return
        }
        tabManager.selectTab(id: tabID)
        completionHandler(nil)
    }

    func setSelected(
        _ selected: Bool,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        // The browser has a single selected tab, so selecting means activating and deselecting
        // is a no-op rather than an error.
        if selected {
            tabManager?.selectTab(id: tabID)
        }
        completionHandler(nil)
    }

    func close(
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        tabManager?.closeTab(id: tabID)
        completionHandler(nil)
    }

    func duplicate(
        using configuration: WKWebExtension.TabConfiguration,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        guard let host else {
            completionHandler(nil, WebExtensionHostError.tabCreationFailed("No browser attached."))
            return
        }
        do {
            let adapter = try host.openTab(
                url: configuration.url ?? tab?.url,
                activate: configuration.shouldBeActive
            )
            completionHandler(adapter, nil)
        } catch {
            completionHandler(nil, error)
        }
    }

    // MARK: - Permissions

    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool {
        // Spec §7: no implicit host grants. M3 replaces this with the permission sheet.
        false
    }

    func shouldBypassPermissions(for context: WKWebExtensionContext) -> Bool {
        false
    }
}
