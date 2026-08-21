import Foundation
import UIKit
import WebKit

@MainActor
protocol TabManagerDelegate: AnyObject {
    func tabManagerDidChangeTabs(_ manager: TabManager)
    func tabManager(_ manager: TabManager, didSelect tab: Tab)
    func tabManager(_ manager: TabManager, didUpdate tab: Tab)
    func tabManager(_ manager: TabManager, didCreateWebViewFor tab: Tab)
    func tabManager(_ manager: TabManager, willSuspend tab: Tab)
}

extension TabManagerDelegate {
    func tabManagerDidChangeTabs(_ manager: TabManager) {}
    func tabManager(_ manager: TabManager, didSelect tab: Tab) {}
    func tabManager(_ manager: TabManager, didUpdate tab: Tab) {}
    func tabManager(_ manager: TabManager, didCreateWebViewFor tab: Tab) {}
    func tabManager(_ manager: TabManager, willSuspend tab: Tab) {}
}

@MainActor
final class TabManager {
    enum TabCreationError: LocalizedError, Equatable {
        case maximumTabCountReached(Int)

        var errorDescription: String? {
            switch self {
            case .maximumTabCountReached(let limit):
                return "The browser can keep at most \(limit) tabs open. Close a tab and try again."
            }
        }
    }

    // `nonisolated`: it is an immutable `Int` on a `@MainActor` type, and it is read from a
    // default argument, which is evaluated in the caller's context rather than this one.
    nonisolated static let defaultMaximumTabCount = SafePersistence.maximumTabCount
    weak var delegate: TabManagerDelegate?

    /// Outbound port to the WebExtension host (M2). Nil until a host attaches, and nil in every
    /// unit test that does not exercise extensions.
    weak var webExtensionObserver: TabWebExtensionObserving?

    private(set) var tabs: [Tab] = []
    private(set) var selectedTabID: UUID?
    private(set) var hasRestoredSession = false

    private let webViewFactory: WebViewFactory
    private let store: TabStore
    private let snapshotManager: TabSnapshotManager
    private var lifecyclePolicy: TabLifecycleManager
    private var lifecycleTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Never>?
    private var lifecycleGeneration = 0
    private let maximumTabCount: Int

    init(
        webViewFactory: WebViewFactory? = nil,
        store: TabStore? = nil,
        snapshotManager: TabSnapshotManager? = nil,
        maximumWarmTabs: Int = 3,
        maximumTabCount: Int = TabManager.defaultMaximumTabCount
    ) {
        self.webViewFactory = webViewFactory ?? WebViewFactory()
        self.store = store ?? TabStore()
        self.snapshotManager = snapshotManager ?? TabSnapshotManager()
        lifecyclePolicy = TabLifecycleManager(maximumWarmTabs: maximumWarmTabs)
        self.maximumTabCount = max(1, maximumTabCount)
    }

    var selectedTab: Tab? {
        guard let selectedTabID else { return nil }
        return tabs.first(where: { $0.id == selectedTabID })
    }

    var liveWebViewCount: Int {
        tabs.lazy.filter { $0.webView != nil }.count
    }

    func tab(id: UUID) -> Tab? {
        tabs.first(where: { $0.id == id })
    }

    func tab(containing webView: WKWebView) -> Tab? {
        tabs.first(where: { $0.webView === webView })
    }

