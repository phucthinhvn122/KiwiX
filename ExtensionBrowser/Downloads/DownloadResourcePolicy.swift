import Foundation

struct DownloadResourcePolicy: Sendable {
    static let standard = DownloadResourcePolicy()

    let maximumDownloadBytes: Int64
    let largeDownloadWarningBytes: Int64
    let minimumFreeSpaceReserveBytes: Int64
    let maximumConcurrentDownloads: Int

    init(
        maximumDownloadBytes: Int64 = 500 * 1_024 * 1_024,
        largeDownloadWarningBytes: Int64 = 50 * 1_024 * 1_024,
        minimumFreeSpaceReserveBytes: Int64 = 250 * 1_024 * 1_024,
        maximumConcurrentDownloads: Int = 3
    ) {
        self.maximumDownloadBytes = max(1, maximumDownloadBytes)
        self.largeDownloadWarningBytes = max(1, min(largeDownloadWarningBytes, maximumDownloadBytes))
        self.minimumFreeSpaceReserveBytes = max(0, minimumFreeSpaceReserveBytes)
        self.maximumConcurrentDownloads = max(1, maximumConcurrentDownloads)
    }

    func permits(expectedBytes: Int64, availableBytes: Int64?) -> Bool {
        if expectedBytes > maximumDownloadBytes { return false }
        guard let availableBytes else { return false }
        let budget = expectedBytes > 0 ? expectedBytes : maximumDownloadBytes
        let (required, overflow) = minimumFreeSpaceReserveBytes.addingReportingOverflow(budget)
        return !overflow && availableBytes >= required
    }

    func shouldAbort(receivedBytes: Int64, availableBytes: Int64?) -> Bool {
        guard receivedBytes >= 0, receivedBytes <= maximumDownloadBytes,
              let availableBytes,
              availableBytes >= minimumFreeSpaceReserveBytes else { return true }
        return false
    }

    func requiresLargeDownloadConfirmation(expectedBytes: Int64) -> Bool {
        expectedBytes >= largeDownloadWarningBytes
    }
}

final class ActiveDownloadRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var identifiers: Set<UUID> = []

    func insert(_ identifier: UUID) {
        lock.withLock { identifiers.insert(identifier) }
    }

    func remove(_ identifier: UUID) {
        lock.withLock { identifiers.remove(identifier) }
    }

    func removeAll() {
        lock.withLock { identifiers.removeAll() }
    }

    func contains(_ identifier: UUID) -> Bool {
        lock.withLock { identifiers.contains(identifier) }
    }
}
