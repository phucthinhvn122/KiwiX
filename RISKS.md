# KiwiX risk register

Updated: 2026-08-19. Probability (P) and impact (I) use a 1–5 scale. “Residual” means source
mitigations exist but runtime or platform evidence is still required.

| ID | Risk | P | I | Mitigation in this repository | Residual / closure evidence |
|---|---|---:|---:|---|---|
| R-01 | Favicon SSRF reaches localhost, LAN, or metadata services | 2 | 5 | Public-unicast DNS/IP policy; initial, redirect, and final URL checks; ephemeral credential-free streaming client | `URLSession` DNS-to-connect TOCTOU remains; close with macOS redirect/DNS tests and platform support for peer-address enforcement |
| R-02 | A page launches another app or floods native UI | 2 | 4 | Active top-level foreground gesture requirement, allowlist/confirmation, per-tab rate limits; origin-labelled bounded JS dialogs | UI integration tests on device, including iframe and background cases |
| R-03 | Untrusted extension package escapes staging or exhausts memory/disk | 2 | 5 | ZIP/folder file-count, byte, ratio, path, symlink, duplicate, CRC, and native-binary checks; bounded identity hashing | Fuzz corpus and peak-memory measurements on Apple runtime |
| R-04 | User mistakes an unsigned local extension for a verified publisher | 3 | 5 | Import UI says “Unverified”, publisher “Not verified”, and shows source, ID, SHA-256, APIs, and sites | Package signatures/trust store are not implemented; hashes prove bytes, not authorship |
| R-05 | Broad host/API access is silently granted or survives revoke | 2 | 5 | Declared/granted split, fail-closed migration, no default broad grants, selected-site subset validation, separate `<all_urls>` warning, immediate bridge suspension, generation-serialized rebuild/reload, in-flight cancellation; failed reload clears old scripts/handlers and reloads pages | Device UI + WebKit integration test must prove existing pages and iframe scripts stop after revoke |
| R-06 | Temporary activeTab access crosses tab/navigation/private boundaries | 2 | 5 | Grant keyed by tab UUID + origin after explicit action; revoke on navigation, close, disable, active-tab change, and action failure; extensions disabled in private | Navigation/action race tests on device |
| R-07 | Malicious extension floods IPC, tabs, scripts, or storage | 2 | 5 | Flat-string IPC with byte/depth/token preflight before JSON decode, request/outstanding/time limits, idempotent tokens, tab/rate caps, script/source/result/parallel limits, storage prevalidation/quota | Stress tests and memory graph on iPhone; a handler that ignores cancellation remains fail-closed but can occupy its bounded slot |
| R-08 | Popup bypasses host policy to reach the network | 2 | 5 | File-root-only navigation, non-persistent store, content-rule HTTP/WS/FTP block, locked fetch/XHR/WebSocket/EventSource/worker/beacon stubs | WebKit implementation behavior needs device network-capture tests; popup networking is intentionally deny-all |
| R-09 | Download ignores declared length, fills disk, or leaves invisible partials | 2 | 5 | 500 MiB streaming cap, free-space reserve, progress/file polling, concurrency cap, hidden partial + atomic finalization, cancel cleanup, startup reconciliation/recovery | Exercise unknown-length, chunked, redirect, cancellation, and app-termination cases with a controlled server |
| R-10 | Corrupt persisted data crashes startup or hides healthy data | 2 | 4 | Streaming bounded file/direct-child reads, extension-count and repository inspection caps, pre-decode checks, atomic writes, tab/history reset/quarantine, per-extension package/storage quarantine, download reconciliation | Fault-injection suite still needs Apple runtime coverage for file-coordination and protection errors |
| R-11 | Private browsing leaks normal-profile state | 2 | 5 | Separate non-persistent WebKit profile reset after the last private tab closes; no extension config, history, tab restore, snapshots, or favicon disk cache; private metadata omitted | Saved download files intentionally persist after an explicit warning; process-restart privacy test required |
| R-12 | Sensitive files are readable while device is locked | 2 | 5 | Central protection classes for browser state, downloads, and temporary staging; recursive protection after install | File protection semantics cannot be proven on Windows/simulator; verify on a passcode-protected device |
| R-13 | Async callbacks mutate stale tabs/UI or complete twice | 2 | 4 | MainActor WebKit/UI ownership, actor stores, serialized UI mutations/persistence, identity/URL rechecks, cancellation, idempotent download/request tracking | Thread Sanitizer and rapid interaction tests on macOS/device |
| R-14 | Logs disclose browsing URLs, paths, or extension content | 2 | 4 | OSLog dynamic error details are private; persistent models strip credentials and bound text; no analytics SDK | Static scan plus privacy inspection of device logs/crash reports |
| R-15 | Source-only review is mistaken for a successful iOS release | 4 | 5 | Documentation explicitly marks Apple build/device gates; CI pins Xcode and action commits; private-API/ad-SDK guards | Close only with green `.xcresult`, Release archive, signed-device run, VoiceOver, memory, and network evidence |
| R-16 | Current custom extension bridge is assumed to provide Chrome parity | 4 | 4 | Small allowlisted API surface; unknown permissions/APIs fail closed; architecture names unsupported areas | Publish compatibility results per OS/device; future `WKWebExtension` migration is a separate decision, not implemented evidence |
| R-17 | Distribution violates platform/store policy or signing expectations | 3 | 5 | Unsigned/signed artifacts are labelled separately; no App Store compatibility claim | Product/legal review and valid signing/provisioning are required before distribution outside development |
| R-18 | Most Chrome MV3 extensions ship `background.service_worker`, which loads silently and never runs | 5 | 5 | Measured in M2, not assumed: `WKWebExtension` accepts such a manifest with `errors == []` and `hasBackgroundContent == true`, yet `loadBackgroundContent` never calls back. `loadBackgroundContent(for:timeout:)` turns that silence into a reportable error instead of a hang; `COMPATIBILITY.md` records it | The M4 installer must detect this before reporting a successful install — a user who sees “installed” for a dead extension is worse off than one who sees a refusal. No repackaging shim exists; whether one is viable is unproven |
| R-19 | Simulator 18.5 results are read as iOS 18.4 device results | 4 | 4 | Host, not JavaScript, stamps `osVersion`/`isSimulator` into every report; `DECISIONS.md` §4.1 keeps the device column at CHƯA CHẠY; both reports carry the warning | The CI runner offers no 18.4 runtime, so the declared deployment floor is still unmeasured. Close with one harness run on 18.4 and one on a provisioned device |
| R-20 | Extension identity is left on the default `runtime.id`, which the runtime reassigns per install | 3 | 4 | Measured across two CI runs of a byte-identical fixture: the default id changed. Apple documents `WKWebExtensionContext.uniqueIdentifier` as `{ get set }`, settable only before the context is loaded, and surfaced to the extension as `browser.runtime.id` — so the fix is to assign our own package content hash (`ExtensionKit/Installer/ExtensionIdentity.swift`) before `controller.load(context)` | Not yet implemented, and not yet measured: the settability is read from Apple documentation, not from a harness probe. Assigning after load is silently ineffective, so the installer's ordering needs a test that would fail if the assignment moved |

