import XCTest
@testable import ExtensionBrowser

@MainActor
final class DocumentIdleSchedulerTests: XCTestCase {
    func testDocumentIdleIsDeferredUntilAfterSchedulingTurn() async throws {
        let scheduler = DocumentIdleScheduler(delayNanoseconds: 1_000_000)
        let counter = MainActorCounter()

        scheduler.schedule(tabID: UUID()) { counter.value += 1 }
        XCTAssertEqual(counter.value, 0)

        try await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(counter.value, 1)
    }

    func testNavigationCancellationAndReplacementPreventStaleIdleWork() async throws {
        let scheduler = DocumentIdleScheduler(delayNanoseconds: 2_000_000)
        let counter = MainActorCounter()
        let cancelledTab = UUID()
        let replacedTab = UUID()

        scheduler.schedule(tabID: cancelledTab) { counter.value += 10 }
        scheduler.cancel(tabID: cancelledTab)
        scheduler.schedule(tabID: replacedTab) { counter.value += 100 }
        scheduler.schedule(tabID: replacedTab) { counter.value += 1 }

        try await Task.sleep(nanoseconds: 30_000_000)
        XCTAssertEqual(counter.value, 1)
    }
}

@MainActor
private final class MainActorCounter {
    var value = 0
}
