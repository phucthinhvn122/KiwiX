import Foundation

/// A package that has been read, verified and unpacked, but not yet installed.
///
/// Staging is separate from committing because §7 requires the user to see what an extension asks
/// for before it lands anywhere permanent, and the permission list only exists once the files are
/// on disk for `WKWebExtension` to read. Whoever stages a package owns the temporary directory
/// until they either `commit` or `discard` it.
public struct StagedExtensionPackage: Sendable {
    public let identity: ExtensionIdentity
    public let signature: ExtensionPackageSignature
    public let format: ExtensionPackage.Format
    /// The directory containing `manifest.json`, ready for `WKWebExtension(resourceBaseURL:)`.
    public let resourceBaseURL: URL
    /// Staging root. `commit` consumes it and `discard` deletes it; it must not outlive the flow.
    let stagingRoot: URL
}

/// Turns a `.crx` or `.zip` on disk into an unpacked extension directory.
///
/// Nothing here reads `manifest.json` beyond checking that the file exists — locating the archive
/// root is a filesystem question, and interpreting the manifest stays WebKit's job under ADR-001.
public struct ExtensionPackageInstaller: Sendable {
    public let limits: ZIPSecurityLimits
    public let maximumInstalledExtensions: Int

    /// Internal rather than `public`: the default limit is read from `SafePersistence`, and a
    /// public default argument may only name public symbols. Every caller is in this module.
    init(
        limits: ZIPSecurityLimits = .default,
        maximumInstalledExtensions: Int = SafePersistence.maximumInstalledExtensionCount
    ) {
        self.limits = limits
        self.maximumInstalledExtensions = maximumInstalledExtensions
    }

    // MARK: - Staging

    /// Reads, verifies and unpacks a package. Blocking: call it off the main actor.
    ///
    /// On any failure the staging directory is removed before the error propagates, so a rejected
    /// package leaves nothing behind.
    public func stage(packageAt url: URL, fileManager: FileManager = .default) throws -> StagedExtensionPackage {
        let data = try readPackage(at: url, fileManager: fileManager)
        let package = try ExtensionPackageReader.read(data)

        let stagingRoot = fileManager.temporaryDirectory
            .appendingPathComponent("ExtensionInstall-\(UUID().uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: stagingRoot, withIntermediateDirectories: true)

        do {
            // SafeZIPExtractor works from a file, and the CRX payload is a slice of the input, so
            // the embedded archive is written out byte-for-byte before it is opened.
            let payloadURL = stagingRoot.appendingPathComponent("payload.zip", isDirectory: false)
            try package.payload.write(to: payloadURL, options: [.atomic])

            let unpackedURL = stagingRoot.appendingPathComponent("unpacked", isDirectory: true)
            try SafeZIPExtractor(limits: limits).extract(
                archiveURL: payloadURL,
                to: unpackedURL,
                fileManager: fileManager
            )
            try? fileManager.removeItem(at: payloadURL)

            let resourceBaseURL = try resourceRoot(in: unpackedURL, fileManager: fileManager)
            let identity = try ExtensionIdentityGenerator.identity(
                forDirectory: resourceBaseURL,
                fileManager: fileManager,
                limits: limits
            )

            let signedLabel = package.signature.isVerified ? "yes" : "no"
            AppLog.extensions.info(
                "Staged extension package format=\(package.format.rawValue, privacy: .public) signed=\(signedLabel, privacy: .public) id=\(identity.identifier.rawValue, privacy: .public)"
            )
            return StagedExtensionPackage(
                identity: identity,
                signature: package.signature,
                format: package.format,
                resourceBaseURL: resourceBaseURL,
                stagingRoot: stagingRoot
            )
        } catch {
            try? fileManager.removeItem(at: stagingRoot)
            throw error
        }
    }

    // MARK: - Committing

    /// Moves a staged package to its permanent home and returns the installed resource directory.
    ///
    /// Protection attributes are applied before the move, not after: if the move succeeded and the
    /// protection call then failed, the extension would be installed and unprotected, which is the
    /// one outcome worth ruling out.
    @discardableResult
    public func commit(
        _ staged: StagedExtensionPackage,
        into installRoot: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let destination = installRoot.appendingPathComponent(
            staged.identity.identifier.rawValue,
            isDirectory: true
        )
        do {
            try fileManager.createDirectory(at: installRoot, withIntermediateDirectories: true)
            guard !fileManager.fileExists(atPath: destination.path) else {
                throw ExtensionInstallError.packageAlreadyInstalled(staged.identity.identifier.rawValue)
            }
            let listing = try BoundedDirectoryReader.directChildren(
                of: installRoot,
                maximumEntryCount: maximumInstalledExtensions + 1,
                fileManager: fileManager
            )
            guard listing.entries.count < maximumInstalledExtensions, !listing.wasTruncated else {
                throw ExtensionInstallError.tooManyInstalledExtensions(limit: maximumInstalledExtensions)
            }

            try AppDataProtectionPolicy.protectRecursively(
                staged.resourceBaseURL,
                category: .browserState,
                fileManager: fileManager
            )
            try fileManager.moveItem(at: staged.resourceBaseURL, to: destination)
        } catch {
            try? fileManager.removeItem(at: staged.stagingRoot)
            throw error
        }

        try? fileManager.removeItem(at: staged.stagingRoot)
        AppLog.extensions.info(
            "Installed extension id=\(staged.identity.identifier.rawValue, privacy: .public)"
        )
        return destination
    }

    public func discard(_ staged: StagedExtensionPackage, fileManager: FileManager = .default) {
        try? fileManager.removeItem(at: staged.stagingRoot)
    }

    // MARK: - Internals

    private func readPackage(at url: URL, fileManager: FileManager) throws -> Data {
        do {
            return try BoundedFileReader.read(
                from: url,
                maximumByteCount: Int(clamping: limits.maximumArchiveBytes),
                fileManager: fileManager
            )
        } catch BoundedFileReadError.tooLarge {
            throw ExtensionInstallError.archiveTooLarge(limit: limits.maximumArchiveBytes)
        } catch {
            throw ExtensionInstallError.archiveUnreadable
        }
    }

    /// Finds the directory holding `manifest.json`.
    ///
    /// Packagers routinely zip the containing folder rather than its contents, so a single wrapper
    /// directory is unwrapped. Two candidates is ambiguous and rejected rather than guessed at.
    private func resourceRoot(in unpacked: URL, fileManager: FileManager) throws -> URL {
        if fileManager.fileExists(atPath: unpacked.appendingPathComponent("manifest.json").path) {
            return unpacked
        }

        let listing = try BoundedDirectoryReader.directChildren(
            of: unpacked,
            includingPropertiesForKeys: [.isDirectoryKey],
            maximumEntryCount: limits.maximumEntryCount,
            fileManager: fileManager
        )
        guard !listing.wasTruncated else {
            throw ExtensionInstallError.tooManyEntries(limit: limits.maximumEntryCount)
        }

        // "__MACOSX" and dot-directories are archiver debris, never the extension.
        let directories = listing.entries.filter { candidate in
            let name = candidate.lastPathComponent
            guard !name.hasPrefix("."), name != "__MACOSX" else { return false }
            let values = try? candidate.resourceValues(forKeys: [.isDirectoryKey])
            return values?.isDirectory == true
        }
        guard directories.count == 1 else { throw ExtensionInstallError.manifestNotFound }

        let candidate = directories[0]
        guard fileManager.fileExists(atPath: candidate.appendingPathComponent("manifest.json").path) else {
            throw ExtensionInstallError.manifestNotFound
        }
        return candidate
    }
}
