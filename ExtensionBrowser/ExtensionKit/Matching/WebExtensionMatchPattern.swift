import Foundation

public struct WebExtensionMatchPattern: Hashable, Codable, Sendable, CustomStringConvertible {
    public enum Scheme: String, Codable, Hashable, Sendable {
        case wildcard = "*"
        case http
        case https
        case ws
        case wss
        case ftp
        case file
    }

    public enum Host: Hashable, Codable, Sendable {
        case any
        case exact(String)
        case domainAndSubdomains(String)
        case none
    }

    public let source: String
    public let schemes: Set<Scheme>
    public let host: Host
    public let pathExpression: String

    public var description: String { source }

    public init(_ source: String) throws {
        guard !source.isEmpty, source.utf8.count <= 2_048 else {
            throw ExtensionManifestError.invalidMatchPattern(
                pattern: String(source.prefix(128)),
                reason: "pattern is empty or exceeds 2048 UTF-8 bytes"
            )
        }
        self.source = source
        if source == "<all_urls>" {
            schemes = [.http, .https, .ws, .wss, .ftp, .file]
            host = .any
            pathExpression = Self.regularExpression(forGlob: "/*")
            return
        }

        guard let separator = source.range(of: "://") else {
            throw ExtensionManifestError.invalidMatchPattern(pattern: source, reason: "missing ://")
        }
        let schemeText = String(source[..<separator.lowerBound]).lowercased()
        guard let parsedScheme = Scheme(rawValue: schemeText) else {
            throw ExtensionManifestError.invalidMatchPattern(pattern: source, reason: "unsupported scheme")
        }

        let remainder = String(source[separator.upperBound...])
        guard let slash = remainder.firstIndex(of: "/") else {
            throw ExtensionManifestError.invalidMatchPattern(pattern: source, reason: "missing path")
        }
        let hostText = String(remainder[..<slash]).lowercased()
        let pathText = String(remainder[slash...])
        guard !pathText.isEmpty else {
            throw ExtensionManifestError.invalidMatchPattern(pattern: source, reason: "missing path")
        }

        if parsedScheme == .file {
            guard hostText.isEmpty || hostText == "*" else {
                throw ExtensionManifestError.invalidMatchPattern(pattern: source, reason: "file patterns cannot name a host")
            }
            schemes = [.file]
            host = .none
        } else {
            guard !hostText.isEmpty, !hostText.contains(":"), !hostText.contains("/") else {
                throw ExtensionManifestError.invalidMatchPattern(pattern: source, reason: "invalid host")
            }
            schemes = parsedScheme == .wildcard ? [.http, .https] : [parsedScheme]
            if hostText == "*" {
                host = .any
            } else if hostText.hasPrefix("*.") {
                let domain = String(hostText.dropFirst(2))
                guard Self.isValidHost(domain) else {
                    throw ExtensionManifestError.invalidMatchPattern(pattern: source, reason: "invalid wildcard host")
                }
                host = .domainAndSubdomains(domain)
            } else {
                guard !hostText.contains("*"), Self.isValidHost(hostText) else {
                    throw ExtensionManifestError.invalidMatchPattern(pattern: source, reason: "wildcards are only allowed as *.")
                }
                host = .exact(hostText)
            }
        }

        let expression = Self.regularExpression(forGlob: pathText)
        do {
            _ = try NSRegularExpression(pattern: expression)
        } catch {
            throw ExtensionManifestError.invalidMatchPattern(pattern: source, reason: "invalid path expression")
        }
        pathExpression = expression
    }

