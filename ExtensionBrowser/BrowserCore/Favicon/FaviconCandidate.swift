import CryptoKit
import Foundation

struct FaviconCandidate: Equatable, Sendable {
    let url: URL
    let declaredMIMEType: String?
    let declaredSizes: [Int]
    let relationship: String
}

enum FaviconURLPolicy {
    static let maximumURLByteCount = 8_192

    static func validatedRemoteURL(_ url: URL, relativeTo pageURL: URL? = nil) -> URL? {
        guard url.absoluteString.utf8.count <= maximumURLByteCount,
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.user == nil,
              url.password == nil,
              let host = url.host,
              !host.isEmpty else {
            return nil
        }

        if pageURL?.scheme?.lowercased() == "https", scheme != "https" {
            return nil
        }

        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: true) else {
            return nil
        }
        components.scheme = scheme
        components.host = host.lowercased()
        components.fragment = nil
        guard let resolved = components.url?.absoluteURL,
              resolved.absoluteString.utf8.count <= maximumURLByteCount else {
            return nil
        }
        return resolved
    }

    static func fallbackURL(for pageURL: URL) -> URL? {
        guard let pageURL = validatedRemoteURL(pageURL),
              var components = URLComponents(url: pageURL, resolvingAgainstBaseURL: false) else {
            return nil
        }
        components.path = "/favicon.ico"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    static func canonicalString(for url: URL) -> String? {
        guard let url = validatedRemoteURL(url),
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased() else {
            return nil
        }
        components.scheme = scheme
        components.host = host
        components.fragment = nil
        if (scheme == "https" && components.port == 443) ||
            (scheme == "http" && components.port == 80) {
            components.port = nil
        }
        if components.percentEncodedPath.isEmpty {
            components.percentEncodedPath = "/"
        }
        return components.string
    }
}

enum FaviconCacheKey {
    static func value(for url: URL) -> String? {
        guard let canonical = FaviconURLPolicy.canonicalString(for: url) else {
            return nil
        }
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    static func isValid(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            ($0 >= 48 && $0 <= 57) || ($0 >= 97 && $0 <= 102)
        }
    }
}

enum FaviconCandidateParser {
    static let maximumCandidateCount = 32

    /// The result is JSON-compatible and intentionally contains attributes only, never page content.
    static let discoveryJavaScript = """
    (() => Array.from(document.querySelectorAll('link[rel]'))
      .slice(0, 64)
      .map((link) => ({
        href: link.getAttribute('href') || '',
        rel: link.getAttribute('rel') || '',
        type: link.getAttribute('type') || '',
        sizes: link.getAttribute('sizes') || ''
      }))
      .filter((item) => item.rel.toLowerCase().split(/\\s+/).some((token) =>
        token === 'icon' || token === 'apple-touch-icon' || token === 'apple-touch-icon-precomposed'
      ))
      .slice(0, 32))()
    """

    static func candidates(
        from javaScriptResult: Any?,
        pageURL: URL,
        includeFallback: Bool = true
    ) -> [FaviconCandidate] {
        guard let safePageURL = FaviconURLPolicy.validatedRemoteURL(pageURL) else {
            return []
        }

        let rawItems = javaScriptResult as? [Any] ?? []
        var parsed: [(candidate: FaviconCandidate, score: Int, order: Int)] = []
        var seen = Set<String>()

        for (order, item) in rawItems.prefix(maximumCandidateCount).enumerated() {
            guard let dictionary = item as? [String: Any],
                  let href = trimmedString(dictionary["href"], maximumLength: 4_096),
                  !href.isEmpty,
                  let rawURL = URL(string: href, relativeTo: safePageURL)?.absoluteURL,
                  let url = FaviconURLPolicy.validatedRemoteURL(rawURL, relativeTo: safePageURL),
                  let canonical = FaviconURLPolicy.canonicalString(for: url),
                  seen.insert(canonical).inserted else {
                continue
            }

            let relationship = trimmedString(dictionary["rel"], maximumLength: 256)?.lowercased() ?? ""
            let relationships = relationship.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            guard relationships.contains("icon") ||
                    relationships.contains("apple-touch-icon") ||
                    relationships.contains("apple-touch-icon-precomposed") else {
                continue
            }

            let mimeType = normalizedMIMEType(trimmedString(dictionary["type"], maximumLength: 128))
            let sizes = parseSizes(trimmedString(dictionary["sizes"], maximumLength: 256))
            let candidate = FaviconCandidate(
                url: url,
                declaredMIMEType: mimeType,
                declaredSizes: sizes,
                relationship: relationship
            )
            parsed.append((candidate, score(candidate), order))
        }

        parsed.sort {
            if $0.score == $1.score { return $0.order < $1.order }
            return $0.score > $1.score
        }
        var result = parsed.map(\.candidate)

        if includeFallback,
           let fallbackURL = FaviconURLPolicy.fallbackURL(for: safePageURL),
           let canonical = FaviconURLPolicy.canonicalString(for: fallbackURL),
           seen.insert(canonical).inserted {
            result.append(
                FaviconCandidate(
                    url: fallbackURL,
                    declaredMIMEType: "image/x-icon",
                    declaredSizes: [],
                    relationship: "fallback"
                )
            )
        }
        return result
    }

    private static func trimmedString(_ value: Any?, maximumLength: Int) -> String? {
        guard let value = value as? String, value.utf8.count <= maximumLength else {
            return nil
        }
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedMIMEType(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.split(separator: ";", maxSplits: 1).first?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return normalized?.isEmpty == false ? normalized : nil
    }

    private static func parseSizes(_ value: String?) -> [Int] {
        guard let value else { return [] }
        return value.lowercased().split(whereSeparator: { $0.isWhitespace }).compactMap { token in
            guard token != "any" else { return nil }
            let dimensions = token.split(separator: "x", maxSplits: 1)
            guard dimensions.count == 2,
                  let width = Int(dimensions[0]),
                  let height = Int(dimensions[1]),
                  width > 0,
                  height > 0,
                  width <= 4_096,
                  height <= 4_096 else {
                return nil
            }
            return max(width, height)
        }
    }

    private static func score(_ candidate: FaviconCandidate) -> Int {
        var value = 0
        if candidate.relationship.split(whereSeparator: { $0.isWhitespace }).contains("icon") {
            value += 20
        }
        if candidate.declaredMIMEType == "image/png" || candidate.declaredMIMEType == "image/x-icon" {
            value += 8
        }
        if let nearest = candidate.declaredSizes.min(by: { abs($0 - 64) < abs($1 - 64) }) {
            value += max(0, 16 - abs(nearest - 64) / 8)
        }
        return value
    }
}
