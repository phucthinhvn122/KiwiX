import CoreFoundation
import Foundation

public struct ExtensionResourceLimits: Sendable {
    public static let standard = ExtensionResourceLimits()

    public let maximumIncomingBytes = 256 * 1_024
    public let maximumOutgoingBytes = 512 * 1_024
    public let maximumNestingDepth = 16
    public let maximumNodeCount = 4_096
    public let maximumObjectMemberCount = 1_024
    public let maximumArrayLength = 1_024
    public let maximumStringBytes = 64 * 1_024
    public let maximumKeyBytes = 256
    public let maximumRequestsPerSecond = 20
    public let maximumBurstRequests = 40
    public let maximumOutstandingRequests = 8
    public let maximumOutstandingRequestsPerAPI = 4
    public let requestTimeoutNanoseconds: UInt64

    public let maximumInlineScriptBytes = 256 * 1_024
    public let maximumScriptFileCount = 32
    public let maximumScriptFileBytes = 1 * 1_024 * 1_024
    public let maximumAggregateScriptBytes = 4 * 1_024 * 1_024
    public let maximumRuntimePreparedScriptBytes = 16 * 1_024 * 1_024
    public let maximumRuntimePreparedScriptCount = 512
    public let maximumScriptResultBytes = 512 * 1_024

    public let maximumStorageOperationBytes = 512 * 1_024
    public let maximumStorageKeyCount = 512
    public let maximumStorageKeyBytes = 256
    public let maximumStorageValueBytes = 256 * 1_024

    public init(requestTimeoutNanoseconds: UInt64 = 10_000_000_000) {
        self.requestTimeoutNanoseconds = max(1, requestTimeoutNanoseconds)
    }
}

struct ExtensionPreparedSourceBudget {
    let maximumBytes: Int
    let maximumScriptCount: Int
    private(set) var usedBytes = 0
    private(set) var usedScriptCount = 0

    init(
        maximumBytes: Int = ExtensionResourceLimits.standard.maximumRuntimePreparedScriptBytes,
        maximumScriptCount: Int = ExtensionResourceLimits.standard.maximumRuntimePreparedScriptCount
    ) {
        self.maximumBytes = max(1, maximumBytes)
        self.maximumScriptCount = max(1, maximumScriptCount)
    }

    mutating func consume(byteCount: Int, scriptCount: Int = 1) throws {
        let (nextBytes, byteOverflow) = usedBytes.addingReportingOverflow(byteCount)
        let (nextScripts, scriptOverflow) = usedScriptCount.addingReportingOverflow(scriptCount)
        guard byteCount >= 0, scriptCount >= 0,
              !byteOverflow, !scriptOverflow,
              nextBytes <= maximumBytes,
              nextScripts <= maximumScriptCount else {
            throw ExtensionRuntimeError.resourceLimitExceeded("runtime content script budget exceeded")
        }
        usedBytes = nextBytes
        usedScriptCount = nextScripts
    }
}

enum ExtensionPayloadValidator {
    private struct Counters {
        var bytes = 0
        var nodes = 0
        var members = 0
    }

    static func convertIncoming(
        _ value: Any,
        maximumBytes: Int? = nil,
        limits: ExtensionResourceLimits = .standard
    ) throws -> JSONValue {
        var counters = Counters()
        return try convert(
            value,
            depth: 0,
            maximumBytes: maximumBytes ?? limits.maximumIncomingBytes,
            limits: limits,
            counters: &counters
        )
    }

    @discardableResult
    static func validate(
        _ value: JSONValue,
        maximumBytes: Int,
        limits: ExtensionResourceLimits = .standard
    ) throws -> Int {
        var counters = Counters()
        try inspect(
            value,
            depth: 0,
            maximumBytes: maximumBytes,
            limits: limits,
            counters: &counters
        )
        return counters.bytes
    }

