(() => {
  "use strict";

  const urlLabel = document.getElementById("last-url");
  const statusLabel = document.getElementById("status");
  const clearButton = document.getElementById("clear");

  async function refresh() {
    try {
      const values = await chrome.storage.local.get(["lastHelloURL"]);
      urlLabel.textContent = values.lastHelloURL || "No page has been recorded yet.";
      statusLabel.textContent = "";
    } catch (error) {
      urlLabel.textContent = "Storage is unavailable.";
      statusLabel.textContent = String(error?.message || error);
    }
  }

  clearButton.addEventListener("click", async () => {
    try {
      await chrome.storage.local.remove(["lastHelloURL"]);
      statusLabel.textContent = "Saved URL cleared.";
      await refresh();
    } catch (error) {
      statusLabel.textContent = String(error?.message || error);
    }
  });

  refresh();
})();
