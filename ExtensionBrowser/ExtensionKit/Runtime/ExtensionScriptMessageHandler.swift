import Foundation
import WebKit

@MainActor
public final class ExtensionScriptMessageHandler: NSObject, WKScriptMessageHandlerWithReply {
    public let extensionID: ExtensionIdentifier
    public let tabID: UUID
    private let registry: ExtensionAPIRegistry

    public init(extensionID: ExtensionIdentifier, tabID: UUID, registry: ExtensionAPIRegistry) {
        self.extensionID = extensionID
        self.tabID = tabID
        self.registry = registry
    }

    public func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage,
        replyHandler: @escaping (Any?, String?) -> Void
    ) {
        guard let request = JSONValue(foundationValue: message.body)?.objectValue,
              let api = request["api"]?.stringValue else {
            replyHandler(nil, ExtensionRuntimeError.invalidArguments("missing API name").localizedDescription)
            return
        }
        let arguments = request["args"] ?? .null
        let context = ExtensionAPIContext(
            extensionID: extensionID,
            tabID: tabID,
            pageURL: message.frameInfo.request.url
        )
        Task { @MainActor [registry] in
            do {
                let result = try await registry.handle(api: api, arguments: arguments, context: context)
                replyHandler(result.foundationValue, nil)
            } catch {
                replyHandler(nil, error.localizedDescription)
            }
        }
    }
}