    private static func convert(
        _ value: Any,
        depth: Int,
        maximumBytes: Int,
        limits: ExtensionResourceLimits,
        counters: inout Counters
    ) throws -> JSONValue {
        try enterNode(depth: depth, limits: limits, counters: &counters)
        if value is NSNull {
            try addBytes(4, maximum: maximumBytes, counters: &counters)
            return .null
        }
        if let number = value as? NSNumber {
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                try addBytes(5, maximum: maximumBytes, counters: &counters)
                return .bool(number.boolValue)
            }
            let double = number.doubleValue
            guard double.isFinite else { throw resourceError("numbers must be finite") }
            try addBytes(32, maximum: maximumBytes, counters: &counters)
            return .number(double)
        }
        if let string = value as? String {
            try validateString(string, maximum: limits.maximumStringBytes, name: "string")
            try addBytes(jsonStringByteEstimate(string), maximum: maximumBytes, counters: &counters)
            return .string(string)
        }
        if let array = value as? [Any] {
            guard array.count <= limits.maximumArrayLength else {
                throw resourceError("array length exceeds \(limits.maximumArrayLength)")
            }
            try addBytes(2 + array.count, maximum: maximumBytes, counters: &counters)
            var converted: [JSONValue] = []
            converted.reserveCapacity(array.count)
            for item in array {
                converted.append(try convert(
                    item,
                    depth: depth + 1,
                    maximumBytes: maximumBytes,
                    limits: limits,
                    counters: &counters
                ))
            }
            return .array(converted)
        }
        if let object = value as? [String: Any] {
            guard object.count <= limits.maximumObjectMemberCount else {
                throw resourceError("object member count exceeds \(limits.maximumObjectMemberCount)")
            }
            counters.members += object.count
            guard counters.members <= limits.maximumObjectMemberCount else {
                throw resourceError("aggregate object member count exceeds \(limits.maximumObjectMemberCount)")
            }
            try addBytes(2 + object.count, maximum: maximumBytes, counters: &counters)
            var converted: [String: JSONValue] = [:]
            converted.reserveCapacity(object.count)
            for (key, item) in object {
                try validateString(key, maximum: limits.maximumKeyBytes, name: "object key")
                try addBytes(jsonStringByteEstimate(key) + 1, maximum: maximumBytes, counters: &counters)
                converted[key] = try convert(
                    item,
                    depth: depth + 1,
                    maximumBytes: maximumBytes,
                    limits: limits,
                    counters: &counters
                )
            }
            return .object(converted)
        }
        throw ExtensionRuntimeError.invalidArguments("message contains a non-JSON value")
    }

    private static func inspect(
        _ value: JSONValue,
        depth: Int,
        maximumBytes: Int,
        limits: ExtensionResourceLimits,
        counters: inout Counters
    ) throws {
        try enterNode(depth: depth, limits: limits, counters: &counters)
        switch value {
        case .null:
            try addBytes(4, maximum: maximumBytes, counters: &counters)
        case .bool:
            try addBytes(5, maximum: maximumBytes, counters: &counters)
        case .number(let value):
            guard value.isFinite else { throw resourceError("numbers must be finite") }
            try addBytes(32, maximum: maximumBytes, counters: &counters)
        case .string(let string):
            try validateString(string, maximum: limits.maximumStringBytes, name: "string")
            try addBytes(jsonStringByteEstimate(string), maximum: maximumBytes, counters: &counters)
        case .array(let values):
            guard values.count <= limits.maximumArrayLength else {
                throw resourceError("array length exceeds \(limits.maximumArrayLength)")
            }
            try addBytes(2 + values.count, maximum: maximumBytes, counters: &counters)
            for item in values {
                try inspect(
                    item,
                    depth: depth + 1,
                    maximumBytes: maximumBytes,
                    limits: limits,
                    counters: &counters
                )
            }
        case .object(let object):
            guard object.count <= limits.maximumObjectMemberCount else {
                throw resourceError("object member count exceeds \(limits.maximumObjectMemberCount)")
            }
            counters.members += object.count
            guard counters.members <= limits.maximumObjectMemberCount else {
                throw resourceError("aggregate object member count exceeds \(limits.maximumObjectMemberCount)")
            }
            try addBytes(2 + object.count, maximum: maximumBytes, counters: &counters)
            for (key, item) in object {
                try validateString(key, maximum: limits.maximumKeyBytes, name: "object key")
                try addBytes(jsonStringByteEstimate(key) + 1, maximum: maximumBytes, counters: &counters)
                try inspect(
                    item,
                    depth: depth + 1,
                    maximumBytes: maximumBytes,
                    limits: limits,
                    counters: &counters
                )
            }
        }
    }

    private static func enterNode(
        depth: Int,
        limits: ExtensionResourceLimits,
        counters: inout Counters
    ) throws {
        guard depth <= limits.maximumNestingDepth else {
            throw resourceError("nesting depth exceeds \(limits.maximumNestingDepth)")
        }
        counters.nodes += 1
        guard counters.nodes <= limits.maximumNodeCount else {
            throw resourceError("node count exceeds \(limits.maximumNodeCount)")
        }
    }

    private static func validateString(_ string: String, maximum: Int, name: String) throws {
        guard string.utf8.count <= maximum else {
            throw resourceError("\(name) exceeds \(maximum) UTF-8 bytes")
        }
    }

    private static func jsonStringByteEstimate(_ string: String) -> Int {
        var bytes = 2 // opening and closing quote
        for scalar in string.unicodeScalars {
            switch scalar.value {
            case 0...0x1F:
                bytes += 6 // \u00XX
            case 0x22, 0x5C:
                bytes += 2 // escaped quote or backslash
            default:
                bytes += String(scalar).utf8.count
            }
        }
        return bytes
    }

    private static func addBytes(_ value: Int, maximum: Int, counters: inout Counters) throws {
        let (next, overflow) = counters.bytes.addingReportingOverflow(value)
        guard !overflow, next <= maximum else {
            throw resourceError("payload exceeds \(maximum) bytes")
        }
        counters.bytes = next
    }

    private static func resourceError(_ details: String) -> ExtensionRuntimeError {
        .resourceLimitExceeded(details)
    }
}

