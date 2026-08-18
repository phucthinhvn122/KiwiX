import Foundation
import ImageIO
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
        guard data.count <= SafePersistence.maximumSnapshotBytes else {
            throw CocoaError(.fileWriteOutOfSpace)
        }
        let directory = try snapshotDirectory(create: true)
        guard let url = SafePersistence.containedSnapshotURL(fileName: fileName, directory: directory) else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        try data.write(to: url, options: [.atomic])
        try AppDataProtectionPolicy.apply(to: url, category: .browserState, fileManager: fileManager)
    }

    func load(fileName: String) throws -> Data? {
        let directory = try snapshotDirectory(create: false)
        guard let url = SafePersistence.containedSnapshotURL(fileName: fileName, directory: directory) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try? BoundedFileReader.read(
            from: url,
            maximumByteCount: SafePersistence.maximumSnapshotBytes,
            fileManager: fileManager
        )
    }

    func remove(fileName: String) throws {
        let directory = try snapshotDirectory(create: false)
        guard let url = SafePersistence.containedSnapshotURL(fileName: fileName, directory: directory) else {
            throw CocoaError(.fileReadInvalidFileName)
        }
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

private enum TabSnapshotImageDecoder {
    static let maximumDimension = 4_096
    static let maximumPixelCount = 8_388_608
    static let renderedMaximumDimension = 1_024

    static func image(from data: Data) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0,
              width <= maximumDimension, height <= maximumDimension,
              width <= maximumPixelCount / height else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: renderedMaximumDimension,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return UIImage(cgImage: image)
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
                    AppLog.tabs.error("Tab snapshot failed: \(error.localizedDescription, privacy: .private)")
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
            AppLog.tabs.error("Could not persist tab snapshot: \(error.localizedDescription, privacy: .private)")
        }
        return image
    }

    func loadSnapshot(for tab: Tab) async {
        guard !tab.isPrivate, let fileName = tab.snapshotFileName else { return }
        do {
            guard let data = try await store.load(fileName: fileName) else { return }
            tab.snapshot = TabSnapshotImageDecoder.image(from: data)
        } catch {
            AppLog.tabs.error("Could not load tab snapshot: \(error.localizedDescription, privacy: .private)")
        }
    }

    func deleteSnapshot(for tab: Tab) async {
        tab.snapshot = nil
        guard !tab.isPrivate, let fileName = tab.snapshotFileName else { return }
        tab.snapshotFileName = nil
        do {
            try await store.remove(fileName: fileName)
        } catch {
            AppLog.tabs.error("Could not delete tab snapshot: \(error.localizedDescription, privacy: .private)")
        }
    }
}
