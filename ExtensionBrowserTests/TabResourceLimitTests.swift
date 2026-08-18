import XCTest
@testable import ExtensionBrowser

@MainActor
final class TabResourceLimitTests: XCTestCase {
    func testGlobalTabCountLimitIsEnforced() throws {
        let manager = TabManager(maximumWarmTabs: 0, maximumTabCount: 2)
        _ = try manager.createTab(select: false)
        _ = try manager.createTab(select: false)

        XCTAssertThrowsError(try manager.createTab(select: false)) { error in
            XCTAssertEqual(error as? TabManager.TabCreationError, .maximumTabCountReached(2))
        }
        XCTAssertEqual(manager.tabs.count, 2)
    }
}
