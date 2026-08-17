import Foundation

struct TabLifecycleDescriptor: Equatable, Sendable {
    let id: UUID
    let lastAccessDate: Date
    let hasLiveWebView: Bool
}

struct TabLifecyclePlan: Equatable, Sendable {
    let activeTabID: UUID?
    let warmTabIDs: Set<UUID>
    let suspendedTabIDs: Set<UUID>
}

struct TabLifecycleManager: Sendable {
    var maximumWarmTabs: Int = 3

    func plan(
        tabs: [TabLifecycleDescriptor],
        selectedTabID: UUID?,
        aggressive: Bool = false
    ) -> TabLifecyclePlan {
        let activeID = selectedTabID.flatMap { selected in
            tabs.contains(where: { $0.id == selected }) ? selected : nil
        }

        let liveBackgroundTabs = tabs
            .filter { $0.id != activeID && $0.hasLiveWebView }
            .sorted { $0.lastAccessDate > $1.lastAccessDate }

        let warmLimit = aggressive ? 0 : max(0, maximumWarmTabs)
        let warmIDs = Set(liveBackgroundTabs.prefix(warmLimit).map(\.id))
        let suspendedIDs = Set(tabs.map(\.id)).subtracting(warmIDs).subtracting(activeID.map { [$0] } ?? [])

        return TabLifecyclePlan(
            activeTabID: activeID,
            warmTabIDs: warmIDs,
            suspendedTabIDs: suspendedIDs
        )
    }
}
