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
        var handlerExtensionIDs: Set<ExtensionIdentifier> = []

        init(controller: WKUserContentController, context: BrowserExtensionTabContext) {
            self.controller = controller
            self.context = context
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
    private var registeredPermissionIDs: Set<ExtensionIdentifier> = []
    private var repositoryObserver: NSObjectProtocol?
    private var lastRuntimeError: String?
    private var injectedScriptCount = 0

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
        do {
            let installed = try await repository.installedExtensions()
            apiRegistry.replaceActionDefaults(with: installed)
            let installedIDs = Set(installed.map(\.id))
            for removedID in registeredPermissionIDs.subtracting(installedIDs) {
                await permissions.unregister(extensionID: removedID)
            }
            registeredPermissionIDs = installedIDs
            await matchCache.removeAll()
            var next: [ExtensionIdentifier: PreparedRuntimeExtension] = [:]
            var preparationErrors: [String] = []
            for item in installed {
                do {
                    try await permissions.register(
                        extensionID: item.id,
                        manifest: item.manifest,
                        isEnabled: item.metadata.isEnabled
                    )
                    try await matchCache.replaceRules(for: item.id, manifest: item.manifest)
                    guard item.metadata.isEnabled else { continue }
                    let scripts = try await ContentScriptSourceBuilder.prepare(
                        installedExtension: item,
                        repository: repository
                    )
                    let world = WKContentWorld.world(name: "ExtensionBrowser.Extension.\(item.id.rawValue)")
                    next[item.id] = PreparedRuntimeExtension(
                        installed: item,
                        contentWorld: world,
                        handlerName: "extensionBridge_\(item.id.rawValue)",
                        scripts: scripts
                    )
                } catch {
                    preparationErrors.append("\(item.metadata.name): \(error.localizedDescription)")
                }
            }
            prepared = next
            lastRuntimeError = preparationErrors.last
            refreshTrackedControllers()
            for (tabID, weakWebView) in webViews {
                guard let webView = weakWebView.value else { continue }
                injectDynamically(
                    runAt: [.documentStart, .documentEnd, .documentIdle],
                    url: webView.url,
                    webView: webView,
                    tabID: tabID,
                    after: navigationRevocations[tabID]
                )
            }
        } catch {
            lastRuntimeError = error.localizedDescription
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
            runAt: [.documentEnd, .documentIdle],
            url: url,
            webView: webView,
            tabID: context.tabID,
            after: navigationRevocations[context.tabID]
        )
    }

    func navigationDidFail(url: URL?, error: Error, context: BrowserExtensionTabContext) {
        lastRuntimeError = error.localizedDescription
        guard !context.isPrivate else { return }
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
            lastRuntimeError = error.localizedDescription
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
        let targetID = tabID ?? BrowserExtensionBridge.shared.browserHost?.extensionActiveTab?.id
        guard let targetID else { throw ExtensionRuntimeError.unavailable("target tab is not live") }
        if let revocation = navigationRevocations[targetID] {
            await revocation.value
        }

        // Resource expansion can suspend. Do it before authorizing the live document so a
        // navigation cannot turn an earlier host grant into execution in a later document.
        let expanded = try await expandResourceMarkers(in: source, extensionID: extensionID)
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
            return result.flatMap(JSONValue.init(foundationValue:)) ?? .null
        } catch {
            throw ExtensionRuntimeError.javascriptEvaluationFailed(error.localizedDescription)
        }
    }

    private func installPreparedExtensions(into record: ControllerRecord) {
        guard let controller = record.controller else { return }
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
            controller.addUserScript(WKUserScript(
                source: ChromeBridgeJavaScript.source(
                    messageHandlerName: runtimeExtension.handlerName,
                    extensionID: runtimeExtension.installed.id
                ),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false,
                in: runtimeExtension.contentWorld
            ))
            runtimeExtension.scripts.forEach { controller.addUserScript($0.userScript) }
        }
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
            controller.removeAllUserScripts()
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
                        self.lastRuntimeError = error.localizedDescription
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
        var resources: [String] = []
        for line in lines {
            let path = String(line.dropFirst(prefix.count).dropLast(suffix.count))
            let data = try await repository.resourceData(extensionID: extensionID, path: path)
            guard let script = String(data: data, encoding: .utf8) else {
                throw ExtensionRuntimeError.invalidResourceEncoding(path)
            }
            resources.append(script)
        }
        return resources.joined(separator: "\n;\n")
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