    public func matches(_ url: URL) -> Bool {
        guard let rawScheme = url.scheme?.lowercased(), let urlScheme = Scheme(rawValue: rawScheme), schemes.contains(urlScheme) else {
            return false
        }

        switch host {
        case .none:
            guard urlScheme == .file else { return false }
        case .any:
            if urlScheme != .file, (url.host?.isEmpty ?? true) { return false }
        case .exact(let expected):
            guard url.host?.lowercased() == expected else { return false }
        case .domainAndSubdomains(let expected):
            guard let actual = url.host?.lowercased(), actual == expected || actual.hasSuffix("." + expected) else {
                return false
            }
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return false }
        var pathAndQuery = components.percentEncodedPath.isEmpty ? "/" : components.percentEncodedPath
        if let query = components.percentEncodedQuery { pathAndQuery += "?" + query }
        return pathAndQuery.range(of: pathExpression, options: [.regularExpression]) != nil
    }

    private static func isValidHost(_ value: String) -> Bool {
        guard !value.isEmpty, value.utf8.count <= 253, !value.hasPrefix("."), !value.hasSuffix(".") else { return false }
        if value == "localhost" { return true }
        return value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy { label in
            guard !label.isEmpty, label.utf8.count <= 63, label.first != "-", label.last != "-" else { return false }
            return label.unicodeScalars.allSatisfy { scalar in
                let number = scalar.value
                return (48...57).contains(number) || (65...90).contains(number) || (97...122).contains(number) || number == 45
            }
        }
    }

    private static func regularExpression(forGlob glob: String) -> String {
        var result = "^"
        var literal = ""
        func flushLiteral() {
            guard !literal.isEmpty else { return }
            result += NSRegularExpression.escapedPattern(for: literal)
            literal.removeAll(keepingCapacity: true)
        }
        for character in glob {
            if character == "*" {
                flushLiteral()
                result += ".*"
            } else {
                literal.append(character)
            }
        }
        flushLiteral()
        return result + "$"
    }
}

public struct CompiledContentScript: Sendable, Equatable, Identifiable {
    public let extensionID: ExtensionIdentifier
    public let manifestIndex: Int
    public let includePatterns: [WebExtensionMatchPattern]
    public let excludePatterns: [WebExtensionMatchPattern]
    public let javascript: [String]
    public let css: [String]
    public let runAt: WebExtensionManifest.RunAt
    public let allFrames: Bool

    public var id: String { "\(extensionID.rawValue):\(manifestIndex)" }

    public func matches(_ url: URL) -> Bool {
        includePatterns.contains(where: { $0.matches(url) }) && !excludePatterns.contains(where: { $0.matches(url) })
    }
}

public enum ExtensionRuleCompiler {
    public static func compile(
        manifest: WebExtensionManifest,
        extensionID: ExtensionIdentifier
    ) throws -> [CompiledContentScript] {
        try manifest.contentScripts.enumerated().map { index, script in
            CompiledContentScript(
                extensionID: extensionID,
                manifestIndex: index,
                includePatterns: try script.matches.map(WebExtensionMatchPattern.init),
                excludePatterns: try script.excludeMatches.map(WebExtensionMatchPattern.init),
                javascript: script.javascript,
                css: script.css,
                runAt: script.runAt,
                allFrames: script.allFrames
            )
        }
    }
}

public actor ExtensionMatchCache {
    private var scriptsByExtension: [ExtensionIdentifier: [CompiledContentScript]] = [:]

    public init() {}

    public func replaceRules(for extensionID: ExtensionIdentifier, manifest: WebExtensionManifest) throws {
        scriptsByExtension[extensionID] = try ExtensionRuleCompiler.compile(manifest: manifest, extensionID: extensionID)
    }

    public func removeRules(for extensionID: ExtensionIdentifier) {
        scriptsByExtension.removeValue(forKey: extensionID)
    }

    public func removeAll() {
        scriptsByExtension.removeAll(keepingCapacity: false)
    }

    public func matchingScripts(for url: URL, enabledExtensionIDs: Set<ExtensionIdentifier>) -> [CompiledContentScript] {
        scriptsByExtension
            .filter { enabledExtensionIDs.contains($0.key) }
            .sorted { $0.key.rawValue < $1.key.rawValue }
            .flatMap { $0.value }
            .filter { $0.matches(url) }
    }
}
