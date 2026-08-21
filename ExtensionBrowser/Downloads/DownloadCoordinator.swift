import Foundation
import WebKit

@MainActor
final class DownloadCoordinator: NSObject, WKDownloadDelegate {
    private static let progressPersistenceInterval: Int64 = 1_048_576

    private let store: DownloadStore
    private let fileManager: FileManager
    private let explicitDownloadsDirectoryURL: URL?
    private let resourcePolicy: DownloadResourcePolicy
    private let activityRegistry = ActiveDownloadRegistry()

    private var itemsByID: [UUID: DownloadItem] = [:]
    private var downloadsByID: [UUID: WKDownload] = [:]
    private var IDsByDownload: [ObjectIdentifier: UUID] = [:]
    private var lastPersistedBytes: [UUID: Int64] = [:]
    private var terminatingDownloadIDs: Set<UUID> = []
    private var progressTimer: Timer?
    private var persistenceTail: Task<Void, Never>?
    private var reloadGeneration = 0

    var onItemsChanged: (([DownloadItem]) -> Void)? {
        didSet { onItemsChanged?(items) }
    }

    var onError: ((String) -> Void)?

    var items: [DownloadItem] {
        itemsByID.values.sorted { lhs, rhs in
            if lhs.createdAt == rhs.createdAt {
                return lhs.id.uuidString < rhs.id.uuidString
            }
            return lhs.createdAt > rhs.createdAt
        }
    }

    func confirmationMessage(expectedBytes: Int64, isPrivate: Bool) -> String? {
        var messages: [String] = []
        if expectedBytes > resourcePolicy.maximumDownloadBytes {
            return maximumSizeMessage
        }
        if resourcePolicy.requiresLargeDownloadConfirmation(expectedBytes: expectedBytes) {
            let size = ByteCountFormatter.string(fromByteCount: expectedBytes, countStyle: .file)
            messages.append("This is a large download (about \(size)).")
        }
        if isPrivate {
            messages.append(
                "Private browsing history will not record it, but the downloaded file will remain on this device until you delete it."
            )
        }
        return messages.isEmpty ? nil : messages.joined(separator: "\n\n")
    }

    var maximumSizeMessage: String {
        let size = ByteCountFormatter.string(fromByteCount: resourcePolicy.maximumDownloadBytes, countStyle: .file)
        return "This file exceeds the \(size) download safety limit."
    }

    func exceedsMaximumSize(expectedBytes: Int64) -> Bool {
        expectedBytes > resourcePolicy.maximumDownloadBytes
    }

    init(
        store: DownloadStore? = nil,
        downloadsDirectoryURL: URL? = nil,
        fileManager: FileManager = .default,
        resourcePolicy: DownloadResourcePolicy = .standard
    ) {
        self.fileManager = fileManager
        explicitDownloadsDirectoryURL = downloadsDirectoryURL
        self.resourcePolicy = resourcePolicy
        self.store = store ?? DownloadStore(
            downloadsDirectoryURL: downloadsDirectoryURL,
            fileManager: fileManager
        )
        super.init()
    }

    deinit {
        progressTimer?.invalidate()
        persistenceTail?.cancel()
    }

    func reload() {
        reloadGeneration += 1
        let generation = reloadGeneration
        let liveIDs = Set(downloadsByID.keys)
        // Serialised behind the same tail as every other store access. `reconciledItems` writes as
        // well as reads — it fails interrupted records, deletes orphan partials and adopts untracked
        // files, then saves — so running it off the chain let a refresh interleave with a pending
        // `remove` or `upsert`. It reads the file before the delete lands and writes it back after,
        // and the record the user just deleted is on disk again.
        let previous = persistenceTail
        persistenceTail = Task { [weak self, store, activityRegistry] in
            await previous?.value
            do {
                let persistedItems = try await store.reconciledItems(
                    excludingLiveIDs: liveIDs,
                    activityRegistry: activityRegistry
                )
                guard let self, generation == self.reloadGeneration else { return }
                let currentLiveIDs = Set(self.downloadsByID.keys)
                self.itemsByID = self.itemsByID.filter { currentLiveIDs.contains($0.key) }
                for item in persistedItems where !currentLiveIDs.contains(item.id) {
                    self.itemsByID[item.id] = item
                }
                self.notifyItemsChanged()
            } catch {
                guard let self, generation == self.reloadGeneration else { return }
                self.report(error)
                self.notifyItemsChanged()
            }
        }
    }

