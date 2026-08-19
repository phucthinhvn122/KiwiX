import UIKit
import WebKit

/// Owns the `WKWebExtensionController` and everything the platform needs from the browser.
///
/// ADR-001: this is Path A. The extension runtime is Apple's (iOS 18.4+); the app only supplies
/// the tab/window model, the permission answers and the UI surfaces. Nothing here parses a
/// manifest or implements a `chrome.*` API.
@MainActor
final class WebExtensionHost: NSObject {
    let controller: WKWebExtensionController
    let harnessChannel = WebExtensionHarnessChannel()
    /// Evidence that the runtime really called us — see `WebExtensionHost+Delegate`.
    let delegateCalls = WebExtensionHostCallCounter()
    var latestActionBadgeText: String?

    private(set) weak var tabManager: TabManager?
    private(set) var loadedContexts: [WKWebExtensionContext] = []
    private(set) var sessionStarted = false

    private var tabAdapters: [UUID: WebExtensionTabAdapter] = [:]
    private var policies: [ObjectIdentifier: WebExtensionPermissionPolicy] = [:]

    /// Test-only hook: serves canned HTML for a URL instead of hitting the network, so
    /// content-script probes are deterministic and offline.
    var simulatedPageProvider: ((URL) -> String?)?

    private(set) lazy var windowAdapter = WebExtensionWindowAdapter(host: self)

    /// - Parameter configuration: pass `nil` for the shared persistent store. Default arguments are
    ///   evaluated outside the actor, so `.default()` cannot be spelled in the signature.
    init(configuration: WKWebExtensionController.Configuration? = nil) {
        controller = WKWebExtensionController(configuration: configuration ?? .default())
        super.init()
        controller.delegate = self
    }

    // MARK: - Browser wiring

    func attach(tabManager: TabManager) {
        self.tabManager = tabManager
        tabManager.webExtensionObserver = self
    }

    /// Announces the current browser state to the controller. Ordering matters: the window has to
    /// exist before its tabs, and a tab has to be open before it can be activated (ADR-004).
    func startSession() {
        guard !sessionStarted else { return }
        sessionStarted = true

        controller.didOpenWindow(windowAdapter)
        controller.didFocusWindow(windowAdapter)

        for tab in visibleTabs() {
            controller.didOpenTab(adapter(for: tab))
        }
        if let active = activeTabAdapter() {
            controller.didActivateTab(active, previousActiveTab: nil)
        }
    }

    func endSession() {
        guard sessionStarted else { return }
        sessionStarted = false
        controller.didCloseWindow(windowAdapter)
    }

    // MARK: - Extension lifecycle

    @discardableResult
    func loadExtension(
        resourceBaseURL: URL,
        policy: WebExtensionPermissionPolicy
    ) async throws -> WKWebExtensionContext {
        let webExtension = try await WKWebExtension(resourceBaseURL: resourceBaseURL)
        let context = WKWebExtensionContext(for: webExtension)

        #if DEBUG
        context.isInspectable = true
        #endif

        apply(policy: policy, to: context, for: webExtension)
        policies[ObjectIdentifier(context)] = policy

        try controller.load(context)
        loadedContexts.append(context)
        AppLog.extensions.info("Loaded web extension context (manifest v\(webExtension.manifestVersion, privacy: .public))")
        return context
    }

    func unloadAll() {
        for context in loadedContexts {
            try? controller.unload(context)
        }
        loadedContexts.removeAll()
        policies.removeAll()
    }

