import UIKit
import XCTest
@testable import ExtensionBrowser

@MainActor
final class ExtensionActionTests: XCTestCase {
    func testMetadataChoosesNearestIconAndSanitizesRaster() throws {
        let manifest = WebExtensionManifest(
            manifestVersion: 3,
            name: "Action",
            version: "1",
            action: .init(defaultIcon: .sized([
                "16": "small.png",
                "48": "large.png",
                "128": "huge.png"
            ]))
        )
        XCTAssertEqual(ExtensionActionMetadata.iconPath(for: manifest), "large.png")
        XCTAssertNil(ExtensionActionMetadata.sanitizedIconData(Data("not an image".utf8)))

        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 24, height: 24))
        let encoded = renderer.pngData { context in
            context.cgContext.setFillColor(UIColor.systemBlue.cgColor)
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 24, height: 24))
        }
        let sanitized = try XCTUnwrap(ExtensionActionMetadata.sanitizedIconData(encoded))
        let image = try XCTUnwrap(UIImage(data: sanitized))
        XCTAssertLessThanOrEqual(image.size.width, CGFloat(ExtensionActionMetadata.toolbarIconPixels))
        XCTAssertLessThanOrEqual(image.size.height, CGFloat(ExtensionActionMetadata.toolbarIconPixels))

        let oversized = UIGraphicsImageRenderer(size: CGSize(
            width: CGFloat(ExtensionActionMetadata.maximumDecodedIconDimension + 1),
            height: 1
        )).pngData { context in
            context.cgContext.fill(CGRect(
                x: 0,
                y: 0,
                width: CGFloat(ExtensionActionMetadata.maximumDecodedIconDimension + 1),
                height: 1
            ))
        }
        XCTAssertNil(ExtensionActionMetadata.sanitizedIconData(oversized))
    }

    func testListingDoesNotGrantActiveTabAndInvocationIsTabScoped() async throws {
        let fixture = try await makeFixture(hasPopup: false)
        defer { try? FileManager.default.removeItem(at: fixture.containerURL) }

        let actions = try await fixture.coordinator.availableActions(
            for: fixture.tab,
            enabledExtensionIDs: [fixture.extensionID]
        )
        XCTAssertEqual(actions.map(\.title), ["Invoke me"])
        XCTAssertFalse(actions[0].hasPopup)
        await XCTAssertThrowsErrorAsync {
            try await fixture.permissions.authorizeHost(
                fixture.tabURL,
                tabID: fixture.tab.id,
                extensionID: fixture.extensionID
            )
        }

        let result = try await fixture.coordinator.invokeAction(
            extensionID: fixture.extensionID,
            for: fixture.tab
        )
        guard case .noPopup = result else { return XCTFail("Expected a no-popup invocation") }
        try await fixture.permissions.authorizeHost(
            fixture.tabURL,
            tabID: fixture.tab.id,
            extensionID: fixture.extensionID
        )
        await XCTAssertThrowsErrorAsync {
            try await fixture.permissions.authorizeHost(
                fixture.tabURL,
                tabID: UUID(),
                extensionID: fixture.extensionID
            )
        }
    }

    func testPopupResultIsCreatedOnlyByExplicitInvocation() async throws {
        let popupProvider = PopupProviderSpy()
        let fixture = try await makeFixture(hasPopup: true, popupProvider: popupProvider)
        defer { try? FileManager.default.removeItem(at: fixture.containerURL) }

        _ = try await fixture.coordinator.availableActions(
            for: fixture.tab,
            enabledExtensionIDs: [fixture.extensionID]
        )
        XCTAssertEqual(popupProvider.callCount, 0)

        let result = try await fixture.coordinator.invokeAction(
            extensionID: fixture.extensionID,
            for: fixture.tab
        )
        guard case .presentPopup = result else { return XCTFail("Expected a popup invocation") }
        XCTAssertEqual(popupProvider.callCount, 1)
    }

    private func makeFixture(
        hasPopup: Bool,
        popupProvider: ExtensionPopupProviding? = nil
    ) async throws -> ActionFixture {
        let fileManager = FileManager.default
        let container = fileManager.temporaryDirectory
            .appendingPathComponent("ExtensionActionTests-\(UUID().uuidString)", isDirectory: true)
        let base = container.appendingPathComponent("Installed", isDirectory: true)
        let stagingContainer = container.appendingPathComponent("Staging", isDirectory: true)
        let staged = stagingContainer.appendingPathComponent("Payload", isDirectory: true)
        try fileManager.createDirectory(at: staged, withIntermediateDirectories: true)

        let manifest = WebExtensionManifest(
            manifestVersion: 3,
            name: "Action fixture",
            version: "1",
            permissions: ["activeTab"],
            action: .init(
                defaultTitle: "Invoke me",
                defaultPopup: hasPopup ? "popup.html" : nil
            )
        )
        try JSONEncoder().encode(manifest).write(
            to: staged.appendingPathComponent("manifest.json"),
            options: .atomic
        )
        if hasPopup {
            try Data("<!doctype html>".utf8).write(
                to: staged.appendingPathComponent("popup.html"),
                options: .atomic
            )
        }
        let identity = try ExtensionIdentityGenerator.identity(forDirectory: staged)
        let identifier = identity.identifier
        let preview = ExtensionPackagePreview(
            id: identifier,
            manifest: manifest,
            packageDigest: identity.digest,
            stagedDirectoryURL: staged,
            stagingContainerURL: stagingContainer
        )
        let repository = ExtensionRepository(baseDirectoryURL: base)
        _ = try await repository.install(preview)
        let permissions = ExtensionPermissionManager()
        try await permissions.register(
            extensionID: identifier,
            manifest: manifest,
            isEnabled: true,
            grantedCapabilities: [.activeTab]
        )
        let storage = ExtensionLocalStorage(repository: repository)
        let registry = ExtensionAPIRegistry(storage: storage, permissions: permissions)
        registry.replaceActionDefaults(with: try await repository.installedExtensions())
        let tabURL = try XCTUnwrap(URL(string: "https://action.example/page"))
        let tab = BrowserTabDescriptor(
            id: UUID(),
            title: "Page",
            url: tabURL,
            isPrivate: false,
            isActive: true
        )
        let coordinator = ExtensionActionCoordinator(
            repository: repository,
            permissions: permissions,
            registry: registry,
            popupProvider: popupProvider,
            activeTabProvider: { tab }
        )
        return ActionFixture(
            containerURL: container,
            extensionID: identifier,
            permissions: permissions,
            coordinator: coordinator,
            tab: tab,
            tabURL: tabURL
        )
    }
}

@MainActor
private final class PopupProviderSpy: ExtensionPopupProviding {
    private(set) var callCount = 0

    func makePopupViewController(
        for extensionID: ExtensionIdentifier,
        tabID: UUID
    ) async throws -> UIViewController {
        callCount += 1
        return UIViewController()
    }
}

@MainActor
private struct ActionFixture {
    let containerURL: URL
    let extensionID: ExtensionIdentifier
    let permissions: ExtensionPermissionManager
    let coordinator: ExtensionActionCoordinator
    let tab: BrowserTabDescriptor
    let tabURL: URL
}

@MainActor
private func XCTAssertThrowsErrorAsync(
    _ expression: @escaping () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected an error", file: file, line: line)
    } catch {
        // Expected.
    }
}
