import XCTest
@testable import ExtensionBrowser

final class SafePersistenceTests: XCTestCase {
    func testSnapshotTraversalAndMalformedNamesAreRejected() {
        let invalid = ["../outside.jpg", "/tmp/file.jpg", "..\\outside.jpg", "%2e%2e.jpg", "not-a-uuid.jpg"]
        for name in invalid {
            XCTAssertNil(SafePersistence.snapshotFileName(name), name)
        }
        let uuid = UUID()
        XCTAssertEqual(
            SafePersistence.snapshotFileName("\(uuid.uuidString).jpg"),
            "\(uuid.uuidString.lowercased()).jpg"
        )
    }

    func testPersistedTitleUsesUTF8ByteLimit() {
        let title = String(repeating: "🦊", count: 1_000)
        XCTAssertLessThanOrEqual(
            SafePersistence.title(title).utf8.count,
            SafePersistence.maximumTitleBytes
        )
    }

    func testPersistedTitleRemovesNativeUISpoofingFormatting() {
        XCTAssertEqual(SafePersistence.title("Account\u{202E}gpj.exe\u{0000}"), "Accountgpj.exe")
    }

    func testPersistedURLRejectsCredentialsAndOversize() throws {
        XCTAssertFalse(SafePersistence.isSafePersistedURL(
            try XCTUnwrap(URL(string: "https://user:password@example.com"))
        ))
        let huge = "https://example.com/" + String(repeating: "a", count: SafePersistence.maximumURLBytes)
        XCTAssertFalse(SafePersistence.isSafePersistedURL(try XCTUnwrap(URL(string: huge))))
    }

    func testBoundedFileReaderRejectsOversizedFileBeforeReturningData() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoundedFileReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let fileURL = directory.appendingPathComponent("hostile.json")
        try Data(repeating: 0x61, count: 1_025).write(to: fileURL)

        XCTAssertThrowsError(try BoundedFileReader.read(from: fileURL, maximumByteCount: 1_024)) {
            XCTAssertEqual($0 as? BoundedFileReadError, .tooLarge)
        }
    }

    func testJSONPreflightRejectsDeepAndStructurallyAmplifiedInput() {
        let deep = Data((String(repeating: "[", count: 40) + "0" + String(repeating: "]", count: 40)).utf8)
        XCTAssertThrowsError(try BoundedJSONPreflight.validate(deep)) {
            XCTAssertEqual($0 as? BoundedJSONPreflightError, .nestingLimit)
        }

        let amplified = Data("[0,0,0,0]".utf8)
        XCTAssertThrowsError(try BoundedJSONPreflight.validate(amplified, maximumStructuralTokens: 2)) {
            XCTAssertEqual($0 as? BoundedJSONPreflightError, .structuralLimit)
        }

        let escaped = Data((#"{"value":""# + String(repeating: #"\""#, count: 5) + #""}"#).utf8)
        XCTAssertThrowsError(try BoundedJSONPreflight.validate(escaped, maximumStringBytes: 8)) {
            XCTAssertEqual($0 as? BoundedJSONPreflightError, .stringLimit)
        }
    }

    func testBoundedDirectoryReaderStopsAtLimit() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoundedDirectoryReaderTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        for index in 0..<3 {
            try Data("\(index)".utf8).write(to: directory.appendingPathComponent("\(index).txt"))
        }

        let listing = try BoundedDirectoryReader.directChildren(of: directory, maximumEntryCount: 2)

        XCTAssertEqual(listing.entries.count, 2)
        XCTAssertTrue(listing.wasTruncated)
    }

    func testBoundedDirectoryReaderDoesNotDescend() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BoundedDirectoryReaderTests-\(UUID().uuidString)", isDirectory: true)
        let nested = directory.appendingPathComponent("nested", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("nested".utf8).write(to: nested.appendingPathComponent("child.txt"))
        try Data("direct".utf8).write(to: directory.appendingPathComponent("direct.txt"))

        let listing = try BoundedDirectoryReader.directChildren(of: directory, maximumEntryCount: 10)

        XCTAssertEqual(Set(listing.entries.map(\.lastPathComponent)), ["nested", "direct.txt"])
        XCTAssertFalse(listing.wasTruncated)
    }
}
