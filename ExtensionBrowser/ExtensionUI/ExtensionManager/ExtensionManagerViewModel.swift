import Foundation
import SwiftUI

@MainActor
final class ExtensionManagerViewModel: ObservableObject {
    @Published private(set) var extensions: [InstalledExtension] = []
    @Published var pendingPreview: ExtensionPackagePreview?
    @Published var isWorking = false
    @Published var errorMessage: String?

    let repository: ExtensionRepository
    let installer: ExtensionInstaller

    init(repository: ExtensionRepository, installer: ExtensionInstaller) {
        self.repository = repository
        self.installer = installer
    }

    func refresh() {
        Task {
            do {
                extensions = try await repository.installedExtensions()
            } catch {
                errorMessage = error.localizedDescription
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
                errorMessage = error.localizedDescription
            }
        }
    }

    func confirmImport() {
        guard let preview = pendingPreview, !isWorking else { return }
        isWorking = true
        Task {
            defer { isWorking = false }
            do {
                _ = try await installer.commit(preview)
                pendingPreview = nil
                extensions = try await repository.installedExtensions()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func cancelImport() {
        guard let preview = pendingPreview else { return }
        Task { await installer.discard(preview) }
        pendingPreview = nil
    }

    func setEnabled(_ enabled: Bool, extensionID: ExtensionIdentifier) {
        Task {
            do {
                _ = try await repository.setEnabled(enabled, extensionID: extensionID)
                extensions = try await repository.installedExtensions()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func remove(extensionID: ExtensionIdentifier) {
        Task {
            do {
                try await repository.remove(extensionID: extensionID)
                extensions = try await repository.installedExtensions()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