    /// Adopts a WebKit-owned download, preserving the originating web view's cookies and request context.
    /// Private downloads remain visible for this process lifetime but are never written to metadata storage.
    func adopt(_ download: WKDownload, isPrivate: Bool) {
        let objectID = ObjectIdentifier(download)
        guard IDsByDownload[objectID] == nil else { return }
        guard downloadsByID.count < resourcePolicy.maximumConcurrentDownloads else {
            download.cancel { _ in }
            onError?("Too many downloads are already running. Try again when one finishes.")
            return
        }

        let now = Date()
        let item = DownloadItem(
            sourceURL: download.originalRequest?.url,
            isPrivate: isPrivate,
            createdAt: now,
            updatedAt: now
        )
        itemsByID[item.id] = item
        downloadsByID[item.id] = download
        IDsByDownload[objectID] = item.id
        activityRegistry.insert(item.id)
        lastPersistedBytes[item.id] = 0
        download.delegate = self
        persist(item)
        notifyItemsChanged()
    }

    func cancel(id: UUID) {
        guard let download = downloadsByID[id], terminatingDownloadIDs.insert(id).inserted else { return }
        download.cancel { [weak self, weak download] _ in
            guard let download else { return }
            Task { @MainActor [weak self] in
                self?.finish(download, status: .cancelled, error: nil)
            }
        }
    }

    func delete(id: UUID) {
        if let download = downloadsByID[id] {
            download.cancel { _ in }
            discardTracking(for: download)
        }

        if let item = itemsByID.removeValue(forKey: id) {
            removeDownloadedFileIfSafe(item.localFileURL)
        }
        lastPersistedBytes.removeValue(forKey: id)
        terminatingDownloadIDs.remove(id)
        enqueuePersistence { store in
            _ = try await store.remove(id: id)
        }
        stopProgressTimerIfIdle()
        notifyItemsChanged()
    }

    func clearFinished() {
        let finishedItems = itemsByID.values.filter { $0.status.isFinished }
        for item in finishedItems {
            itemsByID.removeValue(forKey: item.id)
            lastPersistedBytes.removeValue(forKey: item.id)
            removeDownloadedFileIfSafe(item.localFileURL)
        }
        enqueuePersistence { store in
            _ = try await store.clearFinished()
        }
        notifyItemsChanged()
    }

    func clearAll() {
        for download in downloadsByID.values {
            download.cancel { _ in }
        }
        for item in itemsByID.values {
            removeDownloadedFileIfSafe(item.localFileURL)
        }
        downloadsByID.removeAll()
        IDsByDownload.removeAll()
        itemsByID.removeAll()
        lastPersistedBytes.removeAll()
        terminatingDownloadIDs.removeAll()
        activityRegistry.removeAll()
        stopProgressTimerIfIdle()
        enqueuePersistence { store in
            _ = try await store.clear()
        }
        notifyItemsChanged()
    }

    func openableFileURL(for id: UUID) -> URL? {
        guard let item = itemsByID[id],
              item.status == .completed,
              let fileURL = item.localFileURL,
              isSafeDownloadFile(fileURL),
              fileManager.fileExists(atPath: fileURL.path) else {
            return nil
        }
        return fileURL
    }

