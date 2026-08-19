import Darwin
import Foundation

enum NetworkDestinationPolicyError: Error, Equatable {
    case invalidURL
    case prohibitedHost
    case resolutionFailed
    case prohibitedAddress
}

/// Central policy for native network requests whose destination can be influenced by web content.
/// A destination is allowed only when every resolved address is public unicast. Resolution failure
/// is fail-closed, and callers must repeat validation for every redirect target.
enum NetworkDestinationPolicy {
    typealias HostResolver = @Sendable (String) async throws -> [String]
    static let maximumURLByteCount = 8_192

    static func normalizedPublicHTTPURL(
        _ url: URL,
        relativeTo sourceURL: URL? = nil,
        resolver: HostResolver? = nil
    ) async throws -> URL {
        let normalized = try normalizedHTTPURL(url, relativeTo: sourceURL)
        guard let host = normalized.host else {
            throw NetworkDestinationPolicyError.invalidURL
        }

        if isIPAddress(host) {
            guard isPublicIPAddress(host) else {
                throw NetworkDestinationPolicyError.prohibitedAddress
            }
            return normalized
        }

        guard !isProhibitedHostname(host) else {
            throw NetworkDestinationPolicyError.prohibitedHost
        }
        let addresses: [String]
        if let resolver {
            addresses = try await resolver(host)
        } else {
            addresses = try await Task.detached(priority: .utility) {
                try resolve(host: host)
            }.value
        }
        guard !addresses.isEmpty else {
            throw NetworkDestinationPolicyError.resolutionFailed
        }
        guard addresses.allSatisfy(isPublicIPAddress) else {
            throw NetworkDestinationPolicyError.prohibitedAddress
        }
        return normalized
    }

