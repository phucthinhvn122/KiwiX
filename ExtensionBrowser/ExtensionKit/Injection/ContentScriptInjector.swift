import Foundation
import WebKit

public struct ContentScriptPreparationLimits: Equatable, Sendable {
    public var maximumResourceBytes: Int
    public var maximumPreparedSourceBytes: Int

    public init(
        maximumResourceBytes: Int = 4 * 1_024 * 1_024,
        maximumPreparedSourceBytes: Int = 16 * 1_024 * 1_024
    ) {
        self.maximumResourceBytes = max(1, maximumResourceBytes)
        self.maximumPreparedSourceBytes = max(1, maximumPreparedSourceBytes)
    }

    public static let `default` = ContentScriptPreparationLimits()
}

final class ContentScriptResourceCache {
    private var sources: [String: String] = [:]

    func source(
        for normalizedPath: String,
        maximumBytes: Int,
        load: () async throws -> Data
    ) async throws -> String {
        if let cached = sources[normalizedPath] { return cached }
        let data = try await load()
        guard data.count <= maximumBytes else {
            throw ExtensionRuntimeError.unavailable(
                "content script resource exceeds the \(maximumBytes) byte limit"
            )
        }
        guard let source = String(data: data, encoding: .utf8) else {
            throw ExtensionRuntimeError.invalidResourceEncoding(normalizedPath)
        }
        sources[normalizedPath] = source
        return source
    }
}

private struct BuiltContentScriptSource: Sendable {
    let rule: CompiledContentScript
    let source: String
}

@MainActor
public struct PreparedContentScript {
    public let rule: CompiledContentScript
    public let source: String
    public let contentWorld: WKContentWorld

    public var injectionTime: WKUserScriptInjectionTime {
        switch rule.runAt {
        case .documentStart: return .atDocumentStart
        case .documentEnd, .documentIdle: return .atDocumentEnd
        }
    }

    public var userScript: WKUserScript {
        WKUserScript(
            source: source,
            injectionTime: injectionTime,
            forMainFrameOnly: !rule.allFrames,
            in: contentWorld
        )
    }
}

@MainActor
public enum ContentScriptSourceBuilder {
    public static func prepare(
        installedExtension: InstalledExtension,
        repository: ExtensionRepository,
        limits: ContentScriptPreparationLimits = .default
    ) async throws -> [PreparedContentScript] {
        // Decoding, concatenating and guarding up to the bounded 16 MiB source set
        // stays off the main actor. Only WebKit object creation returns to MainActor.
        let built = try await Task.detached(priority: .utility) {
            try await buildSources(
                installedExtension: installedExtension,
                repository: repository,
                limits: limits
            )
        }.value
        let world = WKContentWorld.world(name: "ExtensionBrowser.Extension.\(installedExtension.id.rawValue)")
        return built.map { PreparedContentScript(rule: $0.rule, source: $0.source, contentWorld: world) }
    }

    nonisolated private static func buildSources(
        installedExtension: InstalledExtension,
        repository: ExtensionRepository,
        limits: ContentScriptPreparationLimits
    ) async throws -> [BuiltContentScriptSource] {
        let rules = try ExtensionRuleCompiler.compile(
            manifest: installedExtension.manifest,
            extensionID: installedExtension.id
        )
        var prepared: [BuiltContentScriptSource] = []
        prepared.reserveCapacity(rules.count)
        let resourceCache = ContentScriptResourceCache()
        var referencedSourceBytes = 0
        var preparedSourceBytes = 0

        for (index, rule) in rules.enumerated() {
            let manifestScript = installedExtension.manifest.contentScripts[index]
            var javaScriptParts: [String] = []
            javaScriptParts.reserveCapacity(manifestScript.javascript.count)
            for path in manifestScript.javascript {
                let normalizedPath = try ExtensionResourcePath.normalize(path)
                let source = try await resourceCache.source(
                    for: normalizedPath,
                    maximumBytes: limits.maximumResourceBytes
                ) {
                    try await repository.resourceData(
                        extensionID: installedExtension.id,
                        path: normalizedPath,
                        maximumBytes: limits.maximumResourceBytes
                    )
                }
                let suffix = "\n//# sourceURL=extension://\(installedExtension.id.rawValue)/\(normalizedPath)"
                let separatorBytes = javaScriptParts.isEmpty ? 0 : 3
                referencedSourceBytes = try addingWithinLimit(
                    source.utf8.count + suffix.utf8.count + separatorBytes,
                    to: referencedSourceBytes,
                    limit: limits.maximumPreparedSourceBytes
                )
                javaScriptParts.append(source + suffix)
            }
            var cssParts: [String] = []
            cssParts.reserveCapacity(manifestScript.css.count)
            for path in manifestScript.css {
                let normalizedPath = try ExtensionResourcePath.normalize(path)
                let source = try await resourceCache.source(
                    for: normalizedPath,
                    maximumBytes: limits.maximumResourceBytes
                ) {
                    try await repository.resourceData(
                        extensionID: installedExtension.id,
                        path: normalizedPath,
                        maximumBytes: limits.maximumResourceBytes
                    )
                }
                let separatorBytes = cssParts.isEmpty ? 0 : 1
                referencedSourceBytes = try addingWithinLimit(
                    source.utf8.count + separatorBytes,
                    to: referencedSourceBytes,
                    limit: limits.maximumPreparedSourceBytes
                )
                cssParts.append(source)
            }
            let source = makeGuardedSource(
                rule: rule,
                javaScript: javaScriptParts.joined(separator: "\n;\n"),
                css: cssParts.joined(separator: "\n")
            )
            preparedSourceBytes = try addingWithinLimit(
                source.utf8.count,
                to: preparedSourceBytes,
                limit: limits.maximumPreparedSourceBytes
            )
            prepared.append(BuiltContentScriptSource(rule: rule, source: source))
        }
        return prepared
    }

