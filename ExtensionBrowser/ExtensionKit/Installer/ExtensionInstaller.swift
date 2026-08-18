import Foundation

public actor ExtensionInstaller {
    public let repository: ExtensionRepository
    public let extractor: SafeZIPExtractor
    private let fileManager: FileManager
    private let parser: ManifestParser

    public init(
        repository: ExtensionRepository,
        extractor: SafeZIPExtractor = SafeZIPExtractor(),
        fileManager: FileManager = .default,
        parser: ManifestParser = ManifestParser()
    ) {
        self.repository = repository
        self.extractor = extractor
        self.fileManager = fileManager
        self.parser = parser
    }

    public func prepareImport(from packageURL: URL) throws -> ExtensionPackagePreview {
        let accessed = packageURL.startAccessingSecurityScopedResource()
        defer { if accessed { packageURL.stopAccessingSecurityScopedResource() } }

        let container = fileManager.temporaryDirectory
            .appendingPathComponent("ExtensionBrowserImports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let extracted = container.appendingPathComponent("extracted", isDirectory: true)
        do {
            try fileManager.createDirectory(
                at: container,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: AppDataProtectionPolicy.Category.temporarySensitive.protection]
            )
            let values = try packageURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey])
            if values.isDirectory == true {
                try extractor.copyDirectory(from: packageURL, to: extracted, fileManager: fileManager)
            } else if values.isRegularFile == true {
                try extractor.extract(archiveURL: packageURL, to: extracted, fileManager: fileManager)
            } else {
                throw ExtensionInstallError.archiveUnreadable
            }
            let manifestURL = try locateManifest(in: extracted)
            let extensionRoot = manifestURL.deletingLastPathComponent()
            let manifest = try parser.parse(fileURL: manifestURL)
            try verifyReferencedResources(manifest: manifest, rootURL: extensionRoot)
            let identity = try ExtensionIdentityGenerator.identity(forDirectory: extensionRoot, fileManager: fileManager)
            try AppDataProtectionPolicy.protectRecursively(
                container,
                category: .temporarySensitive,
                fileManager: fileManager
            )
            return ExtensionPackagePreview(
                id: identity.identifier,
                manifest: manifest,
                packageDigest: identity.digest,
                stagedDirectoryURL: extensionRoot,
                stagingContainerURL: container,
                sourceDescription: "Files: \(packageURL.lastPathComponent)"
            )
        } catch {
            try? fileManager.removeItem(at: container)
            throw error
        }
    }

    public func commit(_ preview: ExtensionPackagePreview) async throws -> InstalledExtension {
        defer { removeStagingContainer(preview.stagingContainerURL) }
        return try await repository.install(preview)
    }

    public func discard(_ preview: ExtensionPackagePreview) {
        removeStagingContainer(preview.stagingContainerURL)
    }

    private func locateManifest(in rootURL: URL) throws -> URL {
        guard let enumerator = fileManager.enumerator(
            at: rootURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: []
        ) else { throw ExtensionManifestError.manifestNotFound }
        var manifests: [URL] = []
        for case let url as URL in enumerator where url.lastPathComponent == "manifest.json" {
            if (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                manifests.append(url)
            }
        }
        guard !manifests.isEmpty else { throw ExtensionManifestError.manifestNotFound }
        guard manifests.count == 1 else { throw ExtensionManifestError.multipleManifests }
        return manifests[0]
    }

    private func verifyReferencedResources(manifest: WebExtensionManifest, rootURL: URL) throws {
        var resources = manifest.contentScripts.flatMap { $0.javascript + $0.css }
        if let popup = manifest.action?.defaultPopup, !popup.isEmpty { resources.append(popup) }
        resources.append(contentsOf: manifest.icons.values)
        if let icon = manifest.action?.defaultIcon {
            switch icon {
            case .path(let path): resources.append(path)
            case .sized(let paths): resources.append(contentsOf: paths.values)
            }
        }
        for path in Set(resources) {
            let url = try ExtensionResourcePath.containedURL(for: path, under: rootURL)
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                throw ExtensionRuntimeError.resourceNotFound(path)
            }
        }
    }

    private func removeStagingContainer(_ candidateURL: URL) {
        let importsRoot = fileManager.temporaryDirectory
            .appendingPathComponent("ExtensionBrowserImports", isDirectory: true)
            .standardizedFileURL
        let candidate = candidateURL.standardizedFileURL
        let prefix = importsRoot.path.hasSuffix("/") ? importsRoot.path : importsRoot.path + "/"
        guard candidate.path.hasPrefix(prefix), candidate.deletingLastPathComponent() == importsRoot else { return }
        try? fileManager.removeItem(at: candidate)
    }
}
