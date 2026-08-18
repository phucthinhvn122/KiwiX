import Foundation

struct ExtensionDecodedRequest: Sendable {
    let api: String
    let arguments: JSONValue
}

/// Flat-string wire codec for the WebKit bridge. Receiving dictionaries/arrays directly from
/// `WKScriptMessage` would let WebKit recursively materialize an attacker-controlled object graph
/// before native limits run. A bounded JSON string lets native code preflight bytes and structure
/// before recursive decoding.
enum ExtensionMessageCodec {
    static func decodeRequest(
        _ body: Any,
        limits: ExtensionResourceLimits = .standard
    ) throws -> ExtensionDecodedRequest {
        guard let serialized = body as? String,
              serialized.utf8.count <= limits.maximumIncomingBytes else {
            throw ExtensionRuntimeError.invalidArguments("request must be bounded serialized JSON")
        }
        let data = Data(serialized.utf8)
        do {
            try BoundedJSONPreflight.validate(
                data,
                maximumDepth: limits.maximumNestingDepth + 1,
                maximumStringBytes: limits.maximumStringBytes,
                maximumStructuralTokens: limits.maximumNodeCount * 3
            )
        } catch {
            throw ExtensionRuntimeError.resourceLimitExceeded("request JSON exceeds structural limits")
        }

        let foundation: Any
        do {
            foundation = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ExtensionRuntimeError.invalidArguments("request is not valid JSON")
        }
        let envelope = try ExtensionPayloadValidator.convertIncoming(
            foundation,
            maximumBytes: limits.maximumIncomingBytes,
            limits: limits
        )
        guard let request = envelope.objectValue,
              request.keys.allSatisfy({ $0 == "api" || $0 == "args" }),
              let api = request["api"]?.stringValue,
              !api.isEmpty,
              api.utf8.count <= 128 else {
            throw ExtensionRuntimeError.invalidArguments("invalid request envelope")
        }
        return ExtensionDecodedRequest(api: api, arguments: request["args"] ?? .null)
    }

    static func encodeResponse(
        _ value: JSONValue,
        limits: ExtensionResourceLimits = .standard
    ) throws -> String {
        _ = try ExtensionPayloadValidator.validate(
            value,
            maximumBytes: limits.maximumOutgoingBytes,
            limits: limits
        )
        let data: Data
        do {
            data = try JSONEncoder().encode(value)
        } catch {
            throw ExtensionRuntimeError.resourceLimitExceeded("response is not serializable")
        }
        guard data.count <= limits.maximumOutgoingBytes,
              let serialized = String(data: data, encoding: .utf8) else {
            throw ExtensionRuntimeError.resourceLimitExceeded("response exceeds the serialized size limit")
        }
        return serialized
    }
}
