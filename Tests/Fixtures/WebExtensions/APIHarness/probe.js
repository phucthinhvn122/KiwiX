// Probe engine. Loaded before background.js by manifest order.
//
// Everything here is deliberately dependency-free and defensive: the whole point is to run on a
// runtime whose capabilities are unknown, so any call may be missing, throw synchronously, or
// reject.

globalThis.KiwiXHarness = (() => {
  const api = globalThis.browser ?? globalThis.chrome;
  const probes = [];
  const MAX_DETAIL = 180;

  function detailText(value) {
    if (value === undefined || value === null) return null;
    if (typeof value === "string") return value.slice(0, MAX_DETAIL);
    try {
      return JSON.stringify(value).slice(0, MAX_DETAIL);
    } catch (error) {
      return String(value).slice(0, MAX_DETAIL);
    }
  }

  function record(id, area, status, detail) {
    probes.push({ id, area, status, detail: detailText(detail) });
  }

  function resolve(path) {
    return path.split(".").reduce((node, key) => (node == null ? undefined : node[key]), api);
  }

  // A missing namespace is "unsupported"; a present namespace that blows up is "fail". The
  // distinction is the entire value of the matrix.
  function classify(error) {
    const message = error && error.message ? error.message : String(error);
    return /is not a function|not supported|not implemented|undefined is not an object/i.test(message)
      ? "unsupported"
      : "fail";
  }

  function existence(id, area, path) {
    const value = resolve(path);
    if (value === undefined || value === null) {
      record(id, area, "unsupported", "missing");
      return false;
    }
    record(id, area, "pass", typeof value);
    return true;
  }

  async function run(id, area, fn) {
    if (typeof fn !== "function") {
      record(id, area, "skipped", "no probe body");
      return undefined;
    }
    try {
      const result = await fn(api);
      record(id, area, "pass", result);
      return result;
    } catch (error) {
      record(id, area, classify(error), error && error.message ? error.message : String(error));
      return undefined;
    }
  }

  function skip(id, area, reason) {
    record(id, area, "skipped", reason);
  }

  function withTimeout(promise, milliseconds, label) {
    return Promise.race([
      promise,
      new Promise((_, reject) =>
        setTimeout(() => reject(new Error(`${label} timed out after ${milliseconds}ms`)), milliseconds)
      )
    ]);
  }

  function deferred() {
    let resolveFn;
    const promise = new Promise((res) => {
      resolveFn = res;
    });
    return { promise, resolve: (value) => resolveFn(value) };
  }

  function environment() {
    const env = {};
    try {
      const manifest = api.runtime.getManifest();
      env.manifestVersion = String(manifest.manifest_version);
      env.extensionName = String(manifest.name);
    } catch (error) {
      env.manifestVersion = "unknown";
    }
    env.globalNamespace = globalThis.browser ? (globalThis.chrome ? "browser+chrome" : "browser") : "chrome";
    env.userAgent = String(globalThis.navigator && navigator.userAgent).slice(0, 160);
    env.hasServiceWorkerGlobal = String(typeof ServiceWorkerGlobalScope !== "undefined");
    env.hasWindowGlobal = String(typeof window !== "undefined");
    return env;
  }

  function report() {
    return { schema: 1, environment: environment(), probes };
  }

  return { api, record, existence, run, skip, withTimeout, deferred, report, probes };
})();
