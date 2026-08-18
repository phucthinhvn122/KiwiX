import XCTest
@testable import ExtensionBrowser

final class DownloadResourcePolicyTests: XCTestCase {
    func testKnownLengthOverLimitIsRejected() {
        let policy = DownloadResourcePolicy(
            maximumDownloadBytes: 100,
            minimumFreeSpaceReserveBytes: 20
        )
        XCTAssertFalse(policy.permits(expectedBytes: 101, availableBytes: 1_000))
    }

    func testUnknownLengthIsAbortedWhenStreamExceedsLimit() {
        let policy = DownloadResourcePolicy(
            maximumDownloadBytes: 100,
            minimumFreeSpaceReserveBytes: 20
        )
        XCTAssertTrue(policy.permits(expectedBytes: -1, availableBytes: 120))
        XCTAssertTrue(policy.shouldAbort(receivedBytes: 101, availableBytes: 1_000))
    }

    func testDiskReserveIsEnforced() {
        let policy = DownloadResourcePolicy(
            maximumDownloadBytes: 100,
            minimumFreeSpaceReserveBytes: 20
        )
        XCTAssertFalse(policy.permits(expectedBytes: 50, availableBytes: 69))
        XCTAssertTrue(policy.shouldAbort(receivedBytes: 10, availableBytes: 19))
    }
}
