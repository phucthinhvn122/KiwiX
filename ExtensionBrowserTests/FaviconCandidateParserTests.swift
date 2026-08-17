import XCTest
@testable import ExtensionBrowser

final class FaviconCandidateParserTests: XCTestCase {
    func testParsesRelativeCandidatesAndAddsOriginFallback() throws {
        let pageURL = try XCTUnwrap(URL(string: "https://Example.com/articles/one"))
        let result: [[String: Any]] = [
            ["href": "../icon.png", "rel": "shortcut icon", "type": "image/png", "sizes": "32x32 64x64"],
            ["href": "/touch.png", "rel": "apple-touch-icon", "type": "image/png", "sizes": "180x180"]
        ]

        let candidates = FaviconCandidateParser.candidates(from: result, pageURL: pageURL)

        XCTAssertEqual(candidates.count, 3)
        XCTAssertEqual(candidates[0].url.absoluteString, "https://example.com/icon.png")
        XCTAssertEqual(candidates[0].declaredSizes, [32, 64])
        XCTAssertEqual(candidates.last?.url.absoluteString, "https://example.com/favicon.ico")
    }

    func testRejectsNonIconRelationshipsAndUnsafeSchemes() throws {
        let pageURL = try XCTUnwrap(URL(string: "https://example.com"))
        let result: [[String: Any]] = [
            ["href": "data:image/png;base64,AAAA", "rel": "icon"],
            ["href": "file:///tmp/icon.png", "rel": "icon"],
            ["href": "/feed.xml", "rel": "alternate"],
            ["href": "https://user:secret@example.com/icon.png", "rel": "icon"]
        ]

        let candidates = FaviconCandidateParser.candidates(from: result, pageURL: pageURL)

        XCTAssertEqual(candidates.map(\.url.absoluteString), ["https://example.com/favicon.ico"])
    }

    func testHTTPSPageRejectsDowngradedHTTPIcon() throws {
        let pageURL = try XCTUnwrap(URL(string: "https://example.com"))
        let result: [[String: Any]] = [
            ["href": "http://example.com/icon.png", "rel": "icon"]
        ]

        let candidates = FaviconCandidateParser.candidates(from: result, pageURL: pageURL)

        XCTAssertEqual(candidates.count, 1)
        XCTAssertEqual(candidates[0].relationship, "fallback")
    }

    func testDuplicateCanonicalURLsAreCollapsed() throws {
        let pageURL = try XCTUnwrap(URL(string: "https://example.com/page"))
        let result: [[String: Any]] = [
            ["href": "https://EXAMPLE.com:443/icon.png#one", "rel": "icon"],
            ["href": "https://example.com/icon.png#two", "rel": "icon"]
        ]

        let candidates = FaviconCandidateParser.candidates(
            from: result,
            pageURL: pageURL,
            includeFallback: false
        )

        XCTAssertEqual(candidates.count, 1)
    }
}
