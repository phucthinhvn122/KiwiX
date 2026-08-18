import Foundation
import WebKit

@MainActor
public final class ExtensionBrowserIntegration: NSObject, BrowserExtensionIntegrating, ExtensionScriptExecuting {
    private struct PreparedRuntimeExtension {
        let installed: InstalledExtension
        let contentWorld: WKContentWorld
        let handlerName: String
        let scripts: [PreparedContentScript]
    }

    private final class ControllerRecord {
        weak var controller: WKUserContentController?
        let context: BrowserExtensionTabContext
        let scriptRegistry: WebViewUserScriptRegistry
        var handlerExtensionIDs: Set<ExtensionIdentifier> = []

        init(controller: WKUserContentController, context: BrowserExtensionTabContext) {
            self.controller = controller
            self.context = context
            self.scriptRegistry = WebViewUserScriptRegistry(controller: controller)
        }
    }

    private final class WeakWebView {
        weak var value: WKWebView?
        init(_ value: WKWebView) { self.value = value }
    }

    public let repository: ExtensionRepository
    public let installer: ExtensionInstaller
    public let permissions: ExtensionPermissionManager
    public let matchCache: ExtensionMatchCache
    public let storage: ExtensionLocalStorage
    public let apiRegistry: ExtensionAPIRegistry
    private let actionCoordinator: ExtensionActionCoordinator

    private var prepared: [ExtensionIdentifier: PreparedRuntimeExtension] = [:]
    private var controllers: [ObjectIdentifier: ControllerRecord] = [:]
    private var webViews: [UUID: WeakWebView] = [:]
    private var navigationRevocations: [UUID: Task<Void, Never>] = [:]
    private let idleScheduler = DocumentIdleScheduler()
    private var registeredPermissionIDs: Set<ExtensionIdentifier> = []
    private var repositoryObserver: NSObjectProtocol?
    private var lastRuntimeError: String?
    private var injectedScriptCount = 0
    private var activeScriptExecutions: [ExtensionIdentifier: Int] = [:]
    private var permissionFingerprints: [ExtensionIdentifier: String] = [:]
    private var reloadTail: Task<Void, Never>?
    private var requestedReloadGeneration: UInt64 = 0

