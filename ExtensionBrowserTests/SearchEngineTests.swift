import XCTest
@testable import ExtensionBrowser

final class SearchEngineTests: XCTestCase {
    func testRejectsTemplateWithoutPlaceholder() {
        XCTAssertNil(SearchEngine(id: "invalid", name: "Invalid", queryURLTemplate: "https://example.com"))
    }

    func testRejectsNonWebTemplate() {
        XCTAssertNil(SearchEngine(id: "invalid", name: "Invalid", queryURLTemplate: "file:///{query}"))
    }

    func testCustomEngineEncodesReservedQueryCharacters() {
        let engine = SearchEngine(
            id: "custom",
            name: "Custom",
            queryURLTemplate: "https://example.com/search?q={query}"
        )!
        XCTAssertEqual(
            engine.searchURL(for: "a&b=c")?.absoluteString,
            "https://example.com/search?q=a%26b%3Dc"
        )
    }
}
