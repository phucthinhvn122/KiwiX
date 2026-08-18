import Foundation

/// Provides the compatibility runtime's explicit `document_idle` boundary. WebKit has no exact
/// Chrome-equivalent hook, so work is deferred after navigation finish and is cancelled whenever
/// the tab commits another navigation, fails, closes, or receives a replacement idle task.
@MainActor
final class DocumentIdleScheduler {
    private struct Entry {
        let token: UUID
        let task: Task<Void, Never>
    }

    private let delayNanoseconds: UInt64
    private var entries: [UUID: Entry] = [:]

    init(delayNanoseconds: UInt64 = 250_000_000) {
        self.delayNanoseconds = delayNanoseconds
    }

    func schedule(
        tabID: UUID,
        operation: @escaping @MainActor @Sendable () -> Void
    ) {
        cancel(tabID: tabID)
        let token = UUID()
        let delayNanoseconds = self.delayNanoseconds
        let task = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
                try Task.checkCancellation()
            } catch {
                return
            }
            guard let self, self.entries[tabID]?.token == token else { return }
            self.entries.removeValue(forKey: tabID)
            operation()
        }
        entries[tabID] = Entry(token: token, task: task)
    }

    func cancel(tabID: UUID) {
        entries.removeValue(forKey: tabID)?.task.cancel()
    }

    func cancelAll() {
        let tasks = entries.values.map(\.task)
        entries.removeAll(keepingCapacity: false)
        tasks.forEach { $0.cancel() }
    }
}