actor ExtensionRequestLimiter {
    struct Token: Hashable, Sendable {
        let id: UUID
        let extensionID: ExtensionIdentifier
        let api: String
    }

    private struct Key: Hashable {
        let extensionID: ExtensionIdentifier
        let api: String
        let tabID: UUID
    }

    private struct APIKey: Hashable {
        let extensionID: ExtensionIdentifier
        let api: String
    }

    private let limits: ExtensionResourceLimits
    private var recentByExtension: [ExtensionIdentifier: [Date]] = [:]
    private var recentByKey: [Key: [Date]] = [:]
    private var outstandingByExtension: [ExtensionIdentifier: Int] = [:]
    private var outstandingByAPI: [APIKey: Int] = [:]
    private var activeTokens: Set<UUID> = []

    init(limits: ExtensionResourceLimits = .standard) {
        self.limits = limits
    }

    func begin(extensionID: ExtensionIdentifier, api: String, tabID: UUID, now: Date = Date()) throws -> Token {
        let cutoff = now.addingTimeInterval(-1)
        var extensionRequests = recentByExtension[extensionID, default: []].filter { $0 > cutoff }
        let key = Key(extensionID: extensionID, api: api, tabID: tabID)
        let apiKey = APIKey(extensionID: extensionID, api: api)
        var keyRequests = recentByKey[key, default: []].filter { $0 > cutoff }
        guard extensionRequests.count < limits.maximumBurstRequests,
              keyRequests.count < limits.maximumRequestsPerSecond else {
            throw ExtensionRuntimeError.resourceLimitExceeded("request rate exceeded")
        }
        guard outstandingByExtension[extensionID, default: 0] < limits.maximumOutstandingRequests,
              outstandingByAPI[apiKey, default: 0] < limits.maximumOutstandingRequestsPerAPI else {
            throw ExtensionRuntimeError.resourceLimitExceeded("too many outstanding requests")
        }

        extensionRequests.append(now)
        keyRequests.append(now)
        recentByExtension[extensionID] = extensionRequests
        recentByKey[key] = keyRequests
        outstandingByExtension[extensionID, default: 0] += 1
        outstandingByAPI[apiKey, default: 0] += 1
        let token = Token(id: UUID(), extensionID: extensionID, api: api)
        activeTokens.insert(token.id)
        return token
    }

    func finish(_ token: Token) {
        guard activeTokens.remove(token.id) != nil else { return }
        outstandingByExtension[token.extensionID] = max(0, outstandingByExtension[token.extensionID, default: 1] - 1)
        let apiKey = APIKey(extensionID: token.extensionID, api: token.api)
        outstandingByAPI[apiKey] = max(0, outstandingByAPI[apiKey, default: 1] - 1)
        if outstandingByExtension[token.extensionID] == 0 { outstandingByExtension.removeValue(forKey: token.extensionID) }
        if outstandingByAPI[apiKey] == 0 { outstandingByAPI.removeValue(forKey: apiKey) }
    }
}

enum ExtensionRequestOutcome: Sendable {
    case success(JSONValue)
    case failure(ExtensionRuntimeError)
}

actor ExtensionRequestRace {
    private var outcome: ExtensionRequestOutcome?
    private var continuation: CheckedContinuation<ExtensionRequestOutcome, Never>?

    func wait() async -> ExtensionRequestOutcome {
        if let outcome { return outcome }
        return await withCheckedContinuation { continuation = $0 }
    }

    func resolve(_ newOutcome: ExtensionRequestOutcome) {
        guard outcome == nil else { return }
        outcome = newOutcome
        continuation?.resume(returning: newOutcome)
        continuation = nil
    }
}

actor ExtensionTabCreationLimiter {
    private var attempts: [ExtensionIdentifier: [Date]] = [:]
    private let maximumCreates: Int
    private let window: TimeInterval

    init(maximumCreates: Int = 5, window: TimeInterval = 30) {
        self.maximumCreates = maximumCreates
        self.window = window
    }

    func consume(extensionID: ExtensionIdentifier, now: Date = Date()) throws {
        let cutoff = now.addingTimeInterval(-window)
        var recent = attempts[extensionID, default: []].filter { $0 > cutoff }
        guard recent.count < maximumCreates else {
            attempts[extensionID] = recent
            throw ExtensionRuntimeError.resourceLimitExceeded("tab creation rate exceeded")
        }
        recent.append(now)
        attempts[extensionID] = recent
    }
}
