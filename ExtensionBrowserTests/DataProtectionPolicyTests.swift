import XCTest
@testable import ExtensionBrowser

final class DataProtectionPolicyTests: XCTestCase {
    func testCategoriesUseExplicitProtectionLevels() {
        XCTAssertEqual(
            AppDataProtectionPolicy.Category.browserState.protection,
            .completeUntilFirstUserAuthentication
        )
        XCTAssertEqual(AppDataProtectionPolicy.Category.download.protection, .completeUnlessOpen)
        XCTAssertEqual(AppDataProtectionPolicy.Category.temporarySensitive.protection, .complete)
    }
}
