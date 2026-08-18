import XCTest
@testable import ExtensionBrowser

final class ExtensionResourceLimitTests: XCTestCase {
    func testOversizedMessageIsRejectedBeforeConversion() {
        let body: [String: Any] = [
            "api": "runtime.sendMessage",
            "args": String(repeating: "x", count: ExtensionResourceLimits.standard.maximumStringBytes + 1)
        ]
        XCTAssertThrowsError(try ExtensionPayloadValidator.convertIncoming(body)) { error in
            guard let runtimeError = error as? ExtensionRuntimeError,
                  case .resourceLimitExceeded = runtimeError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testDeepMessageIsRejected() {
        var value: Any = "leaf"
        for _ in 0...ExtensionResourceLimits.standard.maximumNestingDepth {
            value = ["nested": value]
        }
        XCTAssertThrowsError(try ExtensionPayloadValidator.convertIncoming(value)) { error in
            guard let runtimeError = error as? ExtensionRuntimeError,
                  case .resourceLimitExceeded = runtimeError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testTooManyObjectMembersAreRejected() {
        let count = ExtensionResourceLimits.standard.maximumObjectMemberCount + 1
        let object = Dictionary(uniqueKeysWithValues: (0..<count).map { ("key\($0)", $0) })
        XCTAssertThrowsError(try ExtensionPayloadValidator.convertIncoming(object))
    }

    func testNonFiniteNumberIsRejected() {
        XCTAssertThrowsError(try ExtensionPayloadValidator.convertIncoming(["number": Double.infinity]))
    }

    func testBridgeRequiresFlatSerializedWirePayloadBeforeRecursiveDecode() throws {
        XCTAssertThrowsError(try ExtensionMessageCodec.decodeRequest([
            "api": "runtime.sendMessage",
            "args": ["nested": true]
        ]))

        let decoded = try ExtensionMessageCodec.decodeRequest(
            #"{"api":"runtime.sendMessage","args":{"nested":true}}"#
        )
        XCTAssertEqual(decoded.api, "runtime.sendMessage")
        XCTAssertEqual(decoded.arguments, .object(["nested": .bool(true)]))
    }

    func testSerializedBridgeJSONIsStructurallyRejectedBeforeJSONSerialization() {
        var nested = "null"
        for _ in 0...ExtensionResourceLimits.standard.maximumNestingDepth {
            nested = #"{"nested":\#(nested)}"#
        }
        let request = #"{"api":"runtime.sendMessage","args":\#(nested)}"#

        XCTAssertThrowsError(try ExtensionMessageCodec.decodeRequest(request)) { error in
            guard case .resourceLimitExceeded = error as? ExtensionRuntimeError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testBridgeResponseIsBoundedSerializedJSON() throws {
        let response = try ExtensionMessageCodec.encodeResponse(
            .object(["ok": .bool(true), "value": .string("safe")])
        )
        let decoded = try JSONDecoder().decode(JSONValue.self, from: Data(response.utf8))
        XCTAssertEqual(decoded, .object(["ok": .bool(true), "value": .string("safe")]))

        XCTAssertThrowsError(try ExtensionMessageCodec.encodeResponse(
            .string(String(
                repeating: "x",
                count: ExtensionResourceLimits.standard.maximumStringBytes + 1
            ))
        ))
    }

    func testGeneratedBridgePostsSerializedPayloadRatherThanObjectGraph() throws {
        let identifier = try XCTUnwrap(ExtensionIdentifier(rawValue: String(repeating: "d", count: 32)))
        let source = ChromeBridgeJavaScript.source(
            messageHandlerName: "handler",
            extensionID: identifier
        )
        XCTAssertTrue(source.contains("target.postMessage(serialized)"))
        XCTAssertFalse(source.contains("target.postMessage({ api, args })"))
    }

    @MainActor
    func testRuntimeLockdownRejectsRequestsWhilePermissionsReload() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuntimeLockdownTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ExtensionRepository(baseDirectoryURL: root.appendingPathComponent("Extensions"))
        let permissions = ExtensionPermissionManager()
        let storage = ExtensionLocalStorage(repository: repository)
        let registry = ExtensionAPIRegistry(storage: storage, permissions: permissions)
        let identifier = try XCTUnwrap(ExtensionIdentifier(rawValue: String(repeating: "e", count: 32)))
        let context = ExtensionAPIContext(extensionID: identifier, tabID: UUID(), pageURL: nil)

        registry.suspendRuntime()
        await XCTAssertThrowsErrorAsync {
            _ = try await registry.handle(api: "runtime.sendMessage", arguments: .null, context: context)
        }

        registry.resumeRuntime()
        let result = try await registry.handle(
            api: "runtime.sendMessage",
            arguments: .string("ready"),
            context: context
        )
        XCTAssertEqual(result.objectValue?["message"], .string("ready"))
    }

    @MainActor
    func testRuntimeLockdownCancelsInFlightHandlerBeforeDelayedSideEffect() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuntimeCancellationTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ExtensionRepository(baseDirectoryURL: root.appendingPathComponent("Extensions"))
        let permissions = ExtensionPermissionManager()
        let registry = ExtensionAPIRegistry(
            storage: ExtensionLocalStorage(repository: repository),
            permissions: permissions
        )
        let sideEffect = RuntimeSideEffectSpy()
        registry.register(api: "test.delayed") { _, _ in
            try await Task.sleep(nanoseconds: 1_000_000_000)
            sideEffect.didRun = true
            return .null
        }
        let identifier = try XCTUnwrap(ExtensionIdentifier(rawValue: String(repeating: "9", count: 32)))
        let context = ExtensionAPIContext(extensionID: identifier, tabID: UUID(), pageURL: nil)
        let request = Task { @MainActor in
            try await registry.handle(api: "test.delayed", arguments: .null, context: context)
        }

        try await Task.sleep(nanoseconds: 20_000_000)
        registry.suspendRuntime()

        await XCTAssertThrowsErrorAsync { _ = try await request.value }
        XCTAssertFalse(sideEffect.didRun)
    }

    func testRequestLimiterRejectsSpamAndOutstandingRequests() async throws {
        let identifier = try XCTUnwrap(ExtensionIdentifier(rawValue: String(repeating: "a", count: 32)))
        let limiter = ExtensionRequestLimiter()
        let tabID = UUID()
        var tokens: [ExtensionRequestLimiter.Token] = []
        for _ in 0..<ExtensionResourceLimits.standard.maximumOutstandingRequestsPerAPI {
            tokens.append(try await limiter.begin(extensionID: identifier, api: "tabs.query", tabID: tabID))
        }
        do {
            _ = try await limiter.begin(extensionID: identifier, api: "tabs.query", tabID: tabID)
            XCTFail("Expected outstanding request limit")
        } catch {
            guard case .resourceLimitExceeded = error as? ExtensionRuntimeError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        for token in tokens { await limiter.finish(token) }
    }

    func testPreparedContentScriptBudgetIsGlobalAndDoesNotAdvanceAfterRejection() throws {
        var budget = ExtensionPreparedSourceBudget(maximumBytes: 10, maximumScriptCount: 2)
        try budget.consume(byteCount: 6)

        XCTAssertThrowsError(try budget.consume(byteCount: 5)) {
            XCTAssertEqual(
                $0 as? ExtensionRuntimeError,
                .resourceLimitExceeded("runtime content script budget exceeded")
            )
        }
        XCTAssertEqual(budget.usedBytes, 6)
        try budget.consume(byteCount: 4)
        XCTAssertEqual(budget.usedBytes, 10)
        XCTAssertEqual(budget.usedScriptCount, 2)
        XCTAssertThrowsError(try budget.consume(byteCount: 0))
    }

    @MainActor
    func testBridgeHandlerTimeoutFailsClosedAndReleasesRequest() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtensionTimeoutTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ExtensionRepository(baseDirectoryURL: root.appendingPathComponent("Extensions"))
        let permissions = ExtensionPermissionManager()
        let limits = ExtensionResourceLimits(requestTimeoutNanoseconds: 5_000_000)
        let registry = ExtensionAPIRegistry(
            storage: ExtensionLocalStorage(repository: repository),
            permissions: permissions,
            limits: limits
        )
        registry.register(api: "test.slow") { _, _ in
            try await Task.sleep(nanoseconds: 1_000_000_000)
            return .null
        }
        let identifier = try XCTUnwrap(ExtensionIdentifier(rawValue: String(repeating: "f", count: 32)))
        let context = ExtensionAPIContext(extensionID: identifier, tabID: UUID(), pageURL: nil)

        do {
            _ = try await registry.handle(api: "test.slow", arguments: .null, context: context)
            XCTFail("Expected request timeout")
        } catch {
            XCTAssertEqual(error as? ExtensionRuntimeError, .requestTimedOut)
        }

        registry.register(api: "test.slow") { _, _ in .string("recovered") }
        let recovered = try await registry.handle(api: "test.slow", arguments: .null, context: context)
        XCTAssertEqual(recovered, .string("recovered"))
    }

    @MainActor
    func testTimedOutHandlerThatIgnoresCancellationRetainsBoundedOutstandingSlot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtensionTimeoutTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ExtensionRepository(baseDirectoryURL: root.appendingPathComponent("Extensions"))
        let permissions = ExtensionPermissionManager()
        let limits = ExtensionResourceLimits(requestTimeoutNanoseconds: 10_000_000)
        let registry = ExtensionAPIRegistry(
            storage: ExtensionLocalStorage(repository: repository),
            permissions: permissions,
            limits: limits
        )
        let gate = IgnoringCancellationGate()
        registry.register(api: "test.never") { _, _ in
            await gate.wait()
            return .null
        }
        let identifier = try XCTUnwrap(ExtensionIdentifier(rawValue: String(repeating: "e", count: 32)))
        let context = ExtensionAPIContext(extensionID: identifier, tabID: UUID(), pageURL: nil)

        for _ in 0..<limits.maximumOutstandingRequestsPerAPI {
            do {
                _ = try await registry.handle(api: "test.never", arguments: .null, context: context)
                XCTFail("Expected request timeout")
            } catch {
                XCTAssertEqual(error as? ExtensionRuntimeError, .requestTimedOut)
            }
        }
        do {
            _ = try await registry.handle(api: "test.never", arguments: .null, context: context)
            XCTFail("Expected outstanding request limit")
        } catch {
            guard case .resourceLimitExceeded = error as? ExtensionRuntimeError else {
                await gate.releaseAll()
                return XCTFail("Unexpected error: \(error)")
            }
        }

        await gate.releaseAll()
        try await Task.sleep(nanoseconds: 10_000_000)
    }

    @MainActor
    func testRepositoryReloadFailureClearsPreviouslyPreparedRuntime() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtensionReloadFailureTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let extensionsRoot = root.appendingPathComponent("Extensions", isDirectory: true)
        let repository = ExtensionRepository(
            baseDirectoryURL: extensionsRoot,
            maximumInstalledExtensionCount: 1
        )
        let stagingContainer = root.appendingPathComponent("staging", isDirectory: true)
        let staged = stagingContainer.appendingPathComponent("payload", isDirectory: true)
        try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
        let manifest = WebExtensionManifest(
            manifestVersion: 3,
            name: "Reload Failure Fixture",
            version: "1"
        )
        try JSONEncoder().encode(manifest).write(to: staged.appendingPathComponent("manifest.json"))
        let identity = try ExtensionIdentityGenerator.identity(forDirectory: staged)
        _ = try await repository.install(ExtensionPackagePreview(
            id: identity.identifier,
            manifest: manifest,
            packageDigest: identity.digest,
            stagedDirectoryURL: staged,
            stagingContainerURL: stagingContainer
        ))
        let integration = ExtensionBrowserIntegration(repository: repository)
        await integration.reload()
        XCTAssertEqual(integration.debugInformation["Extensions enabled"], "1")

        for index in 0..<257 {
            try Data().write(to: extensionsRoot.appendingPathComponent("junk-\(index)"))
        }
        await integration.reload()

        XCTAssertEqual(integration.debugInformation["Extensions enabled"], "0")
        do {
            _ = try await integration.apiRegistry.handle(
                api: "runtime.sendMessage",
                arguments: .null,
                context: ExtensionAPIContext(extensionID: identity.identifier, tabID: UUID(), pageURL: nil)
            )
            XCTFail("Expected runtime to remain suspended after failed reload")
        } catch {
            guard case .unavailable = error as? ExtensionRuntimeError else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testTabCreationLimiterRejectsExtensionSpam() async throws {
        let identifier = try XCTUnwrap(ExtensionIdentifier(rawValue: String(repeating: "b", count: 32)))
        let limiter = ExtensionTabCreationLimiter(maximumCreates: 2, window: 60)
        let now = Date()
        try await limiter.consume(extensionID: identifier, now: now)
        try await limiter.consume(extensionID: identifier, now: now)
        await XCTAssertThrowsErrorAsync {
            try await limiter.consume(extensionID: identifier, now: now)
        }
    }

    @MainActor
    func testOversizedInlineScriptIsRejectedBeforeExecutor() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExtensionResourceLimitTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = ExtensionRepository(
            baseDirectoryURL: root.appendingPathComponent("Extensions", isDirectory: true)
        )
        let permissions = ExtensionPermissionManager()
        let storage = ExtensionLocalStorage(repository: repository)
        let registry = ExtensionAPIRegistry(storage: storage, permissions: permissions)
        let executor = ScriptExecutorSpy()
        registry.scriptExecutor = executor
        let identifier = try XCTUnwrap(ExtensionIdentifier(rawValue: String(repeating: "c", count: 32)))
        try await permissions.register(
            extensionID: identifier,
            manifest: WebExtensionManifest(
                manifestVersion: 3,
                name: "Script limits",
                version: "1",
                permissions: ["scripting"]
            ),
            isEnabled: true,
            grantedCapabilities: [.scripting]
        )
        let oversized = String(
            repeating: "x",
            count: ExtensionResourceLimits.standard.maximumInlineScriptBytes + 1
        )

        await XCTAssertThrowsErrorAsync {
            _ = try await registry.handle(
                api: "scripting.executeScript",
                arguments: .object(["code": .string(oversized)]),
                context: ExtensionAPIContext(extensionID: identifier, tabID: UUID(), pageURL: nil)
            )
        }
        XCTAssertEqual(executor.callCount, 0)
    }
}

@MainActor
private final class ScriptExecutorSpy: ExtensionScriptExecuting {
    private(set) var callCount = 0

    func executeScript(
        _ source: String,
        inTab tabID: UUID?,
        extensionID: ExtensionIdentifier
    ) async throws -> JSONValue {
        callCount += 1
        return .null
    }
}

@MainActor
private final class RuntimeSideEffectSpy {
    var didRun = false
}

private actor IgnoringCancellationGate {
    private var continuations: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func releaseAll() {
        let pending = continuations
        continuations.removeAll()
        pending.forEach { $0.resume() }
    }
}

private extension XCTestCase {
    func XCTAssertThrowsErrorAsync(
        _ expression: () async throws -> Void,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            try await expression()
            XCTFail("Expected error", file: file, line: line)
        } catch {
            // Expected.
        }
    }
}
