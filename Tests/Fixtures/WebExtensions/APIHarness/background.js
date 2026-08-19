// Runs the probe suite once the background context starts, then ships the report to the app.
//
// Two transports are attempted, in order: native messaging, then a chunked tabs.create beacon.
// Whichever one lands is itself recorded as a probe, because whether an extension can talk to the
// app at all is one of the things M2 has to answer.

(() => {
  const H = globalThis.KiwiXHarness;
  const api = H.api;

  const NATIVE_APP_ID = "com.phucthinhvn122.KiwiX.harness";
  const BEACON_HOST = "kiwix-harness.invalid";
  const HARNESS_PAGE = "https://harness.kiwix.test/page.html";
  const CHUNK_SIZE = 1200;

  const events = {
    tabsOnCreated: false,
    tabsOnUpdated: false,
    tabsOnActivated: false,
    tabsOnRemoved: false,
    tabsOnMoved: false,
    windowsOnFocusChanged: false,
    runtimeOnMessage: false
  };

  const contentPing = H.deferred();

  function listen(namespace, event, flag) {
    try {
      const target = api[namespace] && api[namespace][event];
      if (!target || typeof target.addListener !== "function") return false;
      target.addListener(() => {
        events[flag] = true;
      });
      return true;
    } catch (error) {
      return false;
    }
  }

  function recordListener(id, namespace, event, flag) {
    H.record(id, "events", listen(namespace, event, flag) ? "pass" : "unsupported", "registration");
  }

  function installListeners() {
    recordListener("tabs.onCreated.addListener", "tabs", "onCreated", "tabsOnCreated");
    recordListener("tabs.onUpdated.addListener", "tabs", "onUpdated", "tabsOnUpdated");
    recordListener("tabs.onActivated.addListener", "tabs", "onActivated", "tabsOnActivated");
    recordListener("tabs.onRemoved.addListener", "tabs", "onRemoved", "tabsOnRemoved");
    recordListener("tabs.onMoved.addListener", "tabs", "onMoved", "tabsOnMoved");
    recordListener("windows.onFocusChanged.addListener", "windows", "onFocusChanged", "windowsOnFocusChanged");

    try {
      api.runtime.onMessage.addListener((message) => {
        events.runtimeOnMessage = true;
        if (message && message.type === "contentPing") {
          contentPing.resolve(message);
        }
        return false;
      });
      H.record("runtime.onMessage.addListener", "events", "pass", "registration");
    } catch (error) {
      H.record("runtime.onMessage.addListener", "events", "fail", error.message);
    }
  }

  function namespaceProbes() {
    const namespaces = [
      ["runtime", "core"],
      ["storage", "storage"],
      ["storage.session", "storage"],
      ["storage.sync", "storage"],
      ["storage.managed", "storage"],
      ["tabs", "tabs"],
      ["windows", "tabs"],
      ["scripting", "scripting"],
      ["userScripts", "scripting"],
      ["declarativeNetRequest", "network"],
      ["webRequest", "network"],
      ["webRequest.filterResponseData", "network"],
      ["webNavigation", "network"],
      ["cookies", "network"],
      ["proxy", "network"],
      ["debugger", "platform"],
      ["dns", "network"],
      ["action", "ui"],
      ["contextMenus", "ui"],
      ["menus", "ui"],
      ["notifications", "ui"],
      ["omnibox", "ui"],
      ["sidePanel", "ui"],
      ["sidebarAction", "ui"],
      ["devtools", "ui"],
      ["commands", "ui"],
      ["permissions", "permissions"],
      ["alarms", "platform"],
      ["i18n", "platform"],
      ["idle", "platform"],
      ["management", "platform"],
      ["offscreen", "platform"],
      ["identity", "platform"],
      ["privacy", "platform"],
      ["bookmarks", "data"],
      ["history", "data"],
      ["downloads", "data"],
      ["browsingData", "data"],
      ["topSites", "data"],
      ["sessions", "data"],
      ["search", "data"]
    ];
    for (const entry of namespaces) {
      H.existence(entry[0], entry[1], entry[0]);
    }
  }

  async function coreProbes() {
    await H.run("runtime.getManifest", "core", () => api.runtime.getManifest().manifest_version);
    await H.run("runtime.id", "core", () => {
      if (typeof api.runtime.id !== "string" || api.runtime.id.length === 0) {
        throw new Error("runtime.id is empty");
      }
      return api.runtime.id;
    });
    await H.run("runtime.getURL", "core", () => api.runtime.getURL("manifest.json"));
    await H.run("runtime.getPlatformInfo", "core", async () => await api.runtime.getPlatformInfo());
    await H.run("i18n.getUILanguage", "platform", () => api.i18n.getUILanguage());
  }

  async function storageProbes() {
    await H.run("storage.local.roundTrip", "storage", async () => {
      await api.storage.local.set({ harnessKey: "harnessValue" });
      const read = await api.storage.local.get("harnessKey");
      if (read.harnessKey !== "harnessValue") throw new Error("value did not round-trip");
      await api.storage.local.remove("harnessKey");
      return "ok";
    });
    await H.run("storage.session.roundTrip", "storage", async () => {
      await api.storage.session.set({ sessionKey: 1 });
      const read = await api.storage.session.get("sessionKey");
      if (read.sessionKey !== 1) throw new Error("value did not round-trip");
      await api.storage.session.remove("sessionKey");
      return "ok";
    });
    await H.run("storage.sync.roundTrip", "storage", async () => {
      await api.storage.sync.set({ syncKey: 1 });
      const read = await api.storage.sync.get("syncKey");
      if (read.syncKey !== 1) throw new Error("value did not round-trip");
      await api.storage.sync.remove("syncKey");
      return "ok";
    });
  }

  async function permissionProbes() {
    await H.run("permissions.getAll", "permissions", async () => {
      const all = await api.permissions.getAll();
      return "permissions=" + (all.permissions || []).length + " origins=" + (all.origins || []).length;
    });
    await H.run("permissions.contains.allUrls", "permissions", async () =>
      String(await api.permissions.contains({ origins: ["<all_urls>"] }))
    );
  }

  async function networkProbes() {
    await H.run("declarativeNetRequest.getEnabledRulesets", "network", async () => {
      const rulesets = await api.declarativeNetRequest.getEnabledRulesets();
      return rulesets.join(",") || "(none)";
    });
    await H.run("declarativeNetRequest.dynamicRules", "network", async () => {
      await api.declarativeNetRequest.updateDynamicRules({
        addRules: [
          {
            id: 1001,
            priority: 1,
            action: { type: "block" },
            condition: { urlFilter: "||dynamic.kiwix.test", resourceTypes: ["script"] }
          }
        ]
      });
      const rules = await api.declarativeNetRequest.getDynamicRules();
      await api.declarativeNetRequest.updateDynamicRules({ removeRuleIds: [1001] });
      return "count=" + rules.length;
    });
    await H.run("declarativeNetRequest.getAvailableStaticRuleCount", "network", async () =>
      String(await api.declarativeNetRequest.getAvailableStaticRuleCount())
    );
    await H.run("cookies.getAll", "network", async () => {
      const cookies = await api.cookies.getAll({});
      return "count=" + cookies.length;
    });
    // Registration succeeding is not observation. Nothing here drives a request past the
    // listener, so this can only ever be "available" (DECISIONS 4.2.5); real observation is a
    // separate probe once a controlled test server exists.
    H.record(
      "webRequest.onBeforeRequest.register",
      "network",
      typeof (api.webRequest && api.webRequest.onBeforeRequest && api.webRequest.onBeforeRequest.addListener) ===
        "function"
        ? "available"
        : "unsupported",
      "listener registration only, no traffic observed"
    );
    await H.run("webRequest.blocking.accepted", "network", () => {
      const noop = () => undefined;
      try {
        api.webRequest.onBeforeRequest.addListener(noop, { urls: ["https://blocked.kiwix.test/*"] }, [
          "blocking"
        ]);
      } finally {
        try {
          api.webRequest.onBeforeRequest.removeListener(noop);
        } catch (error) {
          // Nothing to undo if registration never took.
        }
      }
      return "blocking extraInfoSpec accepted";
    });
    // DECISIONS 4.2 requires DNR enforcement to be confirmed by observing a blocked or redirected
    // request through a project-controlled URL. The harness page is served by loadSimulatedRequest
    // and has no subresource origin we own, so a "blocked" result would be indistinguishable from
    // a DNS failure. Deliberately not faked - see M2_REPORT.md.
    H.skip(
      "declarativeNetRequest.enforcement",
      "network",
      "needs a controlled test server to observe a blocked request (M3)"
    );
  }

  async function uiProbes() {
    await H.run("action.setBadgeText", "ui", async () => {
      await api.action.setBadgeText({ text: "42" });
      return "set";
    });
    await H.run("action.setTitle", "ui", async () => {
      await api.action.setTitle({ title: "Harness" });
      return "set";
    });
    await H.run("contextMenus.create", "ui", () => {
      const id = api.contextMenus.create({ id: "harness-item", title: "Harness", contexts: ["page"] });
      return String(id === undefined ? "created" : id);
    });
    await H.run("alarms.create", "platform", async () => {
      await api.alarms.create("harnessAlarm", { periodInMinutes: 1 });
      const all = await api.alarms.getAll();
      await api.alarms.clear("harnessAlarm");
      return "count=" + all.length;
    });
  }

  async function platformProbes() {
    // DECISIONS 4.1 keeps a `notifications` row, so it needs an answer rather than a shrug. On a
    // runtime without the namespace this records `unsupported` and costs nothing.
    await H.run("notifications.create", "ui", async () => {
      const id = await H.withTimeout(
        api.notifications.create({
          type: "basic",
          title: "KiwiX harness",
          message: "probe"
        }),
        3000,
        "notifications.create"
      );
      try {
        await api.notifications.clear(id);
      } catch (error) {
        // Best effort: the row only needs to know whether create works.
      }
      return "id=" + id;
    });
  }

  async function tabProbes() {
    const queryResult = await H.run("tabs.query", "tabs", async () => {
      const tabs = await api.tabs.query({});
      return "count=" + tabs.length;
    });
    if (queryResult === undefined) {
      H.skip("tabs.create", "tabs", "tabs.query unavailable");
      return;
    }

    await H.run("windows.getCurrent", "tabs", async () => {
      const win = await api.windows.getCurrent();
      return "id=" + win.id + " type=" + win.type + " incognito=" + win.incognito;
    });
    await H.run("windows.getAll", "tabs", async () => {
      const windows = await api.windows.getAll();
      return "count=" + windows.length;
    });

    let harnessTab = null;
    await H.run("tabs.create", "tabs", async () => {
      harnessTab = await api.tabs.create({ url: HARNESS_PAGE, active: true });
      if (!harnessTab || typeof harnessTab.id !== "number") throw new Error("no tab id returned");
      return "id=" + harnessTab.id;
    });
    if (!harnessTab) return;

    await H.run("tabs.get", "tabs", async () => {
      const tab = await api.tabs.get(harnessTab.id);
      return "url=" + tab.url + " title=" + tab.title;
    });

    await H.run("contentScript.injection", "scripting", async () => {
      const ping = await H.withTimeout(contentPing.promise, 8000, "content script ping");
      if (!ping || ping.type !== "contentPing") throw new Error("unexpected ping payload");
      return "href=" + ping.href + " runtimeId=" + ping.hasRuntimeId;
    });

    await H.run("scripting.executeScript", "scripting", async () => {
      const results = await api.scripting.executeScript({
        target: { tabId: harnessTab.id },
        func: () => document.getElementById("kiwix-harness-content-marker") !== null
      });
      const first = results && results[0];
      return "result=" + (first ? first.result : "none");
    });

    await H.run("scripting.insertCSS", "scripting", async () => {
      await api.scripting.insertCSS({ target: { tabId: harnessTab.id }, css: "body { --kiwix: 1; }" });
      return "inserted";
    });

    await H.run("webNavigation.getAllFrames", "network", async () => {
      const frames = await api.webNavigation.getAllFrames({ tabId: harnessTab.id });
      return "frames=" + (frames ? frames.length : 0);
    });

    await H.run("tabs.activate", "tabs", async () => {
      // The harness tab was created active, so re-activating it would prove nothing. Switch away
      // first, then back, and require the browser to report the change both times.
      const others = (await api.tabs.query({})).filter((tab) => tab.id !== harnessTab.id);
      if (others.length === 0) throw new Error("no second tab to switch away to");

      // Preserve the shared flag: eventDeliveryProbes still needs to know it ever fired.
      const seenBefore = events.tabsOnActivated;
      events.tabsOnActivated = false;

      await api.tabs.update(others[0].id, { active: true });
      const away = await api.tabs.get(harnessTab.id);
      if (away.active) throw new Error("harness tab stayed active after switching away");

      await api.tabs.update(harnessTab.id, { active: true });
      const back = await api.tabs.get(harnessTab.id);
      if (!back.active) throw new Error("harness tab did not become active again");

      const firedHere = events.tabsOnActivated;
      events.tabsOnActivated = seenBefore || firedHere;
      // Activation working while the event is missing is a different defect from activation not
      // working at all, so the event result rides along in the detail instead of failing here.
      return "switched=away+back onActivated=" + firedHere;
    });

    await H.run("tabs.remove", "tabs", async () => {
      await api.tabs.remove(harnessTab.id);
      return "removed";
    });
  }

  function eventDeliveryProbes() {
    const expected = [
      ["tabs.onCreated.fired", "tabsOnCreated"],
      ["tabs.onUpdated.fired", "tabsOnUpdated"],
      ["tabs.onActivated.fired", "tabsOnActivated"],
      ["tabs.onRemoved.fired", "tabsOnRemoved"],
      ["runtime.onMessage.fired", "runtimeOnMessage"]
    ];
    for (const entry of expected) {
      const observed = events[entry[1]];
      H.record(entry[0], "events", observed ? "pass" : "fail", "observed=" + observed);
    }
    // These two need an action the harness cannot perform, so a miss is not a failure.
    H.record("tabs.onMoved.fired", "events", events.tabsOnMoved ? "pass" : "skipped", "no reorder performed");
    H.record(
      "windows.onFocusChanged.fired",
      "events",
      events.windowsOnFocusChanged ? "pass" : "skipped",
      "single window"
    );
  }

  function toBase64URL(text) {
    const bytes = new TextEncoder().encode(text);
    let binary = "";
    for (let index = 0; index < bytes.length; index += 1) {
      binary += String.fromCharCode(bytes[index]);
    }
    return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
  }

  async function sendViaNativeMessaging(payload) {
    const reply = await H.withTimeout(
      api.runtime.sendNativeMessage(NATIVE_APP_ID, payload),
      5000,
      "sendNativeMessage"
    );
    if (!reply || reply.received !== true) {
      throw new Error("unexpected reply " + JSON.stringify(reply));
    }
    return "delivered";
  }

  async function sendViaBeacon(payload) {
    const encoded = toBase64URL(JSON.stringify(payload));
    const total = Math.ceil(encoded.length / CHUNK_SIZE);
    for (let index = 0; index < total; index += 1) {
      const chunk = encoded.slice(index * CHUNK_SIZE, (index + 1) * CHUNK_SIZE);
      const url = "https://" + BEACON_HOST + "/?i=" + index + "&n=" + total + "&d=" + chunk;
      await api.tabs.create({ url: url, active: false });
    }
    return "chunks=" + total;
  }

  async function deliver() {
    // The handshake decides the transport, and is itself a probe: it is the only way to find out
    // whether sendNativeMessage reaches the controller delegate on this OS build.
    let nativeOk = false;
    try {
      await sendViaNativeMessaging({ handshake: true });
      nativeOk = true;
      H.record("runtime.sendNativeMessage", "transport", "pass", "handshake accepted");
    } catch (error) {
      H.record("runtime.sendNativeMessage", "transport", "unsupported", error.message);
    }
    H.record("tabs.create.beacon", "transport", nativeOk ? "skipped" : "pass", "fallback transport");

    const payload = H.report();
    if (nativeOk) {
      try {
        await sendViaNativeMessaging(payload);
        return;
      } catch (error) {
        // Fall through to the beacon rather than losing the report.
      }
    }
    await sendViaBeacon(payload);
  }

  async function main() {
    // Any single hang must not cost the entire matrix; whatever has been recorded still ships.
    const watchdog = setTimeout(() => {
      H.record("harness.watchdog", "core", "timeout", "probe run exceeded 20s");
      sendViaBeacon(H.report()).catch(() => {});
    }, 20000);

    installListeners();
    namespaceProbes();
    await coreProbes();
    await storageProbes();
    await permissionProbes();
    await networkProbes();
    await uiProbes();
    await platformProbes();
    await tabProbes();
    eventDeliveryProbes();
    clearTimeout(watchdog);
    await deliver();
  }

  main().catch((error) => {
    H.record("harness.main", "core", "fail", error && error.message ? error.message : String(error));
    sendViaBeacon(H.report()).catch(() => {});
  });
})();