## Stop-ship conditions

Do not distribute a build outside the development team when any of these is true:

- a known High/Critical trust-boundary bypass is open;
- localhost/LAN favicon fetching, automatic external-scheme launch, or popup network escape is reproducible;
- `<all_urls>` is granted on install, cannot be revoked, or content scripts ignore the effective grant;
- private tabs persist browser/extension state other than the explicitly disclosed downloaded file;
- unknown-length downloads can exceed the byte/disk policy or leave tracked partial files;
- a malformed package/store record can crash startup or execute after integrity failure;
- private-API/ad-SDK scans fail;
- macOS build/tests are red or have not run for the candidate commit;
- signing/profile identity does not match the shipped app;
- required device checks for file protection, VoiceOver, memory, and WebKit behavior lack evidence.

## Accepted product limitations

- Extension packages are local and unsigned. Publisher verification and automatic updates are absent.
- Authorized content scripts can read/change matching DOM; `WKContentWorld` isolates globals, not DOM.
- Popup network access is deny-all rather than a complete Chrome network-permission implementation.
- Failed `WKDownload` resume data is intentionally discarded; resumable download UI is not implemented.
- Background workers, webRequest/DNR, native messaging, long-lived ports, and broad Chrome compatibility
  are not supported.
- A private download file persists because the user explicitly saves it; the UI warns before starting and
  metadata does not preserve its private source URL.
- Installed extension bytes are fully reverified on repository scans/reloads, then cached for the
  process lifetime between repository mutations. Out-of-band sandbox tampering after a scan is detected
  at the next scan rather than by rehashing the full tree before every resource read.
