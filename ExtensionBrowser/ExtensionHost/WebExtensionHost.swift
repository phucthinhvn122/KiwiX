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
    private let tabRateLimiter = WebExtensionTabRateLimiter()

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

    /// - Parameter uniqueIdentifier: the app's own stable identity for this extension. The default
    ///   `uniqueIdentifier` is a fresh UUID per install — two CI runs of a byte-identical fixture got
    ///   different ids — and it is what the extension sees as `browser.runtime.id`. Anything keyed on
    ///   the default is lost on reinstall, so the installer must supply its own. Apple documents the
    ///   property as settable only while the context is unloaded, which is why this is assigned here
    ///   and not exposed as a mutable knob afterwards.
    @discardableResult
    func loadExtension(
        resourceBaseURL: URL,
        policy: WebExtensionPermissionPolicy,
        uniqueIdentifier: String? = nil
    ) async throws -> WKWebExtensionContext {
        let webExtension = try await WKWebExtension(resourceBaseURL: resourceBaseURL)
        let context = WKWebExtensionContext(for: webExtension)

        if let uniqueIdentifier {
            context.uniqueIdentifier = uniqueIdentifier
        }

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

    /// Looks up a loaded context by the identity the installer assigned it.
    ///
    /// No side table: `uniqueIdentifier` is set at load time and is immutable while loaded, so the
    /// contexts themselves are the registry and cannot drift out of sync with one.
    func loadedContext(uniqueIdentifier: String) -> WKWebExtensionContext? {
        loadedContexts.first { $0.uniqueIdentifier == uniqueIdentifier }
    }

    /// Unloads one extension and drops everything keyed to it.
    ///
    /// The tab budget is forgotten as well. Identifiers survive a disable/enable cycle, and an
    /// extension that was rate-limited before being disabled must not come back still throttled —
    /// nor keep a stale entry alive for a context that no longer exists.
    func unload(_ context: WKWebExtensionContext) {
        try? controller.unload(context)
        loadedContexts.removeAll { $0 === context }
        policies.removeValue(forKey: ObjectIdentifier(context))
        tabRateLimiter.forget(context: context)
    }

    func unloadAll() {
        for context in loadedContexts {
            try? controller.unload(context)
        }
        loadedContexts.removeAll()
        policies.removeAll()
        tabRateLimiter.forgetAll()
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

    /// Writes the install-time decision onto a fresh context, before it is loaded.
    ///
    /// `denyAll` denies *explicitly* instead of leaving the status alone. `.unknown` means "ask",
    /// and there is nobody to ask outside the install sheet, so leaving it unset would make the
    /// outcome depend on whatever the runtime decides to do with an unanswered permission.
    ///
    /// `allRequestedMatchPatterns` is used rather than `requestedPermissionMatchPatterns`: the
    /// latter covers `host_permissions` only, so an extension whose host access comes from its
    /// content-script `matches` would have been granted nothing and quietly failed to run.
    private func apply(
        policy: WebExtensionPermissionPolicy,
        to context: WKWebExtensionContext,
        for webExtension: WKWebExtension
    ) {
        // Optional permissions are included so a decision is recorded for everything the extension
        // could ever ask for, not just what it asks for at install time.
        let everyPermission = webExtension.requestedPermissions
            .union(webExtension.optionalPermissions)
        let everyPattern = webExtension.allRequestedMatchPatterns
            .union(webExtension.optionalPermissionMatchPatterns)

        switch policy {
        case .denyAll:
            for permission in everyPermission {
                context.setPermissionStatus(.deniedExplicitly, for: permission)
            }
            for pattern in everyPattern {
                context.setPermissionStatus(.deniedExplicitly, for: pattern)
            }

        case .trustFirstPartyBundle:
            // Only what the manifest actually requests. Optional permissions stay unanswered even
            // here — a first-party bundle that wants one can go through the same runtime path.
            for permission in webExtension.requestedPermissions {
                context.setPermissionStatus(.grantedExplicitly, for: permission)
            }
            for pattern in webExtension.allRequestedMatchPatterns {
                context.setPermissionStatus(.grantedExplicitly, for: pattern)
            }

        case .userGranted(let permissions, let matchPatterns):
            for permission in everyPermission {
                let granted = permissions.contains(permission.rawValue)
                context.setPermissionStatus(granted ? .grantedExplicitly : .deniedExplicitly, for: permission)
            }
            for pattern in everyPattern {
                let granted = matchPatterns.contains(pattern.string)
                context.setPermissionStatus(granted ? .grantedExplicitly : .deniedExplicitly, for: pattern)
            }
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

    /// - Parameter context: the extension asking. Required, because both the URL check and the rate
    ///   budget are per extension and there must be no caller that bypasses either.
    @discardableResult
    func openTab(
        url: URL?,
        activate: Bool,
        for context: WKWebExtensionContext
    ) throws -> WebExtensionTabAdapter {
        guard let tabManager else {
            throw WebExtensionHostError.tabCreationFailed("No browser is attached to the extension host.")
        }
        if let url, !WebExtensionTabPolicy.isAllowedNavigationURL(url) {
            throw WebExtensionHostError.navigationBlocked(scheme: url.scheme ?? "unknown")
        }
        guard tabRateLimiter.allow(context: context) else {
            throw WebExtensionHostError.tabCreationRateLimited(
                limit: tabRateLimiter.limit,
                seconds: Int(tabRateLimiter.window)
            )
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
