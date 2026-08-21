import Foundation

enum FaviconNetworkError: Error, Equatable {
    case invalidURL
    case invalidResponse
    case unacceptableStatusCode(Int)
    case responseTooLarge
}

struct FaviconDownload: Sendable {
    let data: Data
    let finalURL: URL
}

private final class FaviconSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var redirectCounts: [Int: Int] = [:]
    private let maximumRedirectCount = 5

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        let redirectCount = lock.withLock {
            let next = redirectCounts[task.taskIdentifier, default: 0] + 1
            redirectCounts[task.taskIdentifier] = next
            return next
        }
        guard redirectCount <= maximumRedirectCount, let targetURL = request.url else {
            completionHandler(nil)
            return
        }
        Task {
            guard let safeURL = try? await NetworkDestinationPolicy.normalizedPublicHTTPURL(
                targetURL,
                relativeTo: task.currentRequest?.url ?? task.originalRequest?.url
            ) else {
                completionHandler(nil)
                return
            }
            var sanitized = request
            sanitized.url = safeURL
            sanitized.httpShouldHandleCookies = false
            sanitized.setValue(nil, forHTTPHeaderField: "Cookie")
            sanitized.setValue(nil, forHTTPHeaderField: "Authorization")
            completionHandler(sanitized)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        lock.withLock {
            _ = redirectCounts.removeValue(forKey: task.taskIdentifier)
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didReceive challenge: URLAuthenticationChallenge,
        // Swift warns that the sendability of this parameter does not match `URLSessionTaskDelegate`
        // ("an error in the Swift 6 language mode"). Adding `@Sendable` was tried and measured on CI
        // run 32449478822: the warning is identical with and without it, so the mismatch is not the
        // one that annotation fixes. Left as the SDK's own spelling rather than annotated on a guess
        // — this method is the TLS challenge gate, and a signature that stops matching the protocol
        // is a delegate callback that silently stops being called. Needs someone with the SDK to
        // read the real declaration of the requirement.
        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        if challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.cancelAuthenticationChallenge, nil)
        }
    }
}

final class FaviconHTTPClient: @unchecked Sendable {
    private let delegate: FaviconSessionDelegate
    private let session: URLSession
    private let maximumByteCount: Int

    init(maximumByteCount: Int = FaviconImageValidator.maximumEncodedByteCount) {
        self.maximumByteCount = maximumByteCount
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.httpMaximumConnectionsPerHost = 4
        let delegate = FaviconSessionDelegate()
        self.delegate = delegate
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }

    deinit {
        session.invalidateAndCancel()
    }

    func download(from url: URL) async throws -> FaviconDownload {
        guard let safeURL = try? await NetworkDestinationPolicy.normalizedPublicHTTPURL(url) else {
            throw FaviconNetworkError.invalidURL
        }
        var request = URLRequest(
            url: safeURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: 10
        )
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("image/webp,image/png,image/jpeg,image/gif,image/x-icon,*/*;q=0.1", forHTTPHeaderField: "Accept")
        request.setValue("ExtensionBrowser/0.1 Favicon", forHTTPHeaderField: "User-Agent")

        let (bytes, response) = try await session.bytes(for: request)
        guard let response = response as? HTTPURLResponse, let finalURL = response.url,
              let safeFinalURL = try? await NetworkDestinationPolicy.normalizedPublicHTTPURL(
                finalURL,
                relativeTo: safeURL
              ) else {
            throw FaviconNetworkError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw FaviconNetworkError.unacceptableStatusCode(response.statusCode)
        }
        if response.expectedContentLength > Int64(maximumByteCount) {
            throw FaviconNetworkError.responseTooLarge
        }

        var data = Data()
        if response.expectedContentLength > 0 {
            data.reserveCapacity(min(Int(response.expectedContentLength), maximumByteCount))
        }
        // Byte-by-byte iteration is the only way `AsyncBytes` enforces a cap on a chunked response
        // whose length nobody declared, and that cap is the point of reading this way. Appending
        // byte-by-byte is not: each `Data.append` is a uniqueness check and a possible reallocation,
        // paid up to 1.5 million times for one icon. The bytes land in a flat buffer and cross into
        // `Data` in 16 KiB runs instead. The limit is still checked per byte, so what is accepted
        // does not change — only how many times the accounting is written down.
        var chunk = [UInt8]()
        chunk.reserveCapacity(16 * 1_024)
        var total = 0
        for try await byte in bytes {
            try Task.checkCancellation()
            guard total < maximumByteCount else {
                throw FaviconNetworkError.responseTooLarge
            }
            chunk.append(byte)
            total += 1
            if chunk.count == 16 * 1_024 {
                data.append(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
            }
        }
        data.append(contentsOf: chunk)
        _ = try FaviconImageValidator.validate(data: data, responseMIMEType: response.mimeType)
        return FaviconDownload(data: data, finalURL: safeFinalURL)
    }
}

actor FaviconRequestBroker {
    private struct PendingRequest {
        let task: Task<Void, Never>
        var waiters: [UUID: CheckedContinuation<FaviconDownload, Error>]
    }

    private let client: FaviconHTTPClient
    private var pending: [String: PendingRequest] = [:]

    init(client: FaviconHTTPClient = FaviconHTTPClient()) {
        self.client = client
    }

    func download(from url: URL, requestKey: String) async throws -> FaviconDownload {
        let waiterID = UUID()
        return try await withTaskCancellationHandler {
            try await waitForDownload(from: url, requestKey: requestKey, waiterID: waiterID)
        } onCancel: {
            Task { await self.cancelWaiter(requestKey: requestKey, waiterID: waiterID) }
        }
    }

    func cancelAll() {
        let requests = pending.values
        pending.removeAll(keepingCapacity: false)
        for request in requests {
            request.task.cancel()
            request.waiters.values.forEach { $0.resume(throwing: CancellationError()) }
        }
    }

    private func waitForDownload(
        from url: URL,
        requestKey: String,
        waiterID: UUID
    ) async throws -> FaviconDownload {
        try await withCheckedThrowingContinuation { continuation in
            if Task.isCancelled {
                continuation.resume(throwing: CancellationError())
                return
            }
            if var request = pending[requestKey] {
                request.waiters[waiterID] = continuation
                pending[requestKey] = request
                return
            }

            let task = Task { [weak self, client = self.client] in
                do {
                    let download = try await client.download(from: url)
                    await self?.finish(requestKey: requestKey, result: .success(download))
                } catch {
                    await self?.finish(requestKey: requestKey, result: .failure(error))
                }
            }
            pending[requestKey] = PendingRequest(task: task, waiters: [waiterID: continuation])
        }
    }

    private func cancelWaiter(requestKey: String, waiterID: UUID) {
        guard var request = pending[requestKey],
              let continuation = request.waiters.removeValue(forKey: waiterID) else {
            return
        }
        continuation.resume(throwing: CancellationError())
        if request.waiters.isEmpty {
            pending.removeValue(forKey: requestKey)
            request.task.cancel()
        } else {
            pending[requestKey] = request
        }
    }

    private func finish(requestKey: String, result: Result<FaviconDownload, Error>) {
        guard let request = pending.removeValue(forKey: requestKey) else { return }
        for continuation in request.waiters.values {
            switch result {
            case .success(let download):
                continuation.resume(returning: download)
            case .failure(let error):
                continuation.resume(throwing: error)
            }
        }
    }
}