    /// - Parameter timeout: seconds to wait before giving up. Required in tests: a manifest the
    ///   runtime cannot start (an MV3 `service_worker`, for one) never calls the completion handler
    ///   at all, so without a deadline the caller hangs instead of learning that fact.
    func loadBackgroundContent(
        for context: WKWebExtensionContext,
        timeout: TimeInterval? = nil
    ) async throws {
        let resumeOnce = ResumeOnce()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if let timeout {
                Task {
                    try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                    guard resumeOnce.claim() else { return }
                    continuation.resume(throwing: WebExtensionHostError.backgroundContentTimedOut(timeout))
                }
            }
            context.loadBackgroundContent { error in
                guard resumeOnce.claim() else { return }
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func policy(for context: WKWebExtensionContext) -> WebExtensionPermissionPolicy {
        policies[ObjectIdentifier(context)] ?? .denyAll
    }

    private func apply(
        policy: WebExtensionPermissionPolicy,
        to context: WKWebExtensionContext,
        for webExtension: WKWebExtension
    ) {
        guard policy == .trustFirstPartyBundle else { return }
        for permission in webExtension.requestedPermissions {
            context.setPermissionStatus(.grantedExplicitly, for: permission)
        }
        for pattern in webExtension.requestedPermissionMatchPatterns {
            context.setPermissionStatus(.grantedExplicitly, for: pattern)
        }
    }

    // MARK: - Tab registry

    func adapter(for tab: Tab) -> WebExtensionTabAdapter {
        if let existing = tabAdapters[tab.id] { return existing }
        let adapter = WebExtensionTabAdapter(tabID: tab.id, host: self)
        tabAdapters[tab.id] = adapter
        return adapter
    }

    func existingAdapter(id: UUID) -> WebExtensionTabAdapter? {
        tabAdapters[id]
    }

    /// Private tabs are invisible to extensions (spec §7).
    func visibleTabs() -> [Tab] {
        tabManager?.tabs.filter { !$0.isPrivate } ?? []
    }

    func visibleTabAdapters() -> [any WKWebExtensionTab] {
        visibleTabs().map { adapter(for: $0) }
    }

    func activeTabAdapter() -> WebExtensionTabAdapter? {
        guard let selected = tabManager?.selectedTab, !selected.isPrivate else { return nil }
        return adapter(for: selected)
    }

    func visibleIndex(of tabID: UUID) -> Int {
        visibleTabs().firstIndex { $0.id == tabID } ?? NSNotFound
    }

    // MARK: - Tab operations requested by extensions

    @discardableResult
    func openTab(url: URL?, activate: Bool) throws -> WebExtensionTabAdapter {
        guard let tabManager else {
            throw WebExtensionHostError.tabCreationFailed("No browser is attached to the extension host.")
        }

        let tab: Tab
        do {
            tab = try tabManager.createTab(url: nil, isPrivate: false, select: activate)
        } catch {
            throw WebExtensionHostError.tabCreationFailed(SafeInput.userFacingError(error))
        }
        let adapter = adapter(for: tab)

        if let url {
            if simulatedPageProvider?(url) != nil {
                tabManager.materializeWebView(for: tab.id)
                _ = loadInterceptedPageIfNeeded(url: url, tabID: tab.id)
            } else {
                tabManager.navigate(to: url, in: tab.id)
            }
        }
        return adapter
    }

    /// - Returns: `true` when the URL was served locally and no network load should happen.
    @discardableResult
    func loadInterceptedPageIfNeeded(url: URL, tabID: UUID) -> Bool {
        guard let html = simulatedPageProvider?(url),
              let tabManager,
              let tab = tabManager.tab(id: tabID),
              let webView = tab.webView else {
            return false
        }
        _ = webView.loadSimulatedRequest(URLRequest(url: url), responseHTML: html)
        tabManager.updateTab(id: tabID, url: url)
        return true
    }
}

// MARK: - TabWebExtensionObserving

extension WebExtensionHost: TabWebExtensionObserving {
    func tabManager(_ manager: TabManager, didOpenTab tab: Tab) {
        guard sessionStarted, !tab.isPrivate else { return }
        controller.didOpenTab(adapter(for: tab))
    }

    func tabManager(_ manager: TabManager, didCloseTabWithID tabID: UUID, isPrivate: Bool) {
        guard let adapter = tabAdapters.removeValue(forKey: tabID) else { return }
        guard sessionStarted, !isPrivate else { return }
        controller.didCloseTab(adapter, windowIsClosing: false)
    }

    func tabManager(_ manager: TabManager, didActivateTab tab: Tab, previousTabID: UUID?) {
        guard sessionStarted, !tab.isPrivate else { return }
        let previous = previousTabID.flatMap { tabAdapters[$0] }
        controller.didActivateTab(adapter(for: tab), previousActiveTab: previous)
    }

    func tabManager(_ manager: TabManager, didMoveTab tab: Tab, fromIndex index: Int) {
        guard sessionStarted, !tab.isPrivate else { return }
        controller.didMoveTab(adapter(for: tab), from: index, in: windowAdapter)
    }

    func tabManager(_ manager: TabManager, didChange change: TabObservedChange, for tab: Tab) {
        guard sessionStarted, !tab.isPrivate else { return }
        var properties: WKWebExtension.TabChangedProperties = []
        if change.contains(.title) { properties.insert(.title) }
        if change.contains(.url) { properties.insert(.URL) }
        if change.contains(.loading) { properties.insert(.loading) }
        if change.contains(.size) { properties.insert(.size) }
        guard !properties.isEmpty else { return }
        controller.didChangeTabProperties(properties, for: adapter(for: tab))
    }
}
