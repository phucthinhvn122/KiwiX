import XCTest
@testable import ExtensionBrowser

final class URLInputParserTests: XCTestCase {
    private let parser = URLInputParser(searchEngine: .duckDuckGo)

    func testExplicitHTTPSURLIsPreserved() {
        let resolution = parser.resolve("https://example.com/docs?q=ios")
        XCTAssertEqual(resolution, .url(URL(string: "https://example.com/docs?q=ios")!))
    }

    func testBareDomainGetsSecureScheme() {
        let resolution = parser.resolve("example.com/docs")
        XCTAssertEqual(resolution, .url(URL(string: "https://example.com/docs")!))
    }

    func testLocalhostWithPortIsAURL() {
        let resolution = parser.resolve("localhost:8080/debug")
        XCTAssertEqual(resolution, .url(URL(string: "http://localhost:8080/debug")!))
    }

    func testIPv4AddressIsAURL() {
        let resolution = parser.resolve("192.168.1.10:3000")
        XCTAssertEqual(resolution, .url(URL(string: "http://192.168.1.10:3000")!))
    }

    func testWordsBecomeEncodedSearchQuery() {
        let resolution = parser.resolve("swift concurrency tutorial")
        XCTAssertEqual(
            resolution,
            .search(URL(string: "https://duckduckgo.com/?q=swift%20concurrency%20tutorial")!)
        )
    }

    func testEmailLikeInputBecomesSearchQuery() {
        guard case .search = parser.resolve("person@example.com") else {
            return XCTFail("Email-like input must not be treated as a host with credentials")
        }
    }

    func testBlankInputReturnsNil() {
        XCTAssertNil(parser.resolve("   \n"))
    }

    func testAboutBlankIsSupported() {
        XCTAssertEqual(parser.resolve("about:blank"), .url(URL(string: "about:blank")!))
    }
}
