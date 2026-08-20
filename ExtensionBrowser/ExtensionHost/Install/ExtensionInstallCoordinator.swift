import Foundation
import WebKit

/// A package that has been unpacked and inspected, waiting on the user's answer.
///
/// Holding one of these means owning a staging directory: it must end in either
/// ``ExtensionInstallCoordinator/install(_:)`` or ``ExtensionInstallCoordinator/cancel(_:)``.
struct PreparedExtensionInstall {
    let staged: StagedExtensionPackage
    let summary: ExtensionPermissionSummary

    /// Spec §7: no verifiable signature means a warning banner and a second confirmation.
    var requiresExplicitTrust: Bool { staged.signature.requiresExplicitTrust }

    var publisherIdentifier: String? {
        if case .verified(let identifier) = staged.signature { return identifier }
        return nil
    }
}

/// The install flow, end to end: pick a file, see what it wants, agree, load it.
///
/// The catalog is the authority, not the loaded contexts — everything enabled is rebuilt from it at
/// launch by ``restore()``. Unpacking is pushed off the main actor because an archive can be tens of
/// megabytes; the WebKit calls stay here, because `WKWebExtension` is main-actor bound. Directory
/// deletes stay here too, matching `DownloadCoordinator`: `FileManager` is not `Sendable`, and a
/// recursive delete of one extension is not worth a hop.
@MainActor
final class ExtensionInstallCoordinator {
    private let store: InstalledExtensionStore
    private let installer: ExtensionPackageInstaller
    private let fileManager: FileManager
    private let explicitInstallRootURL: URL?
    private weak var host: WebExtensionHost?

    private(set) var records: [InstalledExtensionRecord] = []
    var onRecordsChanged: (([InstalledExtensionRecord]) -> Void)?

    init(
        host: WebExtensionHost?,
        store: InstalledExtensionStore = InstalledExtensionStore(),
        installer: ExtensionPackageInstaller = ExtensionPackageInstaller(),
        installRootURL: URL? = nil,
        fileManager: FileManager = .default
    ) {
        self.host = host
        self.store = store
        self.installer = installer
        explicitInstallRootURL = installRootURL
        self.fileManager = fileManager
    }

    // MARK: - Reading

    func reload() async {
        records = (try? await store.load()) ?? []
        onRecordsChanged?(records)
    }

    /// Loads every enabled extension. Call once, at launch.
    func restore() async {
        await reload()
        for record in records where record.isEnabled {
            await load(record)
        }
    }

    // MARK: - Installing

    /// Unpacks the file and asks the runtime what it wants. Installs nothing.
    ///
    /// On any failure the staging directory is removed here, so a caller that gets an error owns
    /// nothing and has nothing to clean up.
    func prepare(fileURL: URL) async throws -> PreparedExtensionInstall {
        let installer = self.installer
        let staged = try await Task.detached(priority: .userInitiated) {
            try installer.stage(packageAt: fileURL)
        }.value

        do {
            let webExtension = try await WKWebExtension(resourceBaseURL: staged.resourceBaseURL)
            return PreparedExtensionInstall(
                staged: staged,
                summary: ExtensionPermissionSummaryReader.summary(
                    for: webExtension,
                    fallbackName: staged.identity.identifier.rawValue
                )
            )
        } catch {
            installer.discard(staged)
            throw error
        }
    }

    func cancel(_ prepared: PreparedExtensionInstall) {
        installer.discard(prepared.staged)
    }

    /// Commits the package and records exactly what the sheet showed.
    ///
    /// The grant is the manifest's request frozen at this moment. A later version asking for more
    /// does not inherit anything: the new permission is simply absent from the record, and
    /// `WebExtensionHost.apply(policy:)` denies whatever the record does not name.
    func install(_ prepared: PreparedExtensionInstall) async throws {
        let root = try installRoot()
        let installer = self.installer
        let staged = prepared.staged
        let installedURL = try await Task.detached(priority: .userInitiated) {
            try installer.commit(staged, into: root)
        }.value

        let record = InstalledExtensionRecord.make(
            staged: staged,
            displayName: prepared.summary.displayName,
            grantedPermissions: Set(prepared.summary.permissions),
            grantedMatchPatterns: Set(prepared.summary.matchPatterns),
            installedAt: Date()
        )

        do {
            records = try await store.upsert(record)
        } catch {
            // The catalog is the authority. Files it does not know about are orphans, so they go
            // rather than sitting in Application Support forever.
            try? fileManager.removeItem(at: installedURL)
            throw error
        }

        onRecordsChanged?(records)
        await load(record)
    }

    // MARK: - Managing

    func setEnabled(_ isEnabled: Bool, for identifier: String) async throws {
        records = try await store.setEnabled(isEnabled, for: identifier)
        onRecordsChanged?(records)

        guard let record = records.first(where: { $0.identifier == identifier }) else { return }
        if isEnabled {
            await load(record)
        } else {
            unload(identifier: identifier)
        }
    }

    func remove(identifier: String) async throws {
        unload(identifier: identifier)
        records = try await store.remove(identifier: identifier)
        onRecordsChanged?(records)

        guard let directory = resourceURL(for: identifier) else { return }
        try? fileManager.removeItem(at: directory)
    }

    // MARK: - Internals

    @discardableResult
    private func load(_ record: InstalledExtensionRecord) async -> Bool {
        guard record.isEnabled,
              let host,
              let resourceBaseURL = resourceURL(for: record.identifier) else { return false }
        guard host.loadedContext(uniqueIdentifier: record.identifier) == nil else { return true }

        do {
            _ = try await host.loadExtension(
                resourceBaseURL: resourceBaseURL,
                policy: record.permissionPolicy,
                uniqueIdentifier: record.identifier
            )
            return true
        } catch {
            // Deliberately not interpolated: an error from the runtime can carry a filesystem path,
            // and §7 keeps user-derived strings out of the log.
            AppLog.extensions.error("An installed extension failed to load and stays disabled")
            return false
        }
    }

    private func unload(identifier: String) {
        guard let host, let context = host.loadedContext(uniqueIdentifier: identifier) else { return }
        host.unload(context)
    }

    /// - Returns: nil when the identifier is not one this app could have written. The catalog is a
    ///   file on disk, and a path component out of a file is not something to hand to `rm`.
    private func resourceURL(for identifier: String) -> URL? {
        guard let identifier = ExtensionIdentifier(rawValue: identifier),
              let root = try? installRoot() else { return nil }
        return root.appendingPathComponent(identifier.rawValue, isDirectory: true)
    }

    private func installRoot() throws -> URL {
        if let explicitInstallRootURL {
            try fileManager.createDirectory(at: explicitInstallRootURL, withIntermediateDirectories: true)
            return explicitInstallRootURL
        }
        return try ExtensionStorageLocation.installRoot(fileManager: fileManager, create: true)
    }
}
