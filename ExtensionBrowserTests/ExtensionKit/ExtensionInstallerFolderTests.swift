import XCTest
@testable import ExtensionBrowser

final class ExtensionInstallerFolderTests: XCTestCase {
    func testPreparesUnpackedExtensionFolder() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let source = root.appendingPathComponent("SampleExtension", isDirectory: true)
        let repositoryURL = root.appendingPathComponent("Installed", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data(#"{"manifest_version":3,"name":"Folder Import","version":"1.0","content_scripts":[{"matches":["https://example.com/*"],"js":["content.js"]}]}"#.utf8)
            .write(to: source.appendingPathComponent("manifest.json"))
        try Data("document.documentElement.dataset.folderImport = 'ok';".utf8)
            .write(to: source.appendingPathComponent("content.js"))

        let repository = ExtensionRepository(baseDirectoryURL: repositoryURL)
        let installer = ExtensionInstaller(repository: repository)
        let preview = try await installer.prepareImport(from: source)

        XCTAssertEqual(preview.manifest.name, "Folder Import")
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: preview.stagedDirectoryURL.appendingPathComponent("content.js").path
        ))
        await installer.discard(preview)
    }

    func testRejectsNativeBinaryInExtensionFolder() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let destination = root.appendingPathComponent("Destination", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data([0x7F, 0x45, 0x4C, 0x46]).write(to: root.appendingPathComponent("payload.bin"))

        XCTAssertThrowsError(try SafeZIPExtractor().copyDirectory(from: root, to: destination)) { error in
            guard case ExtensionInstallError.nativeBinaryNotAllowed = error else {
                return XCTFail("Expected native binary rejection, got \(error)")
            }
        }
    }
}
