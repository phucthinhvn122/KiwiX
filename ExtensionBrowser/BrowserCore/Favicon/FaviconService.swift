import Foundation
import UIKit

enum FaviconPrivacyMode: String, Sendable {
    case normal
    case `private`
}

struct FaviconDataResult: Sendable {
    let data: Data
    let sourceURL: URL
}

@MainActor
struct FaviconImageResult {
    let image: UIImage
    let sourceURL: URL
}

@MainActor
final class FaviconService {
    static let discoveryJavaScript = FaviconCandidateParser.discoveryJavaScript

    private let cache: FaviconCache
    private let broker: FaviconRequestBroker
    private let decoder: FaviconImageDecoder

    init(
        cache: FaviconCache = FaviconCache(),
        broker: FaviconRequestBroker = FaviconRequestBroker(),
        decoder: FaviconImageDecoder = FaviconImageDecoder()
    ) {
        self.cache = cache
        self.broker = broker
        self.decoder = decoder
    }

    func image(
        for pageURL: URL,
        javaScriptResult: Any?,
        privacyMode: FaviconPrivacyMode
    ) async -> FaviconImageResult? {
        guard let result = await data(
            for: pageURL,
            javaScriptResult: javaScriptResult,
            privacyMode: privacyMode
        ), let decoded = await decoder.decode(result.data) else {
            return nil
        }
        return FaviconImageResult(image: UIImage(cgImage: decoded.cgImage), sourceURL: result.sourceURL)
    }

    func data(
        for pageURL: URL,
        javaScriptResult: Any?,
        privacyMode: FaviconPrivacyMode
    ) async -> FaviconDataResult? {
        let candidates = FaviconCandidateParser.candidates(
            from: javaScriptResult,
            pageURL: pageURL,
            includeFallback: true
        )
        for candidate in candidates {
            do {
                try Task.checkCancellation()
                guard let key = FaviconCacheKey.value(for: candidate.url) else { continue }

                if privacyMode == .normal,
                   let cached = await cache.data(forKey: key) {
                    if (try? FaviconImageValidator.validate(data: cached, responseMIMEType: nil)) != nil {
                        return FaviconDataResult(data: cached, sourceURL: candidate.url)
                    }
                    await cache.removeData(forKey: key)
                }

                let download = try await broker.download(
                    from: candidate.url,
                    requestKey: "\(privacyMode.rawValue):\(key)"
                )
                try Task.checkCancellation()
                if privacyMode == .normal {
                    await cache.insert(download.data, forKey: key)
                }
                return FaviconDataResult(data: download.data, sourceURL: download.finalURL)
            } catch is CancellationError {
                return nil
            } catch {
                continue
            }
        }
        return nil
    }

    /// The icon already on disk for a known favicon address. Never touches the network.
    ///
    /// `TabRecord.faviconURL` is computed on every navigation, validated on save, validated again on
    /// load and re-hydrated onto every restored `Tab` — and nothing has ever read it back, so a
    /// relaunch showed a generic globe for every tab until its page was visited again. Cache-only on
    /// purpose: restoring fifty tabs must not open fifty connections at launch.
    func cachedImage(for faviconURL: URL) async -> UIImage? {
        guard let key = FaviconCacheKey.value(for: faviconURL),
              let data = await cache.data(forKey: key),
              let decoded = await decoder.decode(data) else {
            return nil
        }
        return UIImage(cgImage: decoded.cgImage)
    }

    func cancelAll() async {
        await broker.cancelAll()
    }

    func clearCache() async {
        await cache.removeAll()
    }
}
