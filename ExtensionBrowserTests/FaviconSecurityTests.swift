import XCTest
@testable import ExtensionBrowser

final class FaviconSecurityTests: XCTestCase {
    func testCacheKeyCanonicalizesHostDefaultPortAndFragment() throws {
        let first = try XCTUnwrap(URL(string: "HTTPS://EXAMPLE.COM:443/icon.png?v=1#first"))
        let second = try XCTUnwrap(URL(string: "https://example.com/icon.png?v=1#second"))

        XCTAssertEqual(FaviconCacheKey.value(for: first), FaviconCacheKey.value(for: second))
    }

    func testCacheKeyRejectsCredentialsAndLocalFileURL() throws {
        XCTAssertNil(FaviconCacheKey.value(for: URL(string: "https://user:pass@example.com/icon")!))
        XCTAssertNil(FaviconCacheKey.value(for: URL(fileURLWithPath: "/tmp/icon.png")))
    }

    func testFallbackPreservesOriginPortButDropsPageQuery() throws {
        let pageURL = try XCTUnwrap(URL(string: "http://localhost:8080/path?q=secret#fragment"))

        let fallback = FaviconURLPolicy.fallbackURL(for: pageURL)

        XCTAssertEqual(fallback?.absoluteString, "http://localhost:8080/favicon.ico")
    }

    func testImageValidatorRejectsHTMLAndOversizeData() {
        let html = Data("<html><body>not an icon</body></html>".utf8)
        XCTAssertThrowsError(try FaviconImageValidator.validate(data: html, responseMIMEType: "text/html")) {
            XCTAssertEqual($0 as? FaviconValidationError, .unsupportedMIMEType)
        }

        let oversized = Data(repeating: 0, count: FaviconImageValidator.maximumEncodedByteCount + 1)
        XCTAssertThrowsError(try FaviconImageValidator.validate(data: oversized, responseMIMEType: "image/png")) {
            XCTAssertEqual($0 as? FaviconValidationError, .responseTooLarge)
        }
    }
}
