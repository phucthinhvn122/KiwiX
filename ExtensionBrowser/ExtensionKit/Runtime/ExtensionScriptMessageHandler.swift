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
        let request: ExtensionDecodedRequest
        do {
            request = try ExtensionMessageCodec.decodeRequest(message.body)
        } catch {
            replyHandler(nil, SafeInput.userFacingError(error))
            return
        }
        let context = ExtensionAPIContext(
            extensionID: extensionID,
            tabID: tabID,
            pageURL: message.frameInfo.request.url
        )
        Task { @MainActor [registry] in
            do {
                let result = try await registry.handle(
                    api: request.api,
                    arguments: request.arguments,
                    context: context
                )
                replyHandler(try ExtensionMessageCodec.encodeResponse(result), nil)
            } catch {
                replyHandler(nil, SafeInput.userFacingError(error))
            }
        }
    }
}
