import Foundation

@MainActor
public final class ExtensionAPIRegistry {
    public typealias Handler = @MainActor @Sendable (JSONValue, ExtensionAPIContext) async throws -> JSONValue

    private var handlers: [String: Handler] = [:]
    private let storage: ExtensionLocalStorage
    private let permissions: ExtensionPermissionManager
    private let tabProvider: ExtensionTabProviding
    private let limits: ExtensionResourceLimits
    private let requestLimiter: ExtensionRequestLimiter
    private let tabCreationLimiter = ExtensionTabCreationLimiter()
    private struct ActionTitleScope: Hashable {
        let extensionID: ExtensionIdentifier
        let tabID: UUID?
    }

    private var actionTitles: [ActionTitleScope: String] = [:]
    private var defaultActionTitles: [ExtensionIdentifier: String] = [:]
    private var runtimeAvailable = true
    private var runtimeGeneration: UInt64 = 0
    private var activeOperations: [UUID: Task<Void, Never>] = [:]
    public weak var scriptExecutor: ExtensionScriptExecuting?

    public init(
        storage: ExtensionLocalStorage,
        permissions: ExtensionPermissionManager,
        tabProvider: ExtensionTabProviding? = nil,
        limits: ExtensionResourceLimits = .standard
    ) {
        self.storage = storage
        self.permissions = permissions
        self.tabProvider = tabProvider ?? BrowserHostExtensionTabProvider()
        self.limits = limits
        self.requestLimiter = ExtensionRequestLimiter(limits: limits)
        registerBuiltInHandlers()
    }

    public func register(api: String, handler: @escaping Handler) {
        handlers[api] = handler
    }

    func suspendRuntime() {
        runtimeAvailable = false
        runtimeGeneration &+= 1
        let operations = Array(activeOperations.values)
        activeOperations.removeAll(keepingCapacity: false)
        operations.forEach { $0.cancel() }
    }

    func resumeRuntime() {
        runtimeAvailable = true
    }

    public func handle(api: String, arguments: JSONValue, context: ExtensionAPIContext) async throws -> JSONValue {
        guard runtimeAvailable else {
            throw ExtensionRuntimeError.unavailable("extension runtime is refreshing permissions")
        }
        let generation = runtimeGeneration
        guard let handler = handlers[api] else { throw ExtensionRuntimeError.unsupportedAPI(api) }
        let token = try await requestLimiter.begin(
            extensionID: context.extensionID,
            api: api,
            tabID: context.tabID
        )
        let race = ExtensionRequestRace()
        let operationID = UUID()
        let operation = Task { @MainActor [weak self, requestLimiter, limits] in
            defer { self?.activeOperations.removeValue(forKey: operationID) }
            let outcome: ExtensionRequestOutcome
            do {
                try Task.checkCancellation()
                let result = try await handler(arguments, context)
                try Task.checkCancellation()
                _ = try ExtensionPayloadValidator.validate(
                    result,
                    maximumBytes: min(limits.maximumOutgoingBytes, limits.maximumScriptResultBytes)
                )
                outcome = .success(result)
            } catch {
                outcome = .failure(Self.runtimeError(from: error))
            }
            await requestLimiter.finish(token)
            await race.resolve(outcome)
        }
        activeOperations[operationID] = operation
        let timeout = Task { [limits] in
            do {
                try await Task.sleep(nanoseconds: limits.requestTimeoutNanoseconds)
                try Task.checkCancellation()
                await race.resolve(.failure(ExtensionRuntimeError.requestTimedOut))
                // The caller receives a timeout and cancels the operation below. The token is
                // deliberately retained until the handler actually exits: a native handler that
                // ignores cancellation must occupy one of the bounded outstanding slots instead
                // of allowing an attacker to accumulate unbounded orphaned tasks.
            } catch {
                // Cancellation means the operation completed first.
            }
        }

        let outcome = await race.wait()
        timeout.cancel()
        switch outcome {
        case .success(let result):
            guard runtimeAvailable, generation == runtimeGeneration else {
                throw ExtensionRuntimeError.unavailable("extension permissions changed during the request")
            }
            return result
        case .failure(let error):
            operation.cancel()
            throw error
        }
    }

    public var registeredAPIs: [String] { handlers.keys.sorted() }

