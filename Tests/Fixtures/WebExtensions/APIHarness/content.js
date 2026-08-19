// Content script probe. Its only job is to prove that injection happened on a page the browser
// loaded through the tab adapter, and to report what the page context can see.
(() => {
  const api = globalThis.browser ?? globalThis.chrome;
  if (!api || !api.runtime || typeof api.runtime.sendMessage !== "function") {
    return;
  }
  const marker = document.createElement("div");
  marker.id = "kiwix-harness-content-marker";
  marker.style.display = "none";
  document.documentElement.appendChild(marker);

  api.runtime.sendMessage({
    type: "contentPing",
    href: location.href,
    title: document.title,
    hasRuntimeId: typeof api.runtime.id === "string",
    canGetURL: typeof api.runtime.getURL === "function",
    injectedMarker: document.getElementById("kiwix-harness-content-marker") !== null
  });
})();
