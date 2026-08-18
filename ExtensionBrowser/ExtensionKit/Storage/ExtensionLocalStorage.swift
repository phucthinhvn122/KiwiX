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
        if let keys { try validateKeys(keys) }
        let values = try await read(extensionID: extensionID)
        guard let keys else { return values }
        return Dictionary(uniqueKeysWithValues: keys.compactMap { key in values[key].map { (key, $0) } })
    }

    public func set(extensionID: ExtensionIdentifier, values: [String: JSONValue]) async throws {
        try validateOperation(values)
        var current = try await read(extensionID: extensionID)
        current.merge(values) { _, new in new }
        try await write(current, extensionID: extensionID)
    }

    public func remove(extensionID: ExtensionIdentifier, keys: [String]) async throws {
        try validateKeys(keys)
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
        let data: Data
        do {
            data = try BoundedFileReader.read(
                from: fileURL,
                maximumByteCount: maximumBytesPerExtension
            )
        } catch BoundedFileReadError.tooLarge {
            try quarantineCorruptStorage(at: fileURL)
            return [:]
        } catch {
            throw ExtensionRuntimeError.unavailable("extension storage could not be read")
        }

        do {
            try validateJSONStructure(data)
            let decoded = try decoder.decode([String: JSONValue].self, from: data)
            _ = try ExtensionPayloadValidator.validate(decoded.jsonValue, maximumBytes: maximumBytesPerExtension)
            return decoded
        } catch {
            try quarantineCorruptStorage(at: fileURL)
            return [:]
        }
    }

    private func quarantineCorruptStorage(at fileURL: URL) throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        let quarantineURL = fileURL.deletingLastPathComponent().appendingPathComponent(
            "local.corrupt-\(UUID().uuidString).json",
            isDirectory: false
        )
        do {
            try FileManager.default.moveItem(at: fileURL, to: quarantineURL)
            try AppDataProtectionPolicy.apply(to: quarantineURL, category: .browserState)
        } catch {
            throw ExtensionRuntimeError.unavailable("corrupt extension storage could not be quarantined")
        }
    }

    private func write(_ values: [String: JSONValue], extensionID: ExtensionIdentifier) async throws {
        guard let installed = try await repository.extensionWithID(extensionID) else {
            throw ExtensionRuntimeError.extensionNotFound(extensionID.rawValue)
        }
        _ = try ExtensionPayloadValidator.validate(values.jsonValue, maximumBytes: maximumBytesPerExtension)
        let data = try encoder.encode(values)
        guard data.count <= maximumBytesPerExtension else {
            throw ExtensionRuntimeError.unavailable("chrome.storage.local quota exceeded")
        }
        try FileManager.default.createDirectory(at: installed.storageURL, withIntermediateDirectories: true, attributes: nil)
        try data.write(to: installed.storageURL.appendingPathComponent("local.json"), options: [.atomic])
        try AppDataProtectionPolicy.apply(
            to: installed.storageURL.appendingPathComponent("local.json"),
            category: .browserState
        )
    }

    private func validateOperation(_ values: [String: JSONValue]) throws {
        guard values.count <= ExtensionResourceLimits.standard.maximumStorageKeyCount else {
            throw ExtensionRuntimeError.resourceLimitExceeded("too many storage keys")
        }
        try validateKeys(Array(values.keys))
        _ = try ExtensionPayloadValidator.validate(
            values.jsonValue,
            maximumBytes: ExtensionResourceLimits.standard.maximumStorageOperationBytes
        )
        for value in values.values {
            _ = try ExtensionPayloadValidator.validate(
                value,
                maximumBytes: ExtensionResourceLimits.standard.maximumStorageValueBytes
            )
        }
    }

    private func validateKeys(_ keys: [String]) throws {
        let limits = ExtensionResourceLimits.standard
        guard keys.count <= limits.maximumStorageKeyCount,
              keys.allSatisfy({ !$0.isEmpty && $0.utf8.count <= limits.maximumStorageKeyBytes }) else {
            throw ExtensionRuntimeError.resourceLimitExceeded("storage key limit exceeded")
        }
    }

    /// Bounds parser recursion before handing corrupt persisted JSON to Codable.
    private func validateJSONStructure(_ data: Data) throws {
        let maximumDepth = ExtensionResourceLimits.standard.maximumNestingDepth
        try BoundedJSONPreflight.validate(
            data,
            maximumDepth: maximumDepth,
            maximumStringBytes: ExtensionResourceLimits.standard.maximumStringBytes,
            maximumStructuralTokens: ExtensionResourceLimits.standard.maximumNodeCount * 3
        )
        var depth = 0
        var inString = false
        var escaped = false
        var stringBytes = 0
        var containerCount = 0
        var separatorCount = 0
        var memberCount = 0
        let limits = ExtensionResourceLimits.standard
        for byte in data {
            if inString {
                if byte == 0x22, !escaped {
                    inString = false
                } else {
                    stringBytes += 1
                    guard stringBytes <= ExtensionResourceLimits.standard.maximumStringBytes else {
                        throw ExtensionRuntimeError.resourceLimitExceeded("persisted storage string is too large")
                    }
                    if escaped {
                        escaped = false
                    } else if byte == 0x5C {
                        escaped = true
                    }
                }
            } else if byte == 0x22 {
                inString = true
                stringBytes = 0
            } else if byte == 0x7B || byte == 0x5B {
                depth += 1
                containerCount += 1
                guard depth <= maximumDepth else {
                    throw ExtensionRuntimeError.resourceLimitExceeded("persisted storage is nested too deeply")
                }
            } else if byte == 0x2C {
                separatorCount += 1
            } else if byte == 0x3A {
                memberCount += 1
                guard memberCount <= limits.maximumObjectMemberCount else {
                    throw ExtensionRuntimeError.resourceLimitExceeded("persisted storage has too many object members")
                }
            } else if byte == 0x7D || byte == 0x5D {
                depth -= 1
                guard depth >= 0 else { throw ExtensionRuntimeError.unavailable("extension storage is corrupt") }
            }
            guard containerCount + separatorCount + 1 <= limits.maximumNodeCount else {
                throw ExtensionRuntimeError.resourceLimitExceeded("persisted storage has too many values")
            }
        }
        guard depth == 0, !inString else {
            throw ExtensionRuntimeError.unavailable("extension storage is corrupt")
        }
    }
}

private extension Dictionary where Key == String, Value == JSONValue {
    var jsonValue: JSONValue { .object(self) }
}