    public func replaceActionDefaults(with installedExtensions: [InstalledExtension]) {
        let liveIDs = Set(installedExtensions.map(\.id))
        actionTitles = actionTitles.filter { liveIDs.contains($0.key.extensionID) }
        defaultActionTitles = Dictionary(uniqueKeysWithValues: installedExtensions.compactMap { installed in
            guard let action = installed.manifest.action else { return nil }
            return (installed.id, action.defaultTitle ?? installed.metadata.name)
        })
    }

    public func actionTitle(
        extensionID: ExtensionIdentifier,
        tabID: UUID?,
        fallback: String
    ) -> String {
        if let tabID,
           let title = actionTitles[ActionTitleScope(extensionID: extensionID, tabID: tabID)] {
            return title
        }
        return actionTitles[ActionTitleScope(extensionID: extensionID, tabID: nil)]
            ?? defaultActionTitles[extensionID]
            ?? fallback
    }

    public func removeActionState(forTabID tabID: UUID) {
        actionTitles = actionTitles.filter { $0.key.tabID != tabID }
    }

    private func registerBuiltInHandlers() {
        register(api: "storage.local.get") { [storage, permissions] arguments, context in
            try await permissions.authorize(.storage, extensionID: context.extensionID)
            try Task.checkCancellation()
            let request = Self.storageGetRequest(arguments)
            let values = try await storage.get(extensionID: context.extensionID, keys: request.keys)
            if let defaults = request.defaults {
                return .object(defaults.merging(values) { _, stored in stored })
            }
            return .object(values)
        }
        register(api: "storage.local.set") { [storage, permissions] arguments, context in
            try await permissions.authorize(.storage, extensionID: context.extensionID)
            try Task.checkCancellation()
            guard let values = arguments.objectValue else {
                throw ExtensionRuntimeError.invalidArguments("storage.local.set expects an object")
            }
            try await storage.set(extensionID: context.extensionID, values: values)
            return .null
        }
        register(api: "storage.local.remove") { [storage, permissions] arguments, context in
            try await permissions.authorize(.storage, extensionID: context.extensionID)
            try Task.checkCancellation()
            let keys = try Self.stringList(from: arguments, argumentName: "keys")
            try await storage.remove(extensionID: context.extensionID, keys: keys)
            return .null
        }
        register(api: "storage.local.clear") { [storage, permissions] _, context in
            try await permissions.authorize(.storage, extensionID: context.extensionID)
            try Task.checkCancellation()
            try await storage.clear(extensionID: context.extensionID)
            return .null
        }
        register(api: "runtime.sendMessage") { arguments, context in
            .object([
                "delivered": .bool(true),
                "extensionId": .string(context.extensionID.rawValue),
                "message": arguments
            ])
        }
        register(api: "tabs.query") { [weak self] arguments, context in
            guard let self else { throw ExtensionRuntimeError.unavailable("runtime released") }
            try await self.permissions.authorize(.tabs, extensionID: context.extensionID)
            try Task.checkCancellation()
            let query = arguments.objectValue ?? [:]
            var tabs = self.tabProvider.visibleTabs()
            if query["active"] == .bool(true) { tabs = tabs.filter(\.isActive) }
            return .array(tabs.map(\.jsonValue))
        }
        register(api: "tabs.create") { [weak self] arguments, context in
            guard let self else { throw ExtensionRuntimeError.unavailable("runtime released") }
            try await self.permissions.authorize(.tabs, extensionID: context.extensionID)
            try Task.checkCancellation()
            let object = arguments.objectValue ?? [:]
            let url: URL?
            if let value = object["url"]?.stringValue {
                guard let parsed = URL(string: value), Self.isAllowedTabURL(parsed) else {
                    throw ExtensionRuntimeError.invalidArguments("tabs.create received an unsafe URL")
                }
                url = parsed
            } else {
                url = nil
            }
            let active = object["active"] != .bool(false)
            try await self.tabCreationLimiter.consume(extensionID: context.extensionID)
            try Task.checkCancellation()
            return try self.tabProvider.createTab(url: url, active: active).jsonValue
        }
        register(api: "scripting.executeScript") { [weak self] arguments, context in
            guard let self, let executor = self.scriptExecutor else {
                throw ExtensionRuntimeError.unavailable("script executor is not attached")
            }
            try await self.permissions.authorize(.scripting, extensionID: context.extensionID)
            try Task.checkCancellation()
            guard let object = arguments.objectValue else {
                throw ExtensionRuntimeError.invalidArguments("scripting.executeScript expects an object")
            }
            let target = object["target"]?.objectValue
            let requestedTabID = target?["tabId"]?.stringValue.flatMap(UUID.init(uuidString:))
            let source: String
            if let code = object["code"]?.stringValue {
                guard code.utf8.count <= self.limits.maximumInlineScriptBytes else {
                    throw ExtensionRuntimeError.resourceLimitExceeded("inline script is too large")
                }
                source = code
            } else if let files = object["files"]?.arrayValue?.compactMap(\.stringValue), !files.isEmpty {
                guard files.count <= self.limits.maximumScriptFileCount,
                      files.allSatisfy({ $0.utf8.count <= ExtensionResourcePath.maximumPathByteCount }) else {
                    throw ExtensionRuntimeError.resourceLimitExceeded("script file list is too large")
                }
                // Resource expansion occurs in ExtensionBrowserIntegration before evaluation.
                source = files.map { "/*__EXTENSION_FILE__:\($0)*/" }.joined(separator: "\n")
            } else {
                throw ExtensionRuntimeError.invalidArguments("executeScript requires func/code or files")
            }
            try Task.checkCancellation()
            return try await executor.executeScript(
                source,
                inTab: requestedTabID ?? context.tabID,
                extensionID: context.extensionID
            )
        }
        register(api: "action.getTitle") { [weak self] arguments, context in
            guard let self else { throw ExtensionRuntimeError.unavailable("runtime released") }
            let tabID = try self.actionTabID(from: arguments)
            return .string(self.actionTitle(
                extensionID: context.extensionID,
                tabID: tabID,
                fallback: ""
            ))
        }
        register(api: "action.setTitle") { [weak self] arguments, context in
            guard let self else { throw ExtensionRuntimeError.unavailable("runtime released") }
            guard let title = arguments.objectValue?["title"]?.stringValue else {
                throw ExtensionRuntimeError.invalidArguments("action.setTitle expects title")
            }
            guard title.utf8.count <= ManifestValidator.maximumActionTitleBytes,
                  SafeInput.isSafeDisplayText(title) else {
                throw ExtensionRuntimeError.invalidArguments("action title exceeds the UTF-8 size limit")
            }
            let tabID = try self.actionTabID(from: arguments)
            self.actionTitles[ActionTitleScope(extensionID: context.extensionID, tabID: tabID)] = title
            return .null
        }
    }

