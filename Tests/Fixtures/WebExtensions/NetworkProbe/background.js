// Enforcement probe for M3.
//
// The measurement lives on the Swift side: a real loopback server records which paths it was
// asked for. This script only has to (a) install a dynamic rule so both rule kinds are covered,
// and (b) say when it is ready, so the test never navigates before the rules exist. Anything this
// script *claims* about blocking is not evidence — the server's log is.
(() => {
  const api = typeof browser !== "undefined" ? browser : chrome;
  const NATIVE_APPLICATION = "com.phucthinhvn122.KiwiX.harness";

  // The host treats any dictionary carrying `handshake: true` as an extension->host signal, so
  // this reuses the transport M2 already proved works instead of inventing a second one.
  function signal(payload) {
    try {
      api.runtime.sendNativeMessage(NATIVE_APPLICATION, Object.assign({ handshake: true }, payload));
    } catch (error) {
      // No fallback exists. The Swift side times out and reports the silence, which is the
      // honest outcome.
    }
  }

  let webRequestStatus = "unsupported";
  try {
    api.webRequest.onBeforeRequest.addListener(
      (details) => {
        // Observation, not blocking: this reports what the listener actually saw so the matrix
        // can stop guessing from feature detection alone.
        signal({ phase: "webRequest", url: String(details.url) });
      },
      { urls: ["<all_urls>"] }
    );
    webRequestStatus = "registered";
  } catch (error) {
    webRequestStatus = "failed: " + String(error);
  }

  (async () => {
    let dynamicStatus = "not-attempted";
    try {
      await api.declarativeNetRequest.updateDynamicRules({
        removeRuleIds: [1001],
        addRules: [
          {
            id: 1001,
            priority: 1,
            action: { type: "block" },
            condition: {
              urlFilter: "blocked-dynamic.js",
              resourceTypes: ["script", "image", "xmlhttprequest", "sub_frame"]
            }
          }
        ]
      });
      const active = await api.declarativeNetRequest.getDynamicRules();
      dynamicStatus = "installed:" + active.length;
    } catch (error) {
      dynamicStatus = "failed: " + String(error);
    }

    let staticStatus = "unknown";
    try {
      const rulesets = await api.declarativeNetRequest.getEnabledRulesets();
      staticStatus = rulesets.join(",") || "none";
    } catch (error) {
      staticStatus = "failed: " + String(error);
    }

    signal({
      phase: "ready",
      dynamicRules: dynamicStatus,
      enabledRulesets: staticStatus,
      webRequest: webRequestStatus
    });
  })();
})();
