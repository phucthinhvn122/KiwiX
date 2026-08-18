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

    func testFallbackRejectsLocalhostAndPrivateDestinations() throws {
        XCTAssertNil(FaviconURLPolicy.fallbackURL(for: try XCTUnwrap(URL(string: "http://localhost:8080/path"))))
        XCTAssertNil(FaviconURLPolicy.fallbackURL(for: try XCTUnwrap(URL(string: "http://127.0.0.1/icon"))))
        XCTAssertNil(FaviconURLPolicy.fallbackURL(for: try XCTUnwrap(URL(string: "http://192.168.1.1/icon"))))
        XCTAssertNil(FaviconURLPolicy.fallbackURL(for: try XCTUnwrap(URL(string: "http://[::1]/icon"))))
    }

    func testPublicHTTPSDestinationIsAccepted() throws {
        let url = try XCTUnwrap(URL(string: "https://8.8.8.8/icon.png"))
        XCTAssertEqual(FaviconURLPolicy.validatedRemoteURL(url), url)
        XCTAssertTrue(NetworkDestinationPolicy.isPublicIPAddress("8.8.8.8"))
        XCTAssertTrue(NetworkDestinationPolicy.isPublicIPAddress("2606:4700:4700::1111"))
    }

    func testReservedAndMappedPrivateAddressesAreRejected() {
        let prohibited = [
            "0.0.0.0", "10.0.0.1", "100.64.0.1", "169.254.1.1", "172.16.0.1",
            "192.0.2.1", "198.51.100.1", "203.0.113.1", "224.0.0.1", "::", "::1",
            "fe80::1", "fc00::1", "ff02::1", "::ffff:192.168.1.1", "2001:db8::1",
            "64:ff9b::192.168.1.1", "64:ff9b:1::1", "3fff::1", "4000::1",
            "5f00::1", "8000::1"
        ]
        for address in prohibited {
            XCTAssertFalse(NetworkDestinationPolicy.isPublicIPAddress(address), address)
        }
    }

    func testRedirectPublicToPrivateIsRejected() async throws {
        let source = try XCTUnwrap(URL(string: "https://8.8.8.8/favicon.ico"))
        let privateTarget = try XCTUnwrap(URL(string: "https://192.168.1.1/favicon.ico"))
        do {
            _ = try await NetworkDestinationPolicy.normalizedPublicHTTPURL(privateTarget, relativeTo: source)
            XCTFail("Expected redirect target to be rejected")
        } catch {
            XCTAssertEqual(error as? NetworkDestinationPolicyError, .prohibitedAddress)
        }
    }

    func testHostnameResolvingToPrivateAddressIsRejected() async throws {
        let url = try XCTUnwrap(URL(string: "https://images.example/icon.png"))
        do {
            _ = try await NetworkDestinationPolicy.normalizedPublicHTTPURL(url) { host in
                XCTAssertEqual(host, "images.example")
                return ["192.168.1.10"]
            }
            XCTFail("Expected private DNS result to be rejected")
        } catch {
            XCTAssertEqual(error as? NetworkDestinationPolicyError, .prohibitedAddress)
        }
    }

    func testHostnameIsAcceptedOnlyWhenEveryDNSAnswerIsPublic() async throws {
        let url = try XCTUnwrap(URL(string: "https://images.example/icon.png"))
        let accepted = try await NetworkDestinationPolicy.normalizedPublicHTTPURL(url) { _ in
            ["8.8.8.8", "2606:4700:4700::1111"]
        }
        XCTAssertEqual(accepted, url)

        await XCTAssertThrowsErrorAsync {
            _ = try await NetworkDestinationPolicy.normalizedPublicHTTPURL(url) { _ in
                ["8.8.8.8", "127.0.0.1"]
            }
        }
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

private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        // Expected.
    }
}
