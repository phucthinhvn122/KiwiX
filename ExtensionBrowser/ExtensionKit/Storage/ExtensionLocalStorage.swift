import Foundation

public actor ExtensionLocalStorage {
    public let maximumBytesPerExtension: Int
    private let repository: ExtensionRepository
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(repository: ExtensionRepository, maximumBytesPerExtension: Int = 5 * 1_024 * 1_024) {
        self.repository = repository
        self.maximumBytesPerExtension = maximumBytesPerExtension
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        self.encoder = encoder
        self.decoder = JSONDecoder()
    }

    public func get(extensionID: ExtensionIdentifier, keys: [String]? = nil) async throws -> [String: JSONValue] {
        let values = try await read(extensionID: extensionID)
        guard let keys else { return values }
        return Dictionary(uniqueKeysWithValues: keys.compactMap { key in values[key].map { (key, $0) } })
    }

    public func set(extensionID: ExtensionIdentifier, values: [String: JSONValue]) async throws {
        var current = try await read(extensionID: extensionID)
        current.merge(values) { _, new in new }
        try await write(current, extensionID: extensionID)
    }

    public func remove(extensionID: ExtensionIdentifier, keys: [String]) async throws {
        var current = try await read(extensionID: extensionID)
        keys.forEach { current.removeValue(forKey: $0) }
        try await write(current, extensionID: extensionID)
    }

    public func clear(extensionID: ExtensionIdentifier) async throws {
        try await write([:], extensionID: extensionID)
    }

    private func read(extensionID: ExtensionIdentifier) async throws -> [String: JSONValue] {
        guard let installed = try await repository.extensionWithID(extensionID) else {
            throw ExtensionRuntimeError.extensionNotFound(extensionID.rawValue)
        }
        let fileURL = installed.storageURL.appendingPathComponent("local.json")
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [:] }
        do {
            return try decoder.decode([String: JSONValue].self, from: Data(contentsOf: fileURL))
        } catch {
            throw ExtensionRuntimeError.unavailable("extension storage is corrupt")
        }
    }

    private func write(_ values: [String: JSONValue], extensionID: ExtensionIdentifier) async throws {
        guard let installed = try await repository.extensionWithID(extensionID) else {
            throw ExtensionRuntimeError.extensionNotFound(extensionID.rawValue)
        }
        let data = try encoder.encode(values)
        guard data.count <= maximumBytesPerExtension else {
            throw ExtensionRuntimeError.unavailable("chrome.storage.local quota exceeded")
        }
        try FileManager.default.createDirectory(at: installed.storageURL, withIntermediateDirectories: true, attributes: nil)
        try data.write(to: installed.storageURL.appendingPathComponent("local.json"), options: [.atomic])
    }
}
