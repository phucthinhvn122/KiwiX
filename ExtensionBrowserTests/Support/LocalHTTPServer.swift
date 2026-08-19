import Foundation
import Network
@testable import ExtensionBrowser

/// A real HTTP/1.1 server on loopback, for tests that must observe whether a request actually
/// reached the network.
///
/// M2 could not answer that. The harness page is served by `loadSimulatedRequest`, so its
/// subresources point at a host nobody owns: `blocked.kiwix.test` fails DNS, and "suppressed by
/// declarativeNetRequest" produces exactly the same silence as "name did not resolve". A request
/// to `127.0.0.1` needs no DNS at all, so silence here has only one explanation left — provided a
/// sibling request on the same page did arrive, which is what the ordering in the fixture page is
/// for.
///
/// Test-only. It lives in the test target and never ships.
final class LocalHTTPServer: @unchecked Sendable {
    struct Route {
        let contentType: String
        let body: Data
    }

    enum ServerError: Error, LocalizedError {
        case didNotStart(String)

        var errorDescription: String? {
            switch self {
            case .didNotStart(let reason):
                return "Local test server did not start: \(reason)"
            }
        }
    }

    private let listener: NWListener
    private let queue = DispatchQueue(label: "kiwix.tests.local-http-server")
    private let lock = NSLock()
    private var routes: [String: Route] = [:]
    private var observed: [String] = []
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    init() throws {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Never expose a test server to the CI runner's LAN.
        parameters.requiredInterfaceType = .loopback
        listener = try NWListener(using: parameters)
    }

    // MARK: - Lifecycle

    /// - Returns: the ephemeral port the listener bound to.
    func start() async throws -> UInt16 {
        let gate = ResumeOnce()
        return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, Error>) in
            listener.stateUpdateHandler = { [weak self] state in
                switch state {
                case .ready:
                    guard gate.claim() else { return }
                    guard let port = self?.listener.port?.rawValue, port != 0 else {
                        continuation.resume(throwing: ServerError.didNotStart("ready without a port"))
                        return
                    }
                    continuation.resume(returning: port)
                case .failed(let error):
                    if gate.claim() { continuation.resume(throwing: error) }
                case .cancelled:
                    if gate.claim() { continuation.resume(throwing: ServerError.didNotStart("cancelled")) }
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    func stop() {
        listener.stateUpdateHandler = nil
        listener.newConnectionHandler = nil
        listener.cancel()
        lock.lock()
        let open = Array(connections.values)
        connections.removeAll()
        lock.unlock()
        open.forEach { $0.cancel() }
    }

    // MARK: - Routing and observation

    func route(_ path: String, contentType: String, body: String) {
        lock.lock()
        routes[path] = Route(contentType: contentType, body: Data(body.utf8))
        lock.unlock()
    }

    var requestedPaths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return observed
    }

    func received(_ path: String) -> Bool {
        requestedPaths.contains(path)
    }

    // MARK: - Connection handling

    private func accept(_ connection: NWConnection) {
        lock.lock()
        connections[ObjectIdentifier(connection)] = connection
        lock.unlock()
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func forget(_ connection: NWConnection) {
        lock.lock()
        connections.removeValue(forKey: ObjectIdentifier(connection))
        lock.unlock()
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var accumulated = buffer
            if let data { accumulated.append(data) }

            if error != nil {
                connection.cancel()
                self.forget(connection)
                return
            }
            // Only the request head is needed; nothing here accepts a body.
            if let separator = accumulated.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(decoding: accumulated[..<separator.lowerBound], as: UTF8.self)
                self.respond(to: head, on: connection)
                return
            }
            // A head this large is not a request this server should try to answer.
            if isComplete || accumulated.count > 64 * 1024 {
                connection.cancel()
                self.forget(connection)
                return
            }
            self.receive(on: connection, buffer: accumulated)
        }
    }

    private func respond(to head: String, on connection: NWConnection) {
        // "GET /path?query HTTP/1.1" — the path is what the assertions key on.
        let requestLine = String(head.prefix { $0 != "\r" && $0 != "\n" })
        let fields = requestLine.split(separator: " ")
        let target = fields.count >= 2 ? String(fields[1]) : "/"
        let path = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? target

        lock.lock()
        observed.append(path)
        let route = routes[path]
        lock.unlock()

        let body = route?.body ?? Data("not found".utf8)
        var response = "HTTP/1.1 \(route == nil ? "404 Not Found" : "200 OK")\r\n"
        response += "Content-Type: \(route?.contentType ?? "text/plain; charset=utf-8")\r\n"
        response += "Content-Length: \(body.count)\r\n"
        // A cached subresource would never reach the server, which would read as "blocked".
        response += "Cache-Control: no-store, no-cache, must-revalidate\r\n"
        response += "Connection: close\r\n\r\n"

        var payload = Data(response.utf8)
        payload.append(body)
        connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
            connection.cancel()
            self?.forget(connection)
        })
    }
}
