import Foundation
import UIKit
import WebKit

actor TabSnapshotStore {
    private let explicitDirectoryURL: URL?
    private let fileManager: FileManager

    init(directoryURL: URL? = nil, fileManager: FileManager = .default) {
        explicitDirectoryURL = directoryURL
        self.fileManager = fileManager
    }

    func save(_ data: Data, fileName: String) throws {
        let directory = try snapshotDirectory(create: true)
        try data.write(to: directory.appendingPathComponent(fileName), options: [.atomic])
    }

    func load(fileName: String) throws -> Data? {
        let url = try snapshotDirectory(create: false).appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func remove(fileName: String) throws {
        let url = try snapshotDirectory(create: false).appendingPathComponent(fileName)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    private func snapshotDirectory(create: Bool) throws -> URL {
        if let explicitDirectoryURL {
            if create {
                try fileManager.createDirectory(
                    at: explicitDirectoryURL,
                    withIntermediateDirectories: true
                )
            }
            return explicitDirectoryURL
        }

        let caches = try fileManager.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: create
        )
        let directory = caches
            .appendingPathComponent("ExtensionBrowser", isDirectory: true)
            .appendingPathComponent("TabSnapshots", isDirectory: true)
        if create {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        return directory
    }
}

@MainActor
final class TabSnapshotManager {
    private let store: TabSnapshotStore

    init(store: TabSnapshotStore? = nil) {
        self.store = store ?? TabSnapshotStore()
    }

    @discardableResult
    func capture(tab: Tab) async -> UIImage? {
        guard let webView = tab.webView,
              webView.bounds.width > 0,
              webView.bounds.height > 0 else {
            return tab.snapshot
        }

        let configuration = WKSnapshotConfiguration()
        configuration.rect = webView.bounds
        configuration.snapshotWidth = NSNumber(value: min(webView.bounds.width, 430))

        let image: UIImage? = await withCheckedContinuation { continuation in
            webView.takeSnapshot(with: configuration) { image, error in
                if let error {
                    AppLog.tabs.error("Tab snapshot failed: \(error.localizedDescription, privacy: .public)")
                }
                continuation.resume(returning: image)
            }
        }

        guard let image else { return tab.snapshot }
        tab.snapshot = image

        guard !tab.isPrivate, let data = image.jpegData(compressionQuality: 0.72) else {
            return image
        }

        let fileName = "\(tab.id.uuidString.lowercased()).jpg"
        do {
            try await store.save(data, fileName: fileName)
            tab.snapshotFileName = fileName
        } catch {
            AppLog.tabs.error("Could not persist tab snapshot: \(error.localizedDescription, privacy: .public)")
        }
        return image
    }

    func loadSnapshot(for tab: Tab) async {
        guard !tab.isPrivate, let fileName = tab.snapshotFileName else { return }
        do {
            guard let data = try await store.load(fileName: fileName) else { return }
            tab.snapshot = UIImage(data: data)
        } catch {
            AppLog.tabs.error("Could not load tab snapshot: \(error.localizedDescription, privacy: .public)")
        }
    }

    func deleteSnapshot(for tab: Tab) async {
        tab.snapshot = nil
        guard !tab.isPrivate, let fileName = tab.snapshotFileName else { return }
        tab.snapshotFileName = nil
        do {
            try await store.remove(fileName: fileName)
        } catch {
            AppLog.tabs.error("Could not delete tab snapshot: \(error.localizedDescription, privacy: .public)")
        }
    }
}
