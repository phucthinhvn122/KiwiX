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
    weak var delegate: TabManagerDelegate?

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

    init(
        webViewFactory: WebViewFactory = WebViewFactory(),
        store: TabStore = TabStore(),
        snapshotManager: TabSnapshotManager = TabSnapshotManager(),
        maximumWarmTabs: Int = 3
    ) {
        self.webViewFactory = webViewFactory
        self.store = store
        self.snapshotManager = snapshotManager
        lifecyclePolicy = TabLifecycleManager(maximumWarmTabs: maximumWarmTabs)
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
            AppLog.tabs.error("Could not restore tabs: \(error.localizedDescription, privacy: .public)")
            session = nil
        }

        if let session {
            // Private records are ignored defensively even if an older build wrote one.
            tabs = session.tabs.filter { !$0.isPrivate }.map(Tab.init(record:))
        }

        guard !tabs.isEmpty else {
            _ = createTab(url: nil, isPrivate: false, select: true)
            return
        }

        let restoredSelection = session?.selectedTabID.flatMap(tab(id:))
            ?? tabs.max(by: { $0.lastAccessDate < $1.lastAccessDate })

        if let restoredSelection {
            await snapshotManager.loadSnapshot(for: restoredSelection)
            selectedTabID = restoredSelection.id
            activate(restoredSelection)
        }

        delegate?.tabManagerDidChangeTabs(self)
        if let selectedTab {
            delegate?.tabManager(self, didSelect: selectedTab)
        }

        let backgroundTabs = tabs.filter { $0.id != selectedTabID && $0.snapshotFileName != nil }
        Task { [weak self] in
            guard let self else { return }
            for tab in backgroundTabs {
                await self.snapshotManager.loadSnapshot(for: tab)
                self.delegate?.tabManager(self, didUpdate: tab)
            }
        }
    }

    @discardableResult
    func createTab(
        url: URL? = nil,
        isPrivate: Bool = false,
        select: Bool = true
    ) -> Tab {
        let tab = Tab(url: url, isPrivate: isPrivate)
        tabs.append(tab)

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
        if wasSelected {
            selectedTabID = nil
            if tabs.isEmpty {
                _ = createTab(url: nil, isPrivate: false, select: true)
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
        Task { [snapshotManager] in
            await snapshotManager.deleteSnapshot(for: closingTab)
        }

        scheduleLifecycleRebalance()
        schedulePersistence()
    }

    func selectTab(id: UUID) {
        guard let tab = tab(id: id) else { return }
        PerformanceProfiler.event("Tab Switch")

        if let previous = selectedTab, previous.id != id {
            previous.state = previous.webView == nil ? .suspended : .warm
            delegate?.tabManager(self, didUpdate: previous)
        }

        selectedTabID = id
        tab.lastAccessDate = Date()
        activate(tab)
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

        let tab = tabs.remove(at: sourceIndex)
        let adjustedDestination = min(destinationIndex, tabs.count)
        tabs.insert(tab, at: adjustedDestination)
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
        tab.title = url.host ?? (url.absoluteString == "about:blank" ? "New Tab" : url.absoluteString)
        tab.lastAccessDate = Date()
        tab.needsInitialNavigation = false
        tab.updateFaviconCandidate()
        delegate?.tabManager(self, didUpdate: tab)

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
        if let title, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            tab.title = title
        }
        if let url {
            if tab.url != url {
                tab.favicon = nil
            }
            tab.url = url
            tab.updateFaviconCandidate()
        }
        tab.lastAccessDate = Date()
        delegate?.tabManager(self, didUpdate: tab)
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
            AppLog.tabs.error("Could not persist tabs: \(error.localizedDescription, privacy: .public)")
        }
    }

    private func activate(_ tab: Tab) {
        let wasSuspended = tab.webView == nil
        ensureWebView(for: tab)
        tab.state = .active
        tab.isRestoringFromSuspension = wasSuspended && tab.snapshot != nil
    }

    private func ensureWebView(for tab: Tab) {
        guard tab.webView == nil else { return }
        tab.webView = webViewFactory.makeWebView(tabID: tab.id, isPrivate: tab.isPrivate)
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
