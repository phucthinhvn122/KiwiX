import Foundation

public enum ChromeBridgeJavaScript {
    public static func source(messageHandlerName: String, extensionID: ExtensionIdentifier) -> String {
        let handler = javaScriptString(messageHandlerName)
        let identifier = javaScriptString(extensionID.rawValue)
        return """
        (() => {
          if (globalThis.__extensionBrowserBridgeInstalled) return;
          Object.defineProperty(globalThis, '__extensionBrowserBridgeInstalled', { value: true });
          const handlerName = \(handler);
          const extensionId = \(identifier);
          const listeners = [];
          const call = (api, args = null) => {
            const target = globalThis.webkit?.messageHandlers?.[handlerName];
            if (!target) return Promise.reject(new Error('Extension bridge unavailable'));
            return target.postMessage({ api, args });
          };
          const runtime = {
            id: extensionId,
            sendMessage: async (message) => {
              const nativeResult = await call('runtime.sendMessage', message);
              for (const listener of [...listeners]) {
                const response = await listener(message, { id: extensionId }, () => {});
                if (response !== undefined) return response;
              }
              return nativeResult;
            },
            onMessage: {
              addListener(listener) { if (typeof listener === 'function') listeners.push(listener); },
              removeListener(listener) { const i = listeners.indexOf(listener); if (i >= 0) listeners.splice(i, 1); },
              hasListener(listener) { return listeners.includes(listener); }
            }
          };
          const storage = {
            local: {
              get: (keys = null) => call('storage.local.get', keys),
              set: (items) => call('storage.local.set', items),
              remove: (keys) => call('storage.local.remove', keys),
              clear: () => call('storage.local.clear', null)
            }
          };
          const tabs = {
            query: (queryInfo = {}) => call('tabs.query', queryInfo),
            create: (createProperties = {}) => call('tabs.create', createProperties)
          };
          const scripting = {
            executeScript: (details) => {
              const safe = { target: details?.target ?? {}, files: details?.files ?? null };
              if (typeof details?.func === 'function') {
                const args = JSON.stringify(details.args ?? []);
                safe.code = `(${details.func.toString()})(...${args})`;
              }
              return call('scripting.executeScript', safe);
            }
          };
          const action = {
            getTitle: (details = {}) => call('action.getTitle', details),
            setTitle: (details) => call('action.setTitle', details)
          };
          Object.defineProperty(globalThis, 'chrome', {
            value: Object.freeze({ runtime, storage, tabs, scripting, action }),
            configurable: false,
            writable: false
          });
        })();
        """
    }

    private static func javaScriptString(_ value: String) -> String {
        let data = try? JSONSerialization.data(withJSONObject: [value])
        let encoded = data.flatMap { String(data: $0, encoding: .utf8) } ?? "[\"\"]"
        return String(encoded.dropFirst().dropLast())
    }
}
