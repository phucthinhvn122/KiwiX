import Foundation

enum SafeInput {
    static func utf8Prefix(_ value: String, maximumByteCount: Int) -> String {
        guard maximumByteCount > 0, value.utf8.count > maximumByteCount else {
            return maximumByteCount > 0 ? value : ""
        }
        var result = ""
        result.reserveCapacity(min(value.count, maximumByteCount))
        var usedBytes = 0
        for character in value {
            let bytes = String(character).utf8.count
            guard usedBytes + bytes <= maximumByteCount else { break }
            result.append(character)
            usedBytes += bytes
        }
        return result
    }

    static func displayText(
        _ value: String,
        maximumByteCount: Int,
        allowsNewlines: Bool = false
    ) -> String {
        let normalized = value.precomposedStringWithCanonicalMapping
        let filtered = String(normalized.unicodeScalars.filter {
            isSafeDisplayScalar($0, allowsNewlines: allowsNewlines)
        })
        return utf8Prefix(filtered, maximumByteCount: maximumByteCount)
    }

    static func isSafeDisplayText(_ value: String, allowsNewlines: Bool = false) -> Bool {
        !value.unicodeScalars.contains { !isSafeDisplayScalar($0, allowsNewlines: allowsNewlines) }
    }

    static func userFacingError(
        _ error: Error,
        fallback: String = "The operation couldn’t be completed. Try again."
    ) -> String {
        let safe = displayText(
            error.localizedDescription,
            maximumByteCount: 512,
            allowsNewlines: false
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return safe.isEmpty ? fallback : safe
    }

    static func displayHost(for url: URL, fallback: String = "This page") -> String {
        guard let host = url.host(percentEncoded: true), !host.isEmpty else { return fallback }
        let safe = displayText(host.lowercased(), maximumByteCount: 512)
        return safe.isEmpty ? fallback : safe
    }

    static func credentialFreeURL(_ url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        components.user = nil
        components.password = nil
        return components.url
    }

    static func displayURL(_ url: URL, maximumByteCount: Int = 8_192) -> String {
        let value = credentialFreeURL(url)?.absoluteString ?? ""
        return displayText(value, maximumByteCount: maximumByteCount)
    }

    private static func isSafeDisplayScalar(_ scalar: UnicodeScalar, allowsNewlines: Bool) -> Bool {
        if CharacterSet.controlCharacters.contains(scalar) || CharacterSet.newlines.contains(scalar) {
            return allowsNewlines && scalar.value == 0x0A
        }
        switch scalar.value {
        case 0x00AD, 0x061C, 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x2069, 0xFEFF:
            return false
        default:
            return true
        }
    }
}
