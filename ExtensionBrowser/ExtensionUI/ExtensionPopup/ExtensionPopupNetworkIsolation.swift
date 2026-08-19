import Foundation

enum ExtensionPopupNetworkIsolation {
    static let blockedSchemesRuleList = #"""
    [
      {"trigger":{"url-filter":"^https?://"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^wss?://"},"action":{"type":"block"}},
      {"trigger":{"url-filter":"^ftp://"},"action":{"type":"block"}}
    ]
    """#

    /// Content rules do not provide a reliable WebSocket boundary on every supported WebKit
    /// release. Install non-configurable network API stubs before extension page code as a
    /// second, independently testable layer.
    static let javaScript = #"""
    (() => {
      const deny = () => Promise.reject(new TypeError('Extension popup network access is disabled'));
      const DeniedConstructor = class {
        constructor() { throw new TypeError('Extension popup network access is disabled'); }
      };
      const lock = (name, value) => {
        try { Object.defineProperty(globalThis, name, { value, writable: false, configurable: false }); }
        catch (_) { try { globalThis[name] = value; } catch (_) {} }
      };
      lock('fetch', deny);
      lock('XMLHttpRequest', DeniedConstructor);
      lock('WebSocket', DeniedConstructor);
      lock('EventSource', DeniedConstructor);
      lock('Worker', DeniedConstructor);
      lock('SharedWorker', DeniedConstructor);
      if (globalThis.navigator) {
        try {
          Object.defineProperty(globalThis.navigator, 'sendBeacon', {
            value: () => false, writable: false, configurable: false
          });
        } catch (_) {}
      }
    })();
    """#
}
