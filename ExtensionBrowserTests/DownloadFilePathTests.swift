import XCTest
@testable import ExtensionBrowser

final class DownloadFilePathTests: XCTestCase {
    func testSuggestedFilenameCannotTraverseOrSpoofItsExtension() {
        XCTAssertEqual(DownloadFilePath.sanitizedFilename("../../report.pdf"), "report.pdf")
        XCTAssertEqual(
            DownloadFilePath.sanitizedFilename("invoice\u{202E}fdp.exe"),
            "invoicefdp.exe"
        )
        XCTAssertEqual(DownloadFilePath.sanitizedFilename(".."), "Download")
    }

    func testDuplicateFilenameReceivesDeterministicUniqueSuffix() throws {
        let directory = temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("report.pdf"))
        try Data().write(to: directory.appendingPathComponent("report (2).pdf"))

        let destination = try DownloadFilePath.uniqueDestination(
            in: directory,
            suggestedFilename: "report.pdf"
        )

        XCTAssertEqual(destination.lastPathComponent, "report (3).pdf")
        XCTAssertTrue(DownloadFilePath.isDirectChild(destination, of: directory))
    }

    func testOnlySchemaValidInternalPartialNamesAreRecognized() {
        let identifier = UUID()
        XCTAssertEqual(
            DownloadFilePath.internalPartialIdentifier(
                ".kiwix-\(identifier.uuidString.lowercased()).partial"
            ),
            identifier
        )
        XCTAssertNil(DownloadFilePath.internalPartialIdentifier("../.kiwix-\(identifier).partial"))
        XCTAssertNil(DownloadFilePath.internalPartialIdentifier(".kiwix-not-a-uuid.partial"))
        XCTAssertNil(DownloadFilePath.internalPartialIdentifier("\(identifier).partial"))
    }

    private func temporaryDirectory() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("DownloadFilePathTests-\(UUID().uuidString)", isDirectory: true)
        try! FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
