import Foundation
import SwiftUI

@MainActor
final class ExtensionManagerViewModel: ObservableObject {
    @Published private(set) var extensions: [InstalledExtension] = []
    @Published var pendingPreview: ExtensionPackagePreview?
    @Published var isWorking = false
    @Published var errorMessage: String?
    private var mutationTail: Task<Void, Never>?
    private var refreshGeneration = 0

    let repository: ExtensionRepository
    let installer: ExtensionInstaller

    init(repository: ExtensionRepository, installer: ExtensionInstaller) {
        self.repository = repository
        self.installer = installer
    }

    func refresh() {
        refreshGeneration += 1
        let generation = refreshGeneration
        Task {
            do {
                let loaded = try await repository.installedExtensions()
                guard generation == refreshGeneration else { return }
                extensions = loaded
            } catch {
                guard generation == refreshGeneration else { return }
                errorMessage = SafeInput.userFacingError(error)
            }
        }
    }

    func prepareImport(from url: URL) {
        guard !isWorking else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                pendingPreview = try await installer.prepareImport(from: url)
            } catch {
                errorMessage = SafeInput.userFacingError(error)
            }
        }
    }

    func confirmImport() {
        guard let preview = pendingPreview, !isWorking else { return }
        refreshGeneration += 1
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                _ = try await installer.commit(preview)
                pendingPreview = nil
                extensions = try await repository.installedExtensions()
            } catch {
                errorMessage = SafeInput.userFacingError(error)
            }
        }
    }

    func cancelImport() {
        guard let preview = pendingPreview else { return }
        Task { await installer.discard(preview) }
        pendingPreview = nil
    }

    func setEnabled(_ enabled: Bool, extensionID: ExtensionIdentifier) {
        enqueueMutation { repository in
            _ = try await repository.setEnabled(enabled, extensionID: extensionID)
        }
    }

    func remove(extensionID: ExtensionIdentifier) {
        enqueueMutation { repository in
            try await repository.remove(extensionID: extensionID)
        }
    }

    func setCapability(_ capability: ExtensionCapability, granted: Bool, extensionID: ExtensionIdentifier) {
        enqueueMutation { repository in
            _ = try await repository.setCapability(capability, granted: granted, extensionID: extensionID)
        }
    }

    func setHostPermission(_ pattern: String, granted: Bool, extensionID: ExtensionIdentifier) {
        enqueueMutation { repository in
            _ = try await repository.setHostPermission(pattern, granted: granted, extensionID: extensionID)
        }
    }

    func setWebsitePermission(_ hostname: String, granted: Bool, extensionID: ExtensionIdentifier) {
        enqueueMutation { repository in
            _ = try await repository.setWebsitePermission(
                hostname: hostname,
                granted: granted,
                extensionID: extensionID
            )
        }
    }

    func replaceHostPermissions(grantAllDeclared: Bool, extensionID: ExtensionIdentifier) {
        enqueueMutation { repository in
            _ = try await repository.replaceHostPermissions(
                withDeclaredPermissions: grantAllDeclared,
                extensionID: extensionID
            )
        }
    }

    func replaceHostPermissions(withWebsiteHostname hostname: String, extensionID: ExtensionIdentifier) {
        enqueueMutation { repository in
            _ = try await repository.replaceHostPermissions(
                withWebsiteHostname: hostname,
                extensionID: extensionID
            )
        }
    }

    var currentWebsiteHostname: String? {
        guard let tab = BrowserExtensionBridge.shared.browserHost?.extensionActiveTab,
              tab.isActive, !tab.isPrivate,
              let url = tab.url,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let hostname = url.host?.lowercased(), !hostname.isEmpty else {
            return nil
        }
        return hostname
    }

    private func enqueueMutation(
        _ operation: @escaping @Sendable (ExtensionRepository) async throws -> Void
    ) {
        refreshGeneration += 1
        let previous = mutationTail
        mutationTail = Task { [weak self, repository] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            do {
                try await operation(repository)
                self.extensions = try await repository.installedExtensions()
            } catch {
                self.errorMessage = SafeInput.userFacingError(error)
            }
        }
    }
}