    func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String,
        completionHandler: @escaping (URL?) -> Void
    ) {
        guard let id = IDsByDownload[ObjectIdentifier(download)],
              var item = itemsByID[id] else {
            completionHandler(nil)
            return
        }

        do {
            let directoryURL = try downloadsDirectoryURL()
            try fileManager.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: AppDataProtectionPolicy.Category.download.protection]
            )
            try AppDataProtectionPolicy.apply(
                to: directoryURL,
                category: .download,
                fileManager: fileManager
            )
            let expectedBytes = response.expectedContentLength
            guard resourcePolicy.permits(
                expectedBytes: expectedBytes,
                availableBytes: availableCapacity(at: directoryURL)
            ) else {
                throw DownloadSafetyError.insufficientCapacityOrSizeLimit(resourcePolicy.maximumDownloadBytes)
            }
            // WebKit writes to an unmistakable hidden partial. Only a successful delegate
            // completion moves it to a user-visible unique filename, so startup can always
            // clean interrupted private downloads even though they have no persisted metadata.
            let destinationURL = directoryURL.appendingPathComponent(
                ".kiwix-\(id.uuidString.lowercased()).partial",
                isDirectory: false
            )
            guard DownloadFilePath.isDirectChild(destinationURL, of: directoryURL),
                  !fileManager.fileExists(atPath: destinationURL.path) else {
                throw CocoaError(.fileWriteFileExists)
            }

            let now = Date()
            item.sourceURL = response.url ?? item.sourceURL
            item.fileName = DownloadFilePath.sanitizedFilename(suggestedFilename)
            item.localFileURL = destinationURL
            item.mimeType = response.mimeType
            item.totalBytesExpected = response.expectedContentLength > 0
                ? response.expectedContentLength
                : nil
            item.status = .downloading
            item.updatedAt = now
            item.errorDescription = nil
            itemsByID[id] = item
            persist(item)
            notifyItemsChanged()
            startProgressTimerIfNeeded()
            completionHandler(destinationURL)
        } catch {
            completionHandler(nil)
            finish(download, status: .failed, error: error)
        }
    }

    func downloadDidFinish(_ download: WKDownload) {
        finish(download, status: .completed, error: nil)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let isCancellation = (error as NSError).code == NSURLErrorCancelled
        finish(download, status: isCancellation ? .cancelled : .failed, error: error)
    }

    private func finish(_ download: WKDownload, status: DownloadStatus, error: Error?) {
        guard let id = IDsByDownload[ObjectIdentifier(download)],
              var item = itemsByID[id] else {
            discardTracking(for: download)
            return
        }

        updateProgress(for: id, from: download, forcePersistence: false)
        item = itemsByID[id] ?? item
        let now = Date()
        item.status = status
        item.updatedAt = now
        item.completedAt = now
        item.errorDescription = error.map { boundedErrorDescription($0.localizedDescription) }

        if status == .completed {
            do {
                try finalizePartialFile(for: &item)
            } catch {
                item.status = .failed
                item.errorDescription = "The downloaded file could not be finalized."
                removeDownloadedFileIfSafe(item.localFileURL)
                item.localFileURL = nil
            }
        }

        if item.status == .completed, let fileURL = item.localFileURL {
            if let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
               let size = attributes[.size] as? NSNumber {
                item.bytesReceived = max(item.bytesReceived, size.int64Value)
            }
            if resourcePolicy.shouldAbort(
                receivedBytes: item.bytesReceived,
                availableBytes: availableCapacity(at: fileURL.deletingLastPathComponent())
            ) {
                item.status = .failed
                item.errorDescription = DownloadSafetyError
                    .insufficientCapacityOrSizeLimit(resourcePolicy.maximumDownloadBytes)
                    .localizedDescription
                removeDownloadedFileIfSafe(fileURL)
                item.localFileURL = nil
            } else {
                do {
                    try AppDataProtectionPolicy.apply(
                        to: fileURL,
                        category: .download,
                        fileManager: fileManager
                    )
                } catch {
                    item.status = .failed
                    item.errorDescription = "Could not protect the downloaded file."
                    removeDownloadedFileIfSafe(fileURL)
                    item.localFileURL = nil
                }
            }
        } else {
            removeDownloadedFileIfSafe(item.localFileURL)
            item.localFileURL = nil
        }

        itemsByID[id] = item
        persist(item)
        discardTracking(for: download)
        stopProgressTimerIfIdle()
        notifyItemsChanged()
    }

    private func startProgressTimerIfNeeded() {
        guard progressTimer == nil else { return }
        progressTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshActiveProgress()
            }
        }
    }

    private func stopProgressTimerIfIdle() {
        guard downloadsByID.isEmpty else { return }
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func refreshActiveProgress() {
        var changed = false
        var unsafeDownloads: [(UUID, WKDownload)] = []
        for (id, download) in downloadsByID {
            changed = updateProgress(for: id, from: download, forcePersistence: false) || changed
            // Only a transfer that has been given a destination has a volume to measure. A `.queued`
            // download has no `localFileURL` until `decideDestinationUsing` runs, so the capacity
            // came back nil — and `shouldAbort` reads a missing measurement as "abort", which is the
            // right default for a check that must fail closed and the wrong answer to a question
            // that was never asked. The timer only runs while something is downloading, so adopting
            // a second file while the first was in flight cancelled it inside 250 ms, reporting a
            // storage limit that had not been reached.
            guard let item = itemsByID[id],
                  item.status == .downloading,
                  let directory = item.localFileURL?.deletingLastPathComponent() else { continue }
            if resourcePolicy.shouldAbort(
                receivedBytes: item.bytesReceived,
                availableBytes: availableCapacity(at: directory)
            ) {
                unsafeDownloads.append((id, download))
            }
        }
        for (id, download) in unsafeDownloads {
            guard terminatingDownloadIDs.insert(id).inserted else { continue }
            download.cancel { [weak self, weak download] _ in
                guard let download else { return }
                Task { @MainActor [weak self] in
                    self?.finish(
                        download,
                        status: .failed,
                        error: DownloadSafetyError.insufficientCapacityOrSizeLimit(
                            self?.resourcePolicy.maximumDownloadBytes ?? DownloadResourcePolicy.standard.maximumDownloadBytes
                        )
                    )
                }
            }
        }
        if changed {
            notifyItemsChanged()
        }
    }

    @discardableResult
    private func updateProgress(
        for id: UUID,
        from download: WKDownload,
        forcePersistence: Bool
    ) -> Bool {
        guard var item = itemsByID[id], item.status == .downloading else { return false }
        let progress = download.progress
        var received = max(0, progress.completedUnitCount)
        if let fileURL = item.localFileURL,
           let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
           let fileSize = attributes[.size] as? NSNumber {
            received = max(received, fileSize.int64Value)
        }
        let expected = progress.totalUnitCount > 0
            ? progress.totalUnitCount
            : item.totalBytesExpected

        guard received != item.bytesReceived || expected != item.totalBytesExpected else {
            return false
        }
        item.bytesReceived = received
        item.totalBytesExpected = expected
        item.updatedAt = Date()
        itemsByID[id] = item

        let lastPersisted = lastPersistedBytes[id] ?? 0
        if forcePersistence || received - lastPersisted >= Self.progressPersistenceInterval {
            lastPersistedBytes[id] = received
            persist(item)
        }
        return true
    }

    private func discardTracking(for download: WKDownload) {
        guard let id = IDsByDownload.removeValue(forKey: ObjectIdentifier(download)) else { return }
        downloadsByID.removeValue(forKey: id)
        lastPersistedBytes.removeValue(forKey: id)
        terminatingDownloadIDs.remove(id)
        activityRegistry.remove(id)
    }

    private func persist(_ item: DownloadItem) {
        enqueuePersistence { store in
            try await store.upsert(item, isPrivate: item.isPrivate)
        }
    }

    private func enqueuePersistence(
        _ operation: @escaping @Sendable (DownloadStore) async throws -> Void
    ) {
        let previous = persistenceTail
        persistenceTail = Task { [weak self, store] in
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                try await operation(store)
            } catch {
                self?.report(error)
            }
        }
    }

    private func notifyItemsChanged() {
        onItemsChanged?(items)
    }

    private func report(_ error: Error) {
        onError?(SafeInput.userFacingError(error))
    }

    private func downloadsDirectoryURL() throws -> URL {
        if let explicitDownloadsDirectoryURL {
            return explicitDownloadsDirectoryURL.standardizedFileURL
        }
        return try DownloadFilePath.defaultDirectory(fileManager: fileManager).standardizedFileURL
    }

    private func isSafeDownloadFile(_ fileURL: URL) -> Bool {
        guard let directoryURL = try? downloadsDirectoryURL() else { return false }
        return DownloadFilePath.isDirectChild(fileURL, of: directoryURL)
    }

    private func removeDownloadedFileIfSafe(_ fileURL: URL?) {
        guard let fileURL,
              isSafeDownloadFile(fileURL),
              fileManager.fileExists(atPath: fileURL.path) else {
            return
        }
        do {
            try fileManager.removeItem(at: fileURL)
        } catch {
            report(error)
        }
    }

    private func finalizePartialFile(for item: inout DownloadItem) throws {
        guard let partialURL = item.localFileURL,
              isSafeDownloadFile(partialURL),
              DownloadFilePath.isInternalPartialFilename(partialURL.lastPathComponent),
              fileManager.fileExists(atPath: partialURL.path) else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        let directoryURL = try downloadsDirectoryURL()
        let finalURL = try DownloadFilePath.uniqueDestination(
            in: directoryURL,
            suggestedFilename: item.fileName,
            fileManager: fileManager
        )
        try fileManager.moveItem(at: partialURL, to: finalURL)
        item.fileName = finalURL.lastPathComponent
        item.localFileURL = finalURL
    }

    private func boundedErrorDescription(_ description: String) -> String {
        SafeInput.displayText(description, maximumByteCount: 512, allowsNewlines: true)
    }

    private func availableCapacity(at directory: URL) -> Int64? {
        if let capacity = try? directory.resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey]
        ).volumeAvailableCapacityForImportantUsage {
            return capacity
        }
        let attributes = try? fileManager.attributesOfFileSystem(forPath: directory.path)
        return (attributes?[.systemFreeSize] as? NSNumber)?.int64Value
    }
}

private enum DownloadSafetyError: LocalizedError {
    case insufficientCapacityOrSizeLimit(Int64)

    var errorDescription: String? {
        switch self {
        case .insufficientCapacityOrSizeLimit(let maximumBytes):
            let size = ByteCountFormatter.string(fromByteCount: maximumBytes, countStyle: .file)
            return "The download exceeds the \(size) safety limit or would leave too little free storage."
        }
    }
}
