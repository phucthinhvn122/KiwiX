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
    /// Identifiers with an enable/disable in flight.
    ///
    /// `setEnabled` awaits the catalog and then awaits the runtime, and the switch stays live the
    /// whole time. Two quick taps interleaved a load against an unload for the same context and
    /// left the runtime disagreeing with the record on disk about whether the extension was on.
    private var enablementInFlight: Set<String> = []
    /// Why an extension that is installed and switched on is nevertheless doing nothing.
    ///
    /// Keyed by identifier, cleared when the extension loads cleanly, and surfaced by the Extensions
    /// screen. Loading used to be a `Bool` nobody read and a log line nobody sees: an extension whose
    /// context failed to load, or whose background script never started, looked exactly like one that
    /// was working.
    private(set) var runtimeProblems: [String: String] = [:]

    /// How long to wait for background content before calling it dead.
    ///
    /// A working background page answers in milliseconds; only a broken one reaches this. MV3
    /// `background.service_worker` is the case that matters — WebKit accepts the manifest,
    /// `hasBackgroundContent` reports true, and the completion handler is never called at all
    /// (DECISIONS §4.1, COMPATIBILITY.md). Without a deadline that is a hang, not a diagnosis.
    private static let backgroundStartTimeout: TimeInterval = 10
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
        let catalog = try? await store.load()
        records = catalog ?? []
        onRecordsChanged?(records)
        if catalog != nil {
            // Only when the catalog was actually readable. It is the authority on what is installed,
            // so a directory it does not name is an orphan — but a catalog that failed to load names
            // nothing at all, and wiping every extension because one read failed is not a recovery.
            discardOrphanedResourceDirectories()
        }
        for record in records where record.isEnabled {
            await load(record)
        }
    }

    /// Deletes unpacked extensions the catalog has no record of.
    ///
    /// `commit` counts the children of `Extensions/` against the 32-extension cap, so a directory
    /// left behind by a delete that failed halfway does not just waste disk — it consumes a slot the
    /// user cannot see and cannot free from the Extensions screen, because nothing lists it.
    private func discardOrphanedResourceDirectories() {
        guard let root = try? installRoot() else { return }
        let known = Set(records.map(\.identifier))
        guard let listing = try? BoundedDirectoryReader.directChildren(
            of: root,
            maximumEntryCount: SafePersistence.maximumInstalledExtensionCount * 4,
            fileManager: fileManager
        ) else { return }

        for url in listing.entries {
            let name = url.lastPathComponent
            // Shape-checked before it is handed to a recursive delete, for the same reason
            // `resourceURL(for:)` does it: a name read off the filesystem is not an identifier
            // until something says so.
            guard ExtensionIdentifier(rawValue: name) != nil, !known.contains(name) else { continue }
            try? fileManager.removeItem(at: url)
            AppLog.extensions.info("Removed an unpacked extension the catalog does not know about")
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
        let installer = self.installer
        let staged = prepared.staged
        // `commit` owns the staging directory once it is reached — on success it consumes it, on
        // failure it removes it. Nothing owned it before that, so a throw here (no Application
        // Support, no space to create the install root) left the unpacked package behind.
        let root: URL
        do {
            root = try installRoot()
        } catch {
            installer.discard(staged)
            throw error
        }
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
        guard enablementInFlight.insert(identifier).inserted else { return }
        defer { enablementInFlight.remove(identifier) }

        records = try await store.setEnabled(isEnabled, for: identifier)
        onRecordsChanged?(records)

        guard let record = records.first(where: { $0.identifier == identifier }) else { return }
        if isEnabled {
            await load(record)
        } else {
            unload(identifier: identifier)
            runtimeProblems.removeValue(forKey: identifier)
        }
    }

    /// Order matters: the catalog goes first.
    ///
    /// Unloading first meant a catalog write that failed — an unreadable file, no space — left the
    /// extension stopped but still recorded as enabled, and `records` still describing it that way
    /// on screen. The user sees a switch that is on for something that is not running, and the next
    /// launch loads it again. Removing the record first makes the failure a no-op instead: nothing
    /// was unloaded, nothing was deleted, and the error reaches the caller with the state intact.
    func remove(identifier: String) async throws {
        records = try await store.remove(identifier: identifier)
        runtimeProblems.removeValue(forKey: identifier)
        unload(identifier: identifier)
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

        let context: WKWebExtensionContext
        do {
            context = try await host.loadExtension(
                resourceBaseURL: resourceBaseURL,
                policy: record.permissionPolicy,
                uniqueIdentifier: record.identifier
            )
        } catch {
            // Deliberately not interpolated: an error from the runtime can carry a filesystem path,
            // and §7 keeps user-derived strings out of the log.
            AppLog.extensions.error("An installed extension failed to load")
            note(problem: "Failed to load", for: record.identifier)
            return false
        }

        runtimeProblems.removeValue(forKey: record.identifier)
        await startBackgroundContent(for: context, identifier: record.identifier)
        return true
    }

    /// Starts the extension's background script, and records it when that does not happen.
    ///
    /// Nothing used to call this outside the tests. An extension is loaded into the controller and
    /// then left to WebKit to wake lazily — which for an MV3 `background.service_worker` never
    /// happens at all, so the popup, the listeners and every `chrome.*` call the extension makes at
    /// startup simply do not run. The extension is installed, its switch is on, and it is inert.
    /// Forcing the start turns that into an answer instead of a silence.
    private func startBackgroundContent(
        for context: WKWebExtensionContext,
        identifier: String
    ) async {
        guard let host, context.webExtension.hasBackgroundContent else { return }
        do {
            try await host.loadBackgroundContent(for: context, timeout: Self.backgroundStartTimeout)
        } catch {
            AppLog.extensions.error("Background content did not start; the extension is loaded but inert")
            note(problem: "Background script not running", for: identifier)
        }
    }

    private func note(problem: String, for identifier: String) {
        runtimeProblems[identifier] = problem
        onRecordsChanged?(records)
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
