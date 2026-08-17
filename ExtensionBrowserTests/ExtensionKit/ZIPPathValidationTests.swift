import XCTest
@testable import ExtensionBrowser

final class ZIPPathValidationTests: XCTestCase {
    func testAcceptsNormalizedRelativePaths() throws {
        XCTAssertEqual(try SafeZIPExtractor.validateEntryPath("scripts/content.js"), "scripts/content.js")
        XCTAssertEqual(try SafeZIPExtractor.validateEntryPath("images/", isDirectory: true), "images")
        XCTAssertEqual(try SafeZIPExtractor.validateEntryPath("é"), "é")
    }

    func testRejectsTraversalAbsoluteWindowsAndAmbiguousPaths() {
        let paths = [
            "../escape.js", "a/../../escape.js", "/absolute.js", "C:/windows.dll",
            "a\\escape.js", "a//b.js", "./content.js", "line\nbreak.js"
        ]
        for path in paths {
            XCTAssertThrowsError(try SafeZIPExtractor.validateEntryPath(path), "Expected rejection for \(path)")
        }
    }

    func testEntryLimitStopsEnumerationAtFirstExcessEntry() {
        let sequence = CountingSequence(elementCount: 100)

        XCTAssertThrowsError(
            try SafeZIPExtractor.collectEntries(sequence, maximumCount: 2)
        ) { error in
            XCTAssertEqual(error as? ExtensionInstallError, .tooManyEntries(limit: 2))
        }
        XCTAssertEqual(sequence.nextCallCount, 3)
    }
}

private final class CountingSequence: Sequence, IteratorProtocol {
    typealias Element = Int

    private let elementCount: Int
    private var nextValue = 0
    private(set) var nextCallCount = 0

    init(elementCount: Int) {
        self.elementCount = elementCount
    }

    func makeIterator() -> CountingSequence { self }

    func next() -> Int? {
        nextCallCount += 1
        guard nextValue < elementCount else { return nil }
        defer { nextValue += 1 }
        return nextValue
    }
}