    public init(repository: ExtensionRepository = ExtensionRepository()) {
        self.repository = repository
        installer = ExtensionInstaller(repository: repository)
        let permissionManager = ExtensionPermissionManager()
        permissions = permissionManager
        matchCache = ExtensionMatchCache()
        let localStorage = ExtensionLocalStorage(repository: repository)
        storage = localStorage
        let registry = ExtensionAPIRegistry(
            storage: localStorage,
            permissions: permissionManager
        )
        apiRegistry = registry
        actionCoordinator = ExtensionActionCoordinator(
            repository: repository,
            permissions: permissionManager,
            registry: registry
        )
        super.init()
        apiRegistry.scriptExecutor = self
        apiRegistry.suspendRuntime()
        repositoryObserver = NotificationCenter.default.addObserver(
            forName: ExtensionRepository.didChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in await self?.reload() }
        }
        Task { @MainActor [weak self] in await self?.reload() }
    }

    deinit {
        if let repositoryObserver { NotificationCenter.default.removeObserver(repositoryObserver) }
    }

    public func activate() {
        BrowserExtensionBridge.shared.integration = self
    }

    public func reload() async {
        requestedReloadGeneration &+= 1
        let generation = requestedReloadGeneration
        apiRegistry.suspendRuntime()
        let previous = reloadTail
        let operation = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            let succeeded = await self.performReload()
            if succeeded, generation == self.requestedReloadGeneration {
                self.apiRegistry.resumeRuntime()
            }
        }
        reloadTail = operation
        await operation.value
    }

    private func performReload() async -> Bool {
        do {
            let installed = try await repository.installedExtensions()
            let nextPermissionFingerprints = Dictionary(uniqueKeysWithValues: installed.map { item in
                let fingerprint = ([item.metadata.isEnabled ? "enabled" : "disabled"]
                    + item.metadata.grantedPermissions.sorted()
                    + item.metadata.grantedHostPermissions.sorted()).joined(separator: "\u{1F}")
                return (item.id, fingerprint)
            })
            let permissionsChanged = !permissionFingerprints.isEmpty &&
                nextPermissionFingerprints != permissionFingerprints
            permissionFingerprints = nextPermissionFingerprints
            apiRegistry.replaceActionDefaults(with: installed)
            let installedIDs = Set(installed.map(\.id))
            for removedID in registeredPermissionIDs.subtracting(installedIDs) {
                await permissions.unregister(extensionID: removedID)
            }
            registeredPermissionIDs = installedIDs
            await matchCache.removeAll()
            var next: [ExtensionIdentifier: PreparedRuntimeExtension] = [:]
            var preparationErrors: [String] = []
            var sourceBudget = ExtensionPreparedSourceBudget()
            for item in installed {
                do {
                    try await permissions.register(
                        extensionID: item.id,
                        manifest: item.manifest,
                        isEnabled: item.metadata.isEnabled,
                        grantedCapabilities: Set(
                            item.metadata.grantedPermissions.compactMap(ExtensionCapability.init(rawValue:))
                        ),
                        grantedHostPermissions: item.metadata.grantedHostPermissions
                    )
                    try await matchCache.replaceRules(for: item.id, manifest: item.manifest)
                    guard item.metadata.isEnabled else { continue }
                    let scripts = try await ContentScriptSourceBuilder.prepare(
                        installedExtension: item,
                        repository: repository,
                        allowedHostPatterns: Set(item.metadata.grantedHostPermissions)
                    )
                    var extensionSourceBytes = 0
                    for script in scripts {
                        let (nextBytes, overflow) = extensionSourceBytes.addingReportingOverflow(script.source.utf8.count)
                        guard !overflow else {
                            throw ExtensionRuntimeError.contentScriptSourceLimitExceeded(
                                limit: sourceBudget.maximumBytes
                            )
                        }
                        extensionSourceBytes = nextBytes
                    }
                    try sourceBudget.consume(byteCount: extensionSourceBytes, scriptCount: scripts.count)
                    let world = WKContentWorld.world(name: "ExtensionBrowser.Extension.\(item.id.rawValue)")
                    next[item.id] = PreparedRuntimeExtension(
                        installed: item,
                        contentWorld: world,
                        handlerName: "extensionBridge_\(item.id.rawValue)",
                        scripts: scripts
                    )
                } catch {
                    await permissions.unregister(extensionID: item.id)
                    await matchCache.removeRules(for: item.id)
                    preparationErrors.append(
                        "\(item.metadata.name): \(SafeInput.userFacingError(error))"
                    )
                }
            }
            prepared = next
            lastRuntimeError = preparationErrors.last
            refreshTrackedControllers()
            for (tabID, weakWebView) in webViews {
                guard let webView = weakWebView.value else { continue }
                if permissionsChanged {
                    webView.reload()
                    continue
                }
                injectDynamically(
                    runAt: [.documentStart, .documentEnd],
                    url: webView.url,
                    webView: webView,
                    tabID: tabID,
                    after: navigationRevocations[tabID]
                )
            }
            return true
        } catch {
            lastRuntimeError = SafeInput.userFacingError(error)
            prepared.removeAll(keepingCapacity: false)
            permissionFingerprints.removeAll(keepingCapacity: false)
            apiRegistry.replaceActionDefaults(with: [])
            idleScheduler.cancelAll()
            await matchCache.removeAll()
            for extensionID in registeredPermissionIDs {
                await permissions.unregister(extensionID: extensionID)
            }
            registeredPermissionIDs.removeAll(keepingCapacity: false)
            refreshTrackedControllers()
            compactWeakReferences()
            for weakWebView in webViews.values {
                weakWebView.value?.reload()
            }
            return false
        }
    }

    func configure(userContentController: WKUserContentController, context: BrowserExtensionTabContext) {
        guard !context.isPrivate else { return }
        let record = ControllerRecord(controller: userContentController, context: context)
        controllers[ObjectIdentifier(userContentController)] = record
        installPreparedExtensions(into: record)
        compactWeakReferences()
    }

    func navigationDidCommit(url: URL?, in webView: WKWebView, context: BrowserExtensionTabContext) {
        guard !context.isPrivate else { return }
        idleScheduler.cancel(tabID: context.tabID)
        webViews[context.tabID] = WeakWebView(webView)
        let revocation = Task { [permissions] in
            await permissions.revokeActiveTabGrant(tabID: context.tabID)
        }
        navigationRevocations[context.tabID] = revocation
        injectDynamically(
            runAt: [.documentStart],
            url: url,
            webView: webView,
            tabID: context.tabID,
            after: revocation
        )
    }

    func navigationDidFinish(url: URL?, in webView: WKWebView, context: BrowserExtensionTabContext) {
        guard !context.isPrivate else { return }
        webViews[context.tabID] = WeakWebView(webView)
        injectDynamically(
            runAt: [.documentEnd],
            url: url,
            webView: webView,
            tabID: context.tabID,
            after: navigationRevocations[context.tabID]
        )
        let expectedURL = url
        idleScheduler.schedule(tabID: context.tabID) { @MainActor [weak self, weak webView] in
            guard let self, let webView,
                  self.webViews[context.tabID]?.value === webView,
                  webView.url == expectedURL else { return }
            self.injectDynamically(
                runAt: [.documentIdle],
                url: expectedURL,
                webView: webView,
                tabID: context.tabID,
                after: self.navigationRevocations[context.tabID]
            )
        }
    }

    func navigationDidFail(url: URL?, error: Error, context: BrowserExtensionTabContext) {
        guard !context.isPrivate else { return }
        lastRuntimeError = SafeInput.userFacingError(error)
        idleScheduler.cancel(tabID: context.tabID)
        let revocation = Task { [permissions] in
            await permissions.revokeActiveTabGrant(tabID: context.tabID)
        }
        navigationRevocations[context.tabID] = revocation
    }

    func availableActions(
        for tab: BrowserTabDescriptor
    ) async -> [BrowserExtensionActionDescriptor] {
        do {
            return try await actionCoordinator.availableActions(
                for: tab,
                enabledExtensionIDs: Set(prepared.keys)
            )
        } catch {
            lastRuntimeError = SafeInput.userFacingError(error)
            return []
        }
    }

    func invokeAction(
        extensionID rawExtensionID: String,
        for tab: BrowserTabDescriptor
    ) async throws -> BrowserExtensionActionInvocation {
        guard let extensionID = ExtensionIdentifier(rawValue: rawExtensionID) else {
            throw ExtensionRuntimeError.invalidArguments("invalid extension action identifier")
        }
        guard prepared[extensionID] != nil else {
            throw ExtensionRuntimeError.extensionDisabled(rawExtensionID)
        }
        if let revocation = navigationRevocations[tab.id] {
            await revocation.value
        }
        return try await actionCoordinator.invokeAction(extensionID: extensionID, for: tab)
    }

    func extensionTabDidClose(id: UUID) {
        navigationRevocations.removeValue(forKey: id)?.cancel()
        idleScheduler.cancel(tabID: id)
        webViews.removeValue(forKey: id)
        apiRegistry.removeActionState(forTabID: id)
        Task { [permissions] in
            await permissions.revokeActiveTabGrant(tabID: id)
        }
    }

    var debugInformation: [String: String] {
        [
            "Extensions enabled": "\(prepared.count)",
            "Extension APIs": "\(apiRegistry.registeredAPIs.count)",
            "Extension injections": "\(injectedScriptCount)",
            "Extension error": lastRuntimeError ?? "None"
        ]
    }

    public func executeScript(
        _ source: String,
        inTab tabID: UUID?,
        extensionID: ExtensionIdentifier
    ) async throws -> JSONValue {
        guard let runtimeExtension = prepared[extensionID] else {
            throw ExtensionRuntimeError.extensionDisabled(extensionID.rawValue)
        }
        let activeCount = activeScriptExecutions[extensionID, default: 0]
        guard activeCount < 2 else {
            throw ExtensionRuntimeError.resourceLimitExceeded("too many parallel script executions")
        }
        try Task.checkCancellation()
        activeScriptExecutions[extensionID] = activeCount + 1
        defer {
            activeScriptExecutions[extensionID] = max(0, activeScriptExecutions[extensionID, default: 1] - 1)
        }
        let targetID = tabID ?? BrowserExtensionBridge.shared.browserHost?.extensionActiveTab?.id
        guard let targetID else { throw ExtensionRuntimeError.unavailable("target tab is not live") }
        if let revocation = navigationRevocations[targetID] {
            await revocation.value
        }

        // Resource expansion can suspend. Do it before authorizing the live document so a
        // navigation cannot turn an earlier host grant into execution in a later document.
        let expanded = try await expandResourceMarkers(in: source, extensionID: extensionID)
        try Task.checkCancellation()
        if let revocation = navigationRevocations[targetID] {
            await revocation.value
        }
        guard let webView = webViews[targetID]?.value,
              let authorizedURL = webView.url else {
            throw ExtensionRuntimeError.unavailable("target tab is not live")
        }
        try await permissions.authorizeHost(
            authorizedURL,
            tabID: targetID,
            extensionID: extensionID
        )
        try Task.checkCancellation()
        guard webViews[targetID]?.value === webView, webView.url == authorizedURL else {
            throw ExtensionRuntimeError.unavailable("target tab navigated during script authorization")
        }

        // The in-document check closes the remaining gap between native authorization and
        // WebKit evaluating the source. It also preserves the completion value via eval.
        let guardedSource = Self.navigationBoundSource(expanded, expectedURL: authorizedURL)
        do {
            let result = try await webView.evaluateJavaScript(
                guardedSource,
                in: nil,
                contentWorld: runtimeExtension.contentWorld
            )
            guard let result else { return .null }
            return try ExtensionPayloadValidator.convertIncoming(
                result,
                maximumBytes: ExtensionResourceLimits.standard.maximumScriptResultBytes
            )
        } catch {
            throw ExtensionRuntimeError.javascriptEvaluationFailed(
                SafeInput.userFacingError(error, fallback: "JavaScript evaluation failed")
            )
        }
    }

    private func installPreparedExtensions(into record: ControllerRecord) {
        guard let controller = record.controller else { return }
        var scriptGroups: [String: [WKUserScript]] = [:]
        for runtimeExtension in prepared.values.sorted(by: { $0.installed.id.rawValue < $1.installed.id.rawValue }) {
            let handler = ExtensionScriptMessageHandler(
                extensionID: runtimeExtension.installed.id,
                tabID: record.context.tabID,
                registry: apiRegistry
            )
            controller.addScriptMessageHandler(
                handler,
                contentWorld: runtimeExtension.contentWorld,
                name: runtimeExtension.handlerName
            )
            record.handlerExtensionIDs.insert(runtimeExtension.installed.id)
            var scripts = [WKUserScript(
                source: ChromeBridgeJavaScript.source(
                    messageHandlerName: runtimeExtension.handlerName,
                    extensionID: runtimeExtension.installed.id
                ),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: runtimeExtension.contentWorld
            )]
            scripts.append(contentsOf: runtimeExtension.scripts
                .filter { $0.rule.runAt != .documentIdle }
                .map(\.userScript))
            scriptGroups[runtimeExtension.installed.id.rawValue] = scripts
        }
        record.scriptRegistry.replaceExtensionScripts(scriptGroups)
    }

    private func refreshTrackedControllers() {
        compactWeakReferences()
        for record in controllers.values {
            guard let controller = record.controller else { continue }
            for extensionID in record.handlerExtensionIDs {
                let world = WKContentWorld.world(name: "ExtensionBrowser.Extension.\(extensionID.rawValue)")
                controller.removeScriptMessageHandler(
                    forName: "extensionBridge_\(extensionID.rawValue)",
                    contentWorld: world
                )
            }
            record.handlerExtensionIDs.removeAll()
            installPreparedExtensions(into: record)
        }
    }

    private func injectDynamically(
        runAt: Set<WebExtensionManifest.RunAt>,
        url: URL?,
        webView: WKWebView,
        tabID: UUID,
        after revocation: Task<Void, Never>?
    ) {
        guard let url else { return }
        for runtimeExtension in prepared.values {
            for script in runtimeExtension.scripts where runAt.contains(script.rule.runAt) && script.rule.matches(url) {
                Task { @MainActor [weak self, weak webView] in
                    guard let self, let webView else { return }
                    await revocation?.value
                    guard self.webViews[tabID]?.value === webView,
                          webView.url == url else { return }
                    guard await self.permissions.canInject(
                        into: url,
                        tabID: tabID,
                        extensionID: runtimeExtension.installed.id
                    ) else { return }
                    do {
                        _ = try await webView.evaluateJavaScript(
                            script.source,
                            in: nil,
                            contentWorld: runtimeExtension.contentWorld
                        )
                        self.injectedScriptCount += 1
                    } catch {
                        self.lastRuntimeError = SafeInput.userFacingError(error)
                    }
                }
            }
        }
    }

    private func expandResourceMarkers(in source: String, extensionID: ExtensionIdentifier) async throws -> String {
        let prefix = "/*__EXTENSION_FILE__:"
        let suffix = "*/"
        let lines = source.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        guard !lines.isEmpty, lines.allSatisfy({ $0.hasPrefix(prefix) && $0.hasSuffix(suffix) }) else { return source }
        let limits = ExtensionResourceLimits.standard
        guard lines.count <= limits.maximumScriptFileCount else {
            throw ExtensionRuntimeError.resourceLimitExceeded("too many script files")
        }
        var aggregateBytes = 0
        var result = ""
        for (index, line) in lines.enumerated() {
            let path = String(line.dropFirst(prefix.count).dropLast(suffix.count))
            let normalizedPath = try ExtensionResourcePath.normalize(path)
            let data = try await repository.resourceData(
                extensionID: extensionID,
                path: normalizedPath,
                maximumBytes: limits.maximumScriptFileBytes
            )
            let (nextSize, overflow) = aggregateBytes.addingReportingOverflow(data.count)
            guard !overflow, nextSize <= limits.maximumAggregateScriptBytes else {
                throw ExtensionRuntimeError.resourceLimitExceeded("aggregate script source is too large")
            }
            aggregateBytes = nextSize
            guard let script = String(data: data, encoding: .utf8) else {
                throw ExtensionRuntimeError.invalidResourceEncoding(path)
            }
            if index > 0 { result.append("\n;\n") }
            result.append(script)
        }
        return result
    }

    private func compactWeakReferences() {
        controllers = controllers.filter { $0.value.controller != nil }
        webViews = webViews.filter { $0.value.value != nil }
    }

    private static func navigationBoundSource(_ source: String, expectedURL: URL) -> String {
        let expected = javaScriptString(expectedURL.absoluteString)
        let script = javaScriptString(source)
        return """
        (() => {
          if (globalThis.location?.href !== \(expected)) {
            throw new Error('Target document changed before script execution');
          }
          return globalThis.eval(\(script));
        })()
        """
    }

    private static func javaScriptString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [value]),
              let encoded = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return String(encoded.dropFirst().dropLast())
    }
}
