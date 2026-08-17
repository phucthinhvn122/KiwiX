(() => {
  "use strict";

  const badgeID = "extensionbrowser-hello-badge";
  if (document.getElementById(badgeID)) {
    return;
  }

  const badge = document.createElement("div");
  badge.id = badgeID;
  badge.setAttribute("role", "status");
  badge.setAttribute("aria-live", "polite");
  badge.textContent = "🧩 Hello from ExtensionBrowser";

  const parent = document.body || document.documentElement;
  parent.appendChild(badge);

  requestAnimationFrame(() => {
    badge.classList.add("extensionbrowser-hello-visible");
  });

  window.setTimeout(() => {
    badge.classList.remove("extensionbrowser-hello-visible");
    window.setTimeout(() => badge.remove(), 200);
  }, 3000);

  console.info("Hello from ExtensionBrowser extension runtime");

  // Exercise the compatibility bridge when it is available. The example still
  // works in an ordinary browser, which makes the package easy to inspect.
  if (globalThis.chrome?.storage?.local) {
    try {
      const storageResult = globalThis.chrome.storage.local.set({
        lastHelloURL: location.href,
      });
      storageResult?.catch?.((error) => {
        console.debug("Hello Extension storage is unavailable", error);
      });
    } catch (error) {
      console.debug("Hello Extension storage is unavailable", error);
    }
  }

  if (globalThis.chrome?.runtime?.sendMessage) {
    try {
      const messageResult = globalThis.chrome.runtime.sendMessage({
        type: "hello",
        url: location.href,
      });
      messageResult?.catch?.((error) => {
        console.debug("Hello Extension has no message listener", error);
      });
    } catch (error) {
      console.debug("Hello Extension messaging is unavailable", error);
    }
  }
})();