    nonisolated private static func addingWithinLimit(_ count: Int, to total: Int, limit: Int) throws -> Int {
        let (next, overflow) = total.addingReportingOverflow(count)
        guard !overflow, count >= 0, next <= limit else {
            throw ExtensionRuntimeError.contentScriptSourceLimitExceeded(limit: limit)
        }
        return next
    }

    nonisolated private static func makeGuardedSource(
        rule: CompiledContentScript,
        javaScript: String,
        css: String
    ) -> String {
        let includes = jsonStringArray(rule.includePatterns.map(\.source))
        let excludes = jsonStringArray(rule.excludePatterns.map(\.source))
        let marker = jsonString(rule.id)
        let cssLiteral = jsonString(css)
        return """
        (() => {
          const matchPattern = (pattern, href) => {
            let url; try { url = new URL(href); } catch (_) { return false; }
            if (pattern === '<all_urls>') return ['http:', 'https:', 'ws:', 'wss:', 'ftp:', 'file:'].includes(url.protocol);
            const found = pattern.match(/^([^:]+):\\/\\/([^/]*)(\\/.*)$/);
            if (!found) return false;
            const scheme = found[1]; const host = found[2].toLowerCase(); const path = found[3];
            if (scheme === '*') { if (!['http:', 'https:'].includes(url.protocol)) return false; }
            else if (`${scheme}:` !== url.protocol) return false;
            if (url.protocol !== 'file:') {
              const actual = url.hostname.toLowerCase();
              if (host === '*') { if (!actual) return false; }
              else if (host.startsWith('*.')) { const base = host.slice(2); if (actual !== base && !actual.endsWith(`.${base}`)) return false; }
              else if (actual !== host) return false;
            }
            const specials = new Set([46, 43, 63, 94, 36, 123, 125, 40, 41, 124, 91, 93, 92]);
            const escaped = Array.from(path, c => c === '*' ? '.*' : (specials.has(c.charCodeAt(0)) ? String.fromCharCode(92) + c : c)).join('');
            return new RegExp(`^${escaped}$`).test(url.pathname + url.search);
          };
          if (!\(includes).some(p => matchPattern(p, location.href))) return;
          if (\(excludes).some(p => matchPattern(p, location.href))) return;
          const key = \(marker);
          const injected = globalThis.__extensionBrowserInjectedScripts ??= new Set();
          if (injected.has(key)) return;
          injected.add(key);
          const css = \(cssLiteral);
          if (css) {
            const style = document.createElement('style');
            style.dataset.extensionBrowser = key;
            style.textContent = css;
            (document.head || document.documentElement).appendChild(style);
          }
          try {
            \(javaScript)
          } catch (error) {
            console.error('[ExtensionBrowser] content script failed', error);
          }
        })();
        """
    }

    nonisolated private static func jsonStringArray(_ strings: [String]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: strings),
              let result = String(data: data, encoding: .utf8) else { return "[]" }
        return result
    }

    nonisolated private static func jsonString(_ string: String) -> String {
        let array = jsonStringArray([string])
        return String(array.dropFirst().dropLast())
    }
}
