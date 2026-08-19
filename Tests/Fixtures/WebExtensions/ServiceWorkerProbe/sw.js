// Minimal service-worker background. The Swift side only checks whether the runtime accepts and
// starts it; the storage write is there so a started worker leaves a trace.
const api = globalThis.browser ?? globalThis.chrome;

api.storage.local.set({ serviceWorkerStarted: true }).catch(() => {});
