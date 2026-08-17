import XCTest
@testable import ExtensionBrowser

final class M0InfrastructureBenchmarks: XCTestCase {
    func testLifecyclePlanningForTenTabs() {
        let policy = TabLifecycleManager(maximumWarmTabs: 3)
        let selectedID = UUID()
        let tabs = (0..<10).map { index in
            TabLifecycleDescriptor(
                id: index == 0 ? selectedID : UUID(),
                lastAccessDate: Date(timeIntervalSince1970: TimeInterval(index)),
                hasLiveWebView: true
            )
        }

        measure(metrics: [XCTClockMetric(), XCTMemoryMetric()]) {
            for _ in 0..<1_000 {
                _ = policy.plan(tabs: tabs, selectedTabID: selectedID, aggressive: false)
            }
        }
    }
}