    func restoreSession() async {
        guard !hasRestoredSession else { return }
        hasRestoredSession = true

        let session: TabSession?
        do {
            session = try await store.load()
        } catch {
            AppLog.tabs.error("Could not restore tabs: \(error.localizedDescription, privacy: .private)")
            session = nil
        }

        if let session {
            // Private records are ignored defensively even if an older build wrote one.
            tabs = session.tabs.filter { !$0.isPrivate }.prefix(maximumTabCount).map(Tab.init(record:))
        }

        guard !tabs.isEmpty else {
            _ = try? createTab(url: nil, isPrivate: false, select: true)
            return
        }

        let restoredSelection = session?.selectedTabID.flatMap(tab(id:))
            ?? tabs.max(by: { $0.lastAccessDate < $1.lastAccessDate })

        if let restoredSelection {
            await snapshotManager.loadSnapshot(for: restoredSelection)
            selectedTabID = restoredSelection.id
            activate(restoredSelection)
        }

        // Restored tabs bypass `createTab`, so they have to be announced here or the extension
        // runtime starts with an empty window (ADR-004).
        for tab in tabs where !tab.isPrivate {
            webExtensionObserver?.tabManager(self, didOpenTab: tab)
        }
        if let restoredSelection, !restoredSelection.isPrivate {
            webExtensionObserver?.tabManager(self, didActivateTab: restoredSelection, previousTabID: nil)
        }

        delegate?.tabManagerDidChangeTabs(self)
        if let selectedTab {
            delegate?.tabManager(self, didSelect: selectedTab)
        }

        let backgroundTabs = tabs.filter { $0.id != selectedTabID && $0.snapshotFileName != nil }
        Task { [weak self] in
            guard let self else { return }
            for tab in backgroundTabs {
                guard self.tab(id: tab.id) === tab else { continue }
                await self.snapshotManager.loadSnapshot(for: tab)
                guard self.tab(id: tab.id) === tab else { continue }
                self.delegate?.tabManager(self, didUpdate: tab)
            }
        }
    }

    @discardableResult
    func createTab(
        url: URL? = nil,
        isPrivate: Bool = false,
        select: Bool = true
    ) throws -> Tab {
        guard tabs.count < maximumTabCount else {
            throw TabCreationError.maximumTabCountReached(maximumTabCount)
        }
        let tab = Tab(url: url, isPrivate: isPrivate)
        tabs.append(tab)
        // A tab must be announced as open before it can be activated (ADR-004).
        webExtensionObserver?.tabManager(self, didOpenTab: tab)

        if select {
            selectTab(id: tab.id)
        } else {
            tab.state = .suspended
            delegate?.tabManagerDidChangeTabs(self)
            schedulePersistence()
        }
        return tab
    }

    func closeTab(id: UUID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let closingTab = tabs[index]
        let wasSelected = selectedTabID == id

        tabs.remove(at: index)
        webExtensionObserver?.tabManager(
            self,
            didCloseTabWithID: closingTab.id,
            isPrivate: closingTab.isPrivate
        )
        if wasSelected {
            selectedTabID = nil
            if tabs.isEmpty {
                _ = try? createTab(url: nil, isPrivate: false, select: true)
            } else {
                let replacementIndex = min(index, tabs.count - 1)
                selectTab(id: tabs[replacementIndex].id)
            }
        } else {
            delegate?.tabManagerDidChangeTabs(self)
        }

        closingTab.webView?.stopLoading()
        closingTab.webView?.navigationDelegate = nil
        closingTab.webView?.uiDelegate = nil
        closingTab.webView = nil
        if closingTab.isPrivate, !tabs.contains(where: \.isPrivate) {
            webViewFactory.resetPrivateProfile()
        }
        Task { [snapshotManager] in
            await snapshotManager.deleteSnapshot(for: closingTab)
        }

        scheduleLifecycleRebalance()
        schedulePersistence()
    }

    func selectTab(id: UUID) {
        guard let tab = tab(id: id) else { return }
        PerformanceProfiler.event("Tab Switch")

        let previousTabID = selectedTabID
        if let previous = selectedTab, previous.id != id {
            previous.state = previous.webView == nil ? .suspended : .warm
            delegate?.tabManager(self, didUpdate: previous)
        }

        selectedTabID = id
        tab.lastAccessDate = Date()
        activate(tab)
        if previousTabID != id {
            webExtensionObserver?.tabManager(self, didActivateTab: tab, previousTabID: previousTabID)
        }
        delegate?.tabManager(self, didSelect: tab)
        delegate?.tabManagerDidChangeTabs(self)
        scheduleLifecycleRebalance()
        schedulePersistence()
    }

