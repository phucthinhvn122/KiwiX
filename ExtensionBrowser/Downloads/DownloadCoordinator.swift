import Foundation
import WebKit

@MainActor
final class DownloadCoordinator: NSObject, WKDownloadDelegate {
    private static let progressPersistenceInterval: Int64 = 1_048_576

    private let store: DownloadStore
    private let fileManager: FileManager
    private let explicitDownloadsDirectoryURL: URL?

    private var itemsByID: [UUID: DownloadItem] = [:]
    private var downloadsByID: [UUID: WKDownload] = [:]
    private var IDsByDownload: [ObjectIdentifier: UUID] = [:]
    private var lastPersistedBytes: [UUID: Int64] = [:]
    private var progressTimer: Timer?
    private var persistenceTail: Task<Void, Never>?

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

    init(
        store: DownloadStore? = nil,
        downloadsDirectoryURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.fileManager = fileManager
        explicitDownloadsDirectoryURL = downloadsDirectoryURL
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
        Task { [weak self, store] in
            do {
                let persistedItems = try await store.items()
                guard let self else { return }
                let liveIDs = Set(self.downloadsByID.keys)
                for item in persistedItems where !liveIDs.contains(item.id) {
                    self.itemsByID[item.id] = item
                }
                self.notifyItemsChanged()
            } catch {
                self?.report(error)
            }
        }
    }

    /// Adopts a WebKit-owned download, preserving the originating web view's cookies and request context.
    /// Private downloads remain visible for this process lifetime but are never written to metadata storage.
    func adopt(_ download: WKDownload, isPrivate: Bool) {
        let objectID = ObjectIdentifier(download)
        guard IDsByDownload[objectID] == nil else { return }

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
        lastPersistedBytes[item.id] = 0
        download.delegate = self
        persist(item)
        notifyItemsChanged()
    }

    func cancel(id: UUID) {
        guard let download = downloadsByID[id] else { return }
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
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
            )
            let destinationURL = try DownloadFilePath.uniqueDestination(
                in: directoryURL,
                suggestedFilename: suggestedFilename,
                fileManager: fileManager
            )

            let now = Date()
            item.sourceURL = response.url ?? item.sourceURL
            item.fileName = destinationURL.lastPathComponent
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

        if status == .completed, let fileURL = item.localFileURL {
            if let attributes = try? fileManager.attributesOfItem(atPath: fileURL.path),
               let size = attributes[.size] as? NSNumber {
                item.bytesReceived = max(item.bytesReceived, size.int64Value)
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
        for (id, download) in downloadsByID {
            changed = updateProgress(for: id, from: download, forcePersistence: false) || changed
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
        onError?(error.localizedDescription)
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

    private func boundedErrorDescription(_ description: String) -> String {
        var result = ""
        for character in description {
            let proposed = result + String(character)
            guard proposed.utf8.count <= 512 else { break }
            result = proposed
        }
        return result
    }
}
