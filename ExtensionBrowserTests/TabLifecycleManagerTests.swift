import XCTest
@testable import ExtensionBrowser

final class TabLifecycleManagerTests: XCTestCase {
    func testKeepsActiveAndThreeMostRecentLiveTabsWarm() {
        let ids = (0..<6).map { _ in UUID() }
        let descriptors = ids.enumerated().map { index, id in
            TabLifecycleDescriptor(
                id: id,
                lastAccessDate: Date(timeIntervalSince1970: TimeInterval(index)),
                hasLiveWebView: true
            )
        }

        let plan = TabLifecycleManager(maximumWarmTabs: 3).plan(
            tabs: descriptors,
            selectedTabID: ids[5]
        )

        XCTAssertEqual(plan.activeTabID, ids[5])
        XCTAssertEqual(plan.warmTabIDs, Set([ids[2], ids[3], ids[4]]))
        XCTAssertEqual(plan.suspendedTabIDs, Set([ids[0], ids[1]]))
    }

    func testColdTabsRemainSuspendedInsteadOfBeingRecreated() {
        let activeID = UUID()
        let coldID = UUID()
        let plan = TabLifecycleManager(maximumWarmTabs: 3).plan(
            tabs: [
                TabLifecycleDescriptor(id: activeID, lastAccessDate: Date(), hasLiveWebView: true),
                TabLifecycleDescriptor(id: coldID, lastAccessDate: Date(), hasLiveWebView: false)
            ],
            selectedTabID: activeID
        )

        XCTAssertTrue(plan.warmTabIDs.isEmpty)
        XCTAssertEqual(plan.suspendedTabIDs, [coldID])
    }

    func testAggressivePlanSuspendsEveryBackgroundWebView() {
        let activeID = UUID()
        let backgroundID = UUID()
        let plan = TabLifecycleManager(maximumWarmTabs: 3).plan(
            tabs: [
                TabLifecycleDescriptor(id: activeID, lastAccessDate: Date(), hasLiveWebView: true),
                TabLifecycleDescriptor(id: backgroundID, lastAccessDate: Date(), hasLiveWebView: true)
            ],
            selectedTabID: activeID,
            aggressive: true
        )

        XCTAssertEqual(plan.activeTabID, activeID)
        XCTAssertTrue(plan.warmTabIDs.isEmpty)
        XCTAssertEqual(plan.suspendedTabIDs, [backgroundID])
    }
}