    func reorderTab(from sourceIndex: Int, to destinationIndex: Int) {
        guard tabs.indices.contains(sourceIndex),
              destinationIndex >= 0,
              destinationIndex <= tabs.count else {
            return
        }

        // Extensions never see private tabs, so the index they knew is the private-excluded one.
        let previousVisibleIndex = tabs.prefix(sourceIndex).filter { !$0.isPrivate }.count
        let tab = tabs.remove(at: sourceIndex)
        let adjustedDestination = min(destinationIndex, tabs.count)
        tabs.insert(tab, at: adjustedDestination)
        webExtensionObserver?.tabManager(self, didMoveTab: tab, fromIndex: previousVisibleIndex)
        delegate?.tabManagerDidChangeTabs(self)
        schedulePersistence()
    }

    func navigate(to url: URL, in tabID: UUID? = nil) {
        let destinationTab: Tab?
        if let tabID {
            destinationTab = tab(id: tabID)
        } else {
            destinationTab = selectedTab
        }
        guard let tab = destinationTab else { return }
        PerformanceProfiler.event("Page Navigation")

        ensureWebView(for: tab)
        if tab.url != url {
            tab.favicon = nil
        }
        tab.url = url
        tab.title = SafePersistence.title(
            url.absoluteString == "about:blank"
                ? "New Tab"
                : SafeInput.displayHost(for: url, fallback: url.absoluteString)
        )
        tab.lastAccessDate = Date()
        tab.needsInitialNavigation = false
        tab.updateFaviconCandidate()
        delegate?.tabManager(self, didUpdate: tab)
        webExtensionObserver?.tabManager(self, didChange: [.title, .url, .loading], for: tab)

        if url.absoluteString == "about:blank" {
            tab.webView?.loadHTMLString("", baseURL: nil)
        } else {
            tab.webView?.load(URLRequest(url: url, cachePolicy: .useProtocolCachePolicy))
        }
        schedulePersistence()
    }

    func loadInitialPageIfNeeded(for tabID: UUID) {
        guard let tab = tab(id: tabID), tab.needsInitialNavigation, let url = tab.url else { return }
        navigate(to: url, in: tabID)
    }