    private static func storageGetRequest(_ value: JSONValue) -> (keys: [String]?, defaults: [String: JSONValue]?) {
        switch value {
        case .null: return (nil, nil)
        case .string(let key): return ([key], nil)
        case .array(let values): return (values.compactMap(\.stringValue), nil)
        case .object(let defaults): return (Array(defaults.keys), defaults)
        default: return ([], nil)
        }
    }

    private static func stringList(from value: JSONValue, argumentName: String) throws -> [String] {
        if let string = value.stringValue { return [string] }
        if let array = value.arrayValue {
            let strings = array.compactMap(\.stringValue)
            guard strings.count == array.count else {
                throw ExtensionRuntimeError.invalidArguments("\(argumentName) must contain strings")
            }
            return strings
        }
        throw ExtensionRuntimeError.invalidArguments("\(argumentName) must be a string or array")
    }

    private static func isAllowedTabURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased() else { return false }
        if scheme == "about" { return url.absoluteString == "about:blank" }
        return ["http", "https"].contains(scheme) && SafePersistence.isSafePersistedURL(url)
    }

    private static func runtimeError(from error: Error) -> ExtensionRuntimeError {
        if let runtimeError = error as? ExtensionRuntimeError { return runtimeError }
        return .unavailable(SafeInput.displayText(
            error.localizedDescription,
            maximumByteCount: 512,
            allowsNewlines: false
        ))
    }

    private func actionTabID(from arguments: JSONValue) throws -> UUID? {
        guard let value = arguments.objectValue?["tabId"] else { return nil }
        guard let string = value.stringValue, let tabID = UUID(uuidString: string) else {
            throw ExtensionRuntimeError.invalidArguments("action tabId must be a tab UUID string")
        }
        guard tabProvider.visibleTabs().contains(where: { $0.id == tabID }) else {
            throw ExtensionRuntimeError.unavailable("action target tab is not visible")
        }
        return tabID
    }
}