    /// Performs URL/hostname normalization and rejects obviously local names and IP literals.
    /// DNS-backed callers must additionally use `normalizedPublicHTTPURL` before connecting.
    static func normalizedHTTPURL(_ url: URL, relativeTo sourceURL: URL? = nil) throws -> URL {
        guard url.absoluteString.utf8.count <= maximumURLByteCount,
              let rawScheme = url.scheme,
              let rawHost = url.host,
              url.user == nil,
              url.password == nil else {
            throw NetworkDestinationPolicyError.invalidURL
        }

        let scheme = rawScheme.lowercased()
        guard scheme == "http" || scheme == "https" else {
            throw NetworkDestinationPolicyError.invalidURL
        }
        if sourceURL?.scheme?.lowercased() == "https", scheme != "https" {
            throw NetworkDestinationPolicyError.invalidURL
        }

        let host = canonicalHostname(rawHost)
        guard !host.isEmpty, !isProhibitedHostname(host) else {
            throw NetworkDestinationPolicyError.prohibitedHost
        }
        if isIPAddress(host), !isPublicIPAddress(host) {
            throw NetworkDestinationPolicyError.prohibitedAddress
        }

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            throw NetworkDestinationPolicyError.invalidURL
        }
        components.scheme = scheme
        components.host = host
        components.fragment = nil
        guard let resolved = components.url?.absoluteURL,
              resolved.absoluteString.utf8.count <= maximumURLByteCount else {
            throw NetworkDestinationPolicyError.invalidURL
        }
        return resolved
    }

    static func isPublicIPAddress(_ string: String) -> Bool {
        let host = string.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 {
            return withUnsafeBytes(of: &ipv4.s_addr) { bytes in
                guard bytes.count == 4 else { return false }
                return isPublicIPv4(Array(bytes))
            }
        }

        var ipv6 = in6_addr()
        if inet_pton(AF_INET6, host, &ipv6) == 1 {
            return withUnsafeBytes(of: &ipv6) { bytes in
                guard bytes.count == 16 else { return false }
                return isPublicIPv6(Array(bytes))
            }
        }
        return false
    }

    static func isProhibitedHostname(_ rawHost: String) -> Bool {
        let host = canonicalHostname(rawHost)
        guard !host.isEmpty else { return true }
        if isIPAddress(host) { return !isPublicIPAddress(host) }

        // Single-label and special-use names must never escape to a native resolver. These cover
        // localhost aliases, mDNS, home routers and common split-horizon intranet namespaces.
        if !host.contains(".") { return true }
        let prohibitedSuffixes = [
            "localhost", "local", "localdomain", "lan", "home", "home.arpa", "internal", "intranet"
        ]
        return prohibitedSuffixes.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    private static func canonicalHostname(_ host: String) -> String {
        host
            .replacingOccurrences(of: "\u{3002}", with: ".")
            .replacingOccurrences(of: "\u{FF0E}", with: ".")
            .replacingOccurrences(of: "\u{FF61}", with: ".")
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
            .precomposedStringWithCanonicalMapping
    }

    private static func isIPAddress(_ host: String) -> Bool {
        var ipv4 = in_addr()
        if inet_pton(AF_INET, host, &ipv4) == 1 { return true }
        var ipv6 = in6_addr()
        return inet_pton(AF_INET6, host, &ipv6) == 1
    }

    private static func resolve(host: String) throws -> [String] {
        var hints = addrinfo()
        hints.ai_flags = AI_ADDRCONFIG
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP

        var result: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, nil, &hints, &result)
        guard status == 0, let first = result else {
            throw NetworkDestinationPolicyError.resolutionFailed
        }
        defer { freeaddrinfo(first) }

        var addresses: [String] = []
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let entry = cursor?.pointee {
            defer { cursor = entry.ai_next }
            guard entry.ai_family == AF_INET || entry.ai_family == AF_INET6,
                  let address = entry.ai_addr else { continue }
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let conversion = getnameinfo(
                address,
                entry.ai_addrlen,
                &buffer,
                socklen_t(buffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            if conversion == 0 {
                addresses.append(String(cString: buffer))
            }
        }
        return Array(Set(addresses))
    }

    private static func isPublicIPv4(_ bytes: [UInt8]) -> Bool {
        let a = bytes[0]
        let b = bytes[1]
        let c = bytes[2]

        if a == 0 || a == 10 || a == 127 { return false }
        if a == 100 && (64...127).contains(b) { return false } // shared address space
        if a == 169 && b == 254 { return false } // link-local
        if a == 172 && (16...31).contains(b) { return false }
        if a == 192 && b == 168 { return false }
        if a == 192 && b == 0 && c == 0 { return false } // IETF protocol assignments
        if a == 192 && b == 0 && c == 2 { return false } // TEST-NET-1
        if a == 192 && b == 88 && c == 99 { return false } // deprecated 6to4 relay
        if a == 198 && (b == 18 || b == 19) { return false } // benchmark range
        if a == 198 && b == 51 && c == 100 { return false } // TEST-NET-2
        if a == 203 && b == 0 && c == 113 { return false } // TEST-NET-3
        if a >= 224 { return false } // multicast and reserved
        return true
    }

    private static func isPublicIPv6(_ bytes: [UInt8]) -> Bool {
        guard bytes.count == 16 else { return false }
        if bytes.allSatisfy({ $0 == 0 }) { return false } // unspecified
        if bytes.dropLast().allSatisfy({ $0 == 0 }), bytes.last == 1 { return false } // loopback

        // IPv4-mapped and IPv4-compatible addresses inherit the IPv4 policy.
        if bytes[0..<10].allSatisfy({ $0 == 0 }),
           (bytes[10] == 0 && bytes[11] == 0 || bytes[10] == 0xFF && bytes[11] == 0xFF) {
            return isPublicIPv4(Array(bytes[12..<16]))
        }

        if bytes[0] == 0xFF { return false } // multicast
        if (bytes[0] & 0xFE) == 0xFC { return false } // unique-local fc00::/7
        if bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0x80 { return false } // link-local fe80::/10
        if bytes[0] == 0xFE && (bytes[1] & 0xC0) == 0xC0 { return false } // deprecated site-local
        if bytes[0] == 0x01 && bytes[1...7].allSatisfy({ $0 == 0 }) { return false } // discard-only 100::/64
        if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] <= 0x01 { return false } // special-use 2001::/23
        if bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0D && bytes[3] == 0xB8 { return false }
        if bytes[0] == 0x3F && (bytes[1] & 0xF0) == 0xF0 { return false } // documentation 3fff::/20
        if bytes[0] == 0x5F && bytes[1] == 0x00 { return false } // segment-routing SIDs 5f00::/16

        // The well-known NAT64 prefix embeds an IPv4 destination. The local-use translation prefix
        // cannot be classified without host routing state and is therefore rejected.
        if bytes.starts(with: [0x00, 0x64, 0xFF, 0x9B, 0, 0, 0, 0, 0, 0, 0, 0]) {
            return isPublicIPv4(Array(bytes[12..<16]))
        }
        if bytes.starts(with: [0x00, 0x64, 0xFF, 0x9B, 0x00, 0x01]) { return false }

        // 6to4 embeds an IPv4 endpoint; reject when that endpoint is not public.
        if bytes[0] == 0x20 && bytes[1] == 0x02 {
            return isPublicIPv4(Array(bytes[2..<6]))
        }
        // Native favicon networking is intentionally conservative: outside the explicit
        // translation forms above, only today's IPv6 global-unicast block is accepted.
        return (bytes[0] & 0xE0) == 0x20 // 2000::/3
    }
}
