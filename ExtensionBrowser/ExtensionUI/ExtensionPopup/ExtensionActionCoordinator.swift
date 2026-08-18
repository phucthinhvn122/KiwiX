import Foundation
import ImageIO
import UIKit

enum ExtensionActionMetadata {
    static let preferredIconPixels = 32
    static let maximumDecodedIconDimension = 1_024
    static let maximumDecodedIconPixels = 1_048_576
    static let toolbarIconPixels = 64
    private static let supportedRasterTypes: Set<String> = ["public.png", "public.jpeg"]

    static func displayTitle(
        installed: InstalledExtension,
        runtimeTitle: String
    ) -> String {
        runtimeTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? installed.metadata.name
            : runtimeTitle
    }

    static func iconPath(for manifest: WebExtensionManifest) -> String? {
        if let reference = manifest.action?.defaultIcon {
            switch reference {
            case .path(let path): return path
            case .sized(let paths): return bestSizedPath(in: paths)
            }
        }
        return bestSizedPath(in: manifest.icons)
    }

    static func hasPopup(_ manifest: WebExtensionManifest) -> Bool {
        guard let path = manifest.action?.defaultPopup else { return false }
        return !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Validates attacker-controlled image metadata before decoding, then returns
    /// a small single-frame PNG. Browser chrome never receives original compressed
    /// bytes, eliminating oversized raster and animated-image decode surprises.
    static func sanitizedIconData(_ data: Data) -> Data? {
        let options: [CFString: Any] = [kCGImageSourceShouldCache: false]
        guard let source = CGImageSourceCreateWithData(data as CFData, options as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let imageType = CGImageSourceGetType(source),
              supportedRasterTypes.contains(imageType as String),
              let properties = CGImageSourceCopyPropertiesAtIndex(
                source,
                0,
                options as CFDictionary
              ) as? [CFString: Any],
              let width = integerProperty(properties[kCGImagePropertyPixelWidth]),
              let height = integerProperty(properties[kCGImagePropertyPixelHeight]),
              width > 0, height > 0,
              width <= maximumDecodedIconDimension,
              height <= maximumDecodedIconDimension,
              width.multipliedReportingOverflow(by: height).overflow == false,
              width * height <= maximumDecodedIconPixels else {
            return nil
        }
        let thumbnailOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: toolbarIconPixels,
            kCGImageSourceShouldCacheImmediately: true
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(
            source,
            0,
            thumbnailOptions as CFDictionary
        ) else {
            return nil
        }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output as CFMutableData,
            "public.png" as CFString,
            1,
            nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private static func bestSizedPath(in paths: [String: String]) -> String? {
        paths.compactMap { key, path -> (distance: Int, size: Int, path: String)? in
            guard let size = Int(key), size > 0 else { return nil }
            return (abs(size - preferredIconPixels), size, path)
        }.sorted {
            if $0.distance != $1.distance { return $0.distance < $1.distance }
            if $0.size != $1.size { return $0.size > $1.size }
            return $0.path < $1.path
        }.first?.path ?? paths.sorted(by: { $0.key < $1.key }).first?.value
    }

    private static func integerProperty(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        return value as? Int
    }
}

/// Owns the explicit user-action boundary between browser chrome and an extension.
/// Merely asking for descriptors never mutates permission state.
@MainActor
final class ExtensionActionCoordinator {
    typealias ActiveTabProvider = @MainActor () -> BrowserTabDescriptor?

    private static let maximumIconBytes = 2 * 1_024 * 1_024

    private let repository: ExtensionRepository
    private let permissions: ExtensionPermissionManager
    private let registry: ExtensionAPIRegistry
    private let popupProvider: ExtensionPopupProviding
    private let activeTabProvider: ActiveTabProvider

    init(
        repository: ExtensionRepository,
        permissions: ExtensionPermissionManager,
        registry: ExtensionAPIRegistry,
        popupProvider: ExtensionPopupProviding? = nil,
        activeTabProvider: @escaping ActiveTabProvider = {
            BrowserExtensionBridge.shared.browserHost?.extensionActiveTab
        }
    ) {
        self.repository = repository
        self.permissions = permissions
        self.registry = registry
        self.popupProvider = popupProvider ?? DefaultExtensionPopupProvider(
            repository: repository,
            registry: registry
        )
        self.activeTabProvider = activeTabProvider
    }

    func availableActions(
        for tab: BrowserTabDescriptor,
        enabledExtensionIDs: Set<ExtensionIdentifier>
    ) async throws -> [BrowserExtensionActionDescriptor] {
        guard isCurrentNormalTab(tab) else { return [] }
        let installed = try await repository.verifiedExtensionsSnapshot()
        guard isCurrentNormalTab(tab) else { return [] }

        var result: [BrowserExtensionActionDescriptor] = []
        for item in installed where item.metadata.isEnabled
            && item.manifest.action != nil
            && enabledExtensionIDs.contains(item.id) {
            let runtimeTitle = registry.actionTitle(
                extensionID: item.id,
                tabID: tab.id,
                fallback: item.manifest.action?.defaultTitle ?? item.metadata.name
            )
            let iconData: Data?
            if let iconPath = ExtensionActionMetadata.iconPath(for: item.manifest) {
                let encodedData = try? await repository.resourceData(
                    extensionID: item.id,
                    path: iconPath,
                    maximumBytes: Self.maximumIconBytes
                )
                if let encodedData {
                    iconData = await Task.detached(priority: .utility) {
                        ExtensionActionMetadata.sanitizedIconData(encodedData)
                    }.value
                } else {
                    iconData = nil
                }
            } else {
                iconData = nil
            }
            guard isCurrentNormalTab(tab) else { return [] }
            result.append(BrowserExtensionActionDescriptor(
                extensionID: item.id.rawValue,
                title: ExtensionActionMetadata.displayTitle(installed: item, runtimeTitle: runtimeTitle),
                iconData: iconData,
                hasPopup: ExtensionActionMetadata.hasPopup(item.manifest)
            ))
        }
        return result.sorted {
            let order = $0.title.localizedCaseInsensitiveCompare($1.title)
            return order == .orderedSame ? $0.extensionID < $1.extensionID : order == .orderedAscending
        }
    }

    func invokeAction(
        extensionID: ExtensionIdentifier,
        for tab: BrowserTabDescriptor
    ) async throws -> BrowserExtensionActionInvocation {
        guard isCurrentNormalTab(tab) else {
            throw ExtensionRuntimeError.unavailable("extension actions require the current normal tab")
        }
        guard let installed = try await repository.extensionWithID(extensionID) else {
            throw ExtensionRuntimeError.extensionNotFound(extensionID.rawValue)
        }
        guard installed.metadata.isEnabled, installed.manifest.action != nil else {
            throw ExtensionRuntimeError.extensionDisabled(extensionID.rawValue)
        }
        guard isCurrentNormalTab(tab) else {
            throw ExtensionRuntimeError.unavailable("active tab changed before action invocation")
        }

        let snapshot = await permissions.snapshot(extensionID: extensionID)
        if snapshot?.capabilities.contains(.activeTab) == true,
           let url = tab.url,
           Self.isGrantablePageURL(url) {
            try await permissions.grantActiveTab(url, tabID: tab.id, extensionID: extensionID)
        }

        do {
            let result: BrowserExtensionActionInvocation
            if ExtensionActionMetadata.hasPopup(installed.manifest) {
                let popup = try await popupProvider.makePopupViewController(
                    for: extensionID,
                    tabID: tab.id
                )
                result = .presentPopup(popup)
            } else {
                result = .noPopup
            }
            guard isCurrentNormalTab(tab) else {
                await permissions.revokeActiveTabGrant(tabID: tab.id, extensionID: extensionID)
                throw ExtensionRuntimeError.unavailable("active tab changed while preparing the action")
            }
            return result
        } catch {
            await permissions.revokeActiveTabGrant(tabID: tab.id, extensionID: extensionID)
            throw error
        }
    }

    private func isCurrentNormalTab(_ requested: BrowserTabDescriptor) -> Bool {
        guard requested.isActive, !requested.isPrivate,
              let current = activeTabProvider(), current.isActive, !current.isPrivate else {
            return false
        }
        return current.id == requested.id && current.url == requested.url
    }

    private static func isGrantablePageURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        return (scheme == "http" || scheme == "https") && url.host != nil
    }
}