    func updateTab(id: UUID, title: String? = nil, url: URL? = nil) {
        guard let tab = tab(id: id) else { return }
        var change: TabObservedChange = []
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let normalized = SafePersistence.title(title)
            if tab.title != normalized { change.insert(.title) }
            tab.title = normalized
        }
        if let url {
            if tab.url != url {
                tab.favicon = nil
                change.insert(.url)
            }
            tab.url = url
            tab.updateFaviconCandidate()
        }
        tab.lastAccessDate = Date()
        delegate?.tabManager(self, didUpdate: tab)
        if !change.isEmpty {
            webExtensionObserver?.tabManager(self, didChange: change, for: tab)
        }
        schedulePersistence()
    }

    /// Puts a tab's address back to a load that actually committed.
    ///
    /// Distinct from `updateTab(id:url:)`, where `nil` means "leave the URL alone": here `nil` is a
    /// real value. A tab whose provisional load was cancelled before anything committed has no
    /// address at all, and going on showing the target of a load that never happened is the bug
    /// this exists to undo.
    func revertToCommittedURL(tabID: UUID, committedURL: URL?) {
        guard let tab = tab(id: tabID), tab.url != committedURL else { return }
        tab.url = committedURL
        tab.favicon = nil
        tab.updateFaviconCandidate()
        delegate?.tabManager(self, didUpdate: tab)
        webExtensionObserver?.tabManager(self, didChange: [.url], for: tab)
        schedulePersistence()
    }

    func updateFavicon(
        tabID: UUID,
        image: UIImage,
        sourceURL: URL,
        expectedPageURL: URL
    ) {
        guard let tab = tab(id: tabID), tab.url == expectedPageURL else { return }
        tab.favicon = image
        tab.faviconURL = sourceURL
        delegate?.tabManager(self, didUpdate: tab)
        schedulePersistence()
    }

    func markRestorationComplete(tabID: UUID) {
        guard let tab = tab(id: tabID) else { return }
        tab.isRestoringFromSuspension = false
        delegate?.tabManager(self, didUpdate: tab)
    }

    func handleMemoryWarning() {
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        lifecycleTask?.cancel()
        lifecycleTask = Task { [weak self] in
            await self?.applyLifecyclePlan(aggressive: true, generation: generation)
        }
    }

    func prepareForBackground() async {
        if let selectedTab {
            _ = await snapshotManager.capture(tab: selectedTab)
            delegate?.tabManager(self, didUpdate: selectedTab)
        }
        await persistImmediately()
    }

    func persistImmediately() async {
        persistenceTask?.cancel()
        let normalTabs = tabs.filter { !$0.isPrivate }
        let records = normalTabs.map(\.record)
        let persistedSelection: UUID?
        if let selectedTabID, normalTabs.contains(where: { $0.id == selectedTabID }) {
            persistedSelection = selectedTabID
        } else {
            persistedSelection = normalTabs.max(by: { $0.lastAccessDate < $1.lastAccessDate })?.id
        }

        do {
            try await store.save(TabSession(selectedTabID: persistedSelection, tabs: records))
        } catch {
            AppLog.tabs.error("Could not persist tabs: \(error.localizedDescription, privacy: .private)")
        }
    }

    private func activate(_ tab: Tab) {
        let wasSuspended = tab.webView == nil
        ensureWebView(for: tab)
        tab.state = .active
        tab.isRestoringFromSuspension = wasSuspended && tab.snapshot != nil
    }

    /// Forces a tab's web view into existence. Extensions can target a suspended tab, and a
    /// content script has nowhere to run without one.
    @discardableResult
    func materializeWebView(for tabID: UUID) -> WKWebView? {
        guard let tab = tab(id: tabID) else { return nil }
        ensureWebView(for: tab)
        return tab.webView
    }

    private func ensureWebView(for tab: Tab) {
        guard tab.webView == nil else { return }
        tab.webView = webViewFactory.makeWebView(isPrivate: tab.isPrivate)
        delegate?.tabManager(self, didCreateWebViewFor: tab)
    }

    private func scheduleLifecycleRebalance() {
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        lifecycleTask?.cancel()
        lifecycleTask = Task { [weak self] in
            await Task.yield()
            await self?.applyLifecyclePlan(aggressive: false, generation: generation)
        }
    }

    private func applyLifecyclePlan(aggressive: Bool, generation: Int) async {
        guard generation == lifecycleGeneration else { return }
        let descriptors = tabs.map {
            TabLifecycleDescriptor(
                id: $0.id,
                lastAccessDate: $0.lastAccessDate,
                hasLiveWebView: $0.webView != nil
            )
        }
        let plan = lifecyclePolicy.plan(
            tabs: descriptors,
            selectedTabID: selectedTabID,
            aggressive: aggressive
        )

        for tab in tabs {
            if tab.id == plan.activeTabID {
                tab.state = .active
            } else if plan.warmTabIDs.contains(tab.id) {
                tab.state = .warm
            } else if tab.webView == nil {
                tab.state = .suspended
            }
        }

        let tabsToSuspend = tabs.filter {
            plan.suspendedTabIDs.contains($0.id) && $0.webView != nil
        }

        for tab in tabsToSuspend {
            guard generation == lifecycleGeneration,
                  tab.id != selectedTabID else {
                return
            }

            delegate?.tabManager(self, willSuspend: tab)
            _ = await snapshotManager.capture(tab: tab)

            guard generation == lifecycleGeneration,
                  tab.id != selectedTabID else {
                return
            }
            tab.webView?.stopLoading()
            tab.webView?.navigationDelegate = nil
            tab.webView?.uiDelegate = nil
            tab.webView = nil
            tab.needsInitialNavigation = tab.url != nil && tab.url?.absoluteString != "about:blank"
            tab.state = .suspended
            tab.isRestoringFromSuspension = false
            delegate?.tabManager(self, didUpdate: tab)
        }

        await persistImmediately()
    }

    private func schedulePersistence() {
        persistenceTask?.cancel()
        persistenceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await self?.persistImmediately()
        }
    }
}
