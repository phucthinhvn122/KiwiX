# KiwiX architecture and security contract

This document describes the implementation currently in this repository. `project.yml` and the Swift
source remain authoritative. The extension runtime is Apple's `WKWebExtension` (ADR-001 in
`DECISIONS.md`); the app-owned runtime that preceded it has been removed. KiwiX does **not** claim
Chrome compatibility — what the runtime supports is measured by the API harness, not asserted here.

## Runtime shape

```text
Address/search input -> URLInputParser -> TabManager -> WKWebView
                                      -> History / tabs / snapshots / downloads

Extension directory -> WKWebExtension(resourceBaseURL:) -> WKWebExtensionContext
                    -> WKWebExtensionController -> WebExtensionHost -> tab/window adapters
```

- `BrowserCore` owns navigation policy, the active web view, trusted browser chrome, dialogs, and
  favicon discovery/fetching. `WebViewConfigurationProvider` is where the extension controller is
  attached to a configuration, or deliberately not attached.
- `Tabs` owns logical tab identity, the 50-tab global cap, normal-session restoration, snapshots, and
  ACTIVE/WARM/SUSPENDED lifecycle planning.
- `ExtensionHost` owns the `WKWebExtensionController`, the tab/window adapters WebKit calls back into,
  the permission policy per context, and the bounded package extractor CRX3 install will need.
- `History`, `Downloads`, `Settings`, and `Security` own their bounded stores and centralized policies.

Which APIs work is WebKit's answer, not the app's. The harness measures it per run rather than this
document claiming it.

## Browser profiles and private mode

Normal tabs share the default `WKWebsiteDataStore`. Private tabs use a separate non-persistent data
store and process pool; closing the last private tab replaces both and ends that in-memory private
profile. Private tabs are excluded from session restoration, history, snapshots, the favicon disk cache, and
the extension controller.

Downloads are the intentional exception: a user may save a file from a private tab. Before starting,
the UI states that the file remains on the device until deletion. Source/history metadata for a private
download is not persisted. On a later launch an untracked saved file can be surfaced as a recovered
download with no source URL, so it is not an invisible orphan.

## Navigation and trusted UI

- Address input is capped at 8,192 UTF-8 bytes. HTTP(S) URLs with credentials are rejected, malformed
  scheme-like input is not leaked to a search provider, and custom search templates are validated.
- Web content cannot launch an external scheme without a top-level, active-tab, foreground
  `linkActivated` gesture. Known user-intent schemes are allowlisted; unknown schemes require another
  native confirmation. Attempts are rate-limited per tab.
- `target=_blank` creation requires the same active foreground gesture and is rate-limited. The global
  tab cap still applies.
- JavaScript alert/confirm/prompt UI uses the initiating `WKFrameInfo.request.url` origin, never a
  document-controlled title. Messages/default input are byte-bounded; background, stacked, and
  excessive dialogs are suppressed with safe completion values.
- Error, private-mode, download, and permission states use native text and accessibility values rather
  than color alone. Interactive controls target at least 44 points and custom text uses Dynamic Type.

## Favicon network policy

Favicon candidates are untrusted web input. Native fetching accepts only credential-free HTTP(S) URLs,
forbids HTTPS downgrade, and validates the initial URL, every redirect, and the final URL. Hostnames are
canonicalized and resolved off the main actor; resolution fails closed unless every returned address is
public unicast. Loopback, unspecified, link-local, RFC1918/private, shared, benchmark, documentation,
multicast, reserved, IPv4-mapped IPv6, ULA, and special-use local hostnames are rejected.

The client uses an ephemeral credential/cookie/cache-free `URLSession`, a five-redirect limit, timeouts,
streaming byte enforcement, and image dimension/pixel validation. Private tabs bypass the disk cache.

Residual limitation: `URLSession` does not expose a supported way to pin the exact DNS answers used by
its connection while preserving normal TLS hostname verification. KiwiX resolves immediately before
each request/redirect and revalidates the final URL, which reduces DNS-rebinding risk but cannot remove
the resolver-to-connect TOCTOU completely. Cross-origin favicon fetching should be reconsidered if a
future platform API provides peer-address enforcement.

## Extension runtime (Path A)

ADR-001: the extension runtime is Apple's `WKWebExtension` stack, minimum iOS 18.4. The app does not
parse manifests, does not build content scripts, and does not implement any `chrome.*` method. What the
app owns is the browser side of the contract WebKit asks for.

```text
WKWebExtension(resourceBaseURL:)  ->  WKWebExtensionContext  ->  WKWebExtensionController
                                                                        |
       WebExtensionHost  <- delegate callbacks (tabs, windows, permissions, messages)
             |
             +-- WebExtensionTabAdapter   (WKWebExtensionTab)   -> TabManager
             +-- WebExtensionWindowAdapter (WKWebExtensionWindow)
             +-- WebExtensionHarnessChannel (test-only API probe transport)

ExtensionInstallCoordinator  ->  ExtensionPackageInstaller  ->  SafeZIPExtractor
             |                            |
             |                            +-- ExtensionPackageReader -> CRX3Reader (signature)
             +-- InstalledExtensionStore (catalog, the authority)
             +-- ExtensionPermissionSheetViewController (consent, spec 7)
```

`WebExtensionHost` holds the single controller, keeps a `UUID -> WebExtensionTabAdapter` registry, and
mirrors browser events into the runtime through `TabWebExtensionObserving`: open, close, activate, move,
and property changes. Ordering is fixed — the window is announced before its tabs, and a tab is opened
before it can be activated. Private tabs are filtered out of every one of those calls.

`WebExtensionHost.loadExtension` assigns `uniqueIdentifier` before load. The default is a fresh UUID per
install and it is what the extension reads as `browser.runtime.id`, so anything keyed on the default is
lost on reinstall. Apple documents the property as settable only while the context is unloaded. The
harness measures this end to end: an assigned identifier reaches JavaScript as `browser.runtime.id`
(`runtime.id` probe, PASS, CI run 32226404376).

`loadBackgroundContent` takes a timeout. A manifest the runtime cannot start — an MV3
`background.service_worker`, for one — never calls the completion handler at all, so without a deadline
the caller hangs instead of reporting that fact.

Permission answers come from a `WebExtensionPermissionPolicy` per context. `trustFirstPartyBundle`
grants every requested permission and match pattern and exists for the bundled harness fixture only.
`userGranted(permissions:matchPatterns:)` carries exactly the set the consent sheet displayed, for
anything the user installed. `denyAll` is the fallback for any context whose policy was not recorded,
and the three runtime prompts in `WebExtensionHost+Delegate` answer with nothing regardless.

The subset property is structural rather than checked after the fact: the granted set is built *from*
`requestedPermissions` and `allRequestedMatchPatterns`, so a pattern the manifest never asked for has no
route into a record. `optionalPermissions` are recorded as denied and stay denied — there is no runtime
grant dialog, and the sheet says so rather than implying one exists.

`allRequestedMatchPatterns`, not `requestedPermissionMatchPatterns`: the latter omits content-script
`matches`, so an extension whose entire host access comes from content scripts would be granted nothing
and fail silently.

### Private browsing

`WKWebViewConfiguration` is copied when the web view is created, so `webExtensionController` cannot be
corrected afterwards. `WebViewConfigurationProvider.configuration(isPrivate:)` therefore attaches the
controller to normal configurations only and leaves it `nil` for private ones. That single assignment is
the enforcement point for "extensions are off in private tabs", and `PrivateModeTests` asserts both
halves of it — the controller present on normal, absent on private, before and after a profile reset.

### Installing a package

The user picks a file; nothing else is a source. There is no store, no URL field, and no auto-update,
because a file the user chose is a file the user can point at afterwards.

`ExtensionPackageReader` classifies it. A `.crx` goes through `CRX3Reader`, which verifies an RSA
PKCS#1 v1.5 SHA-256 proof over the Chromium-specified payload — the literal `CRX3 SignedData` plus a NUL,
then the little-endian header length, then the header, then the archive — and derives the publisher id
as the first 128 bits of `SHA256(DER SPKI)` rendered in the `a`-`p` alphabet. The header is rejected if it
contains an end-of-central-directory token, which would let a crafted header steer a ZIP reader.

The resulting type has two cases and deliberately not three:

```swift
case verified(publisherIdentifier: String)
case unsigned(UnsignedReason)   // .plainArchive | .noSupportedProof
```

A *wrong* signature is a thrown error that never reaches the UI. Only a *missing* one — a plain archive,
or a CRX3 carrying only proofs `SecKey` will not evaluate — reaches the consent sheet, where spec 7
requires a warning banner and a second confirmation. Collapsing both into one "signature not OK" case is
how a broken signature eventually gets handled with a soft warning.

`SafeZIPExtractor` bounds the archive at 50 MiB compressed, 2,000 entries, 16 MiB per entry, 100 MiB
expanded, and a 250:1 compression-ratio threshold for large entries. Entry paths are rejected for
absolute/traversal forms, empty or dot components, backslashes, drive paths, NUL and control bytes,
case/Unicode collisions, symlinks, unsupported object types, executable extensions, and native binary
magic. CRC is checked while extracting. `ExtensionIdentity` then computes a SHA-256 over normalized
relative paths, lengths, and file bytes; the first 128 bits are the extension's identifier, which is also
its `uniqueIdentifier` and its directory name under `Application Support/ExtensionBrowser/Extensions/`.

Nothing here reads a manifest. The consent sheet is filled by constructing `WKWebExtension` on the
staging directory and reading `requestedPermissions` and `allRequestedMatchPatterns` back. This is not
tidiness: the strings on screen are the same strings written to the catalog and later turned back into
`WKWebExtension.Permission` when the grant is applied. A sheet that spelled them differently would be
describing a permission that never happens.

`InstalledExtensionStore` is the authority, not the directory listing. `restore()` rebuilds the runtime
from the catalog at launch; a commit whose catalog write fails has its files deleted rather than left as
an orphan; and any identifier read back from the catalog is re-validated through
`ExtensionIdentifier(rawValue:)` before it can become a path component, because a string read out of a
file on disk is not something to hand to a recursive delete.

A `.crx` declares its own UTI conforming to `public.data`, not `public.zip-archive` — CRX3 opens with
`Cr24`, so the latter would be a false claim the system acts on. The app does not declare
`LSSupportsOpeningDocumentsInPlace`, and `SceneDelegate` re-checks `!options.openInPlace` anyway, because
the import path deletes the file it reads and that must never be a user's original.

Signature verification proves who built a package and that it was not altered afterwards. It does not
make a publisher trustworthy: the id is a key fingerprint, not a vetted name, and a plain `.zip` has
neither.

### What the runtime actually supports

Measured, not assumed. The bundled `APIHarness` fixture probes 90 APIs and prints a pass/fail table on
every CI run; `COMPATIBILITY.md` carries the current matrix and `M2_REPORT.md` the run it came from.
Latest: 42 pass, 0 fail, 18 available-but-unexercised, 26 unsupported, 4 skipped, on iOS 18.5 simulator.
Simulator results are a smoke test, not device evidence.

One answer did not come from the harness, because the harness cannot serve itself a request it owns.
`WebExtensionNetworkEnforcementTests` runs a real HTTP server on loopback and measures whether a
`declarativeNetRequest` rule stops anything. It does not: the rules install, `getEnabledRulesets()` and
`hasContentModificationRules` both report them, `getMatchedRules()` returns empty, and every request
arrives — while a `WKContentRuleList` compiled by the same test blocks the same URL on the same server.
`webRequest` listeners register and never fire. `M3_REPORT.md` has the method and the eliminated
confounds; R-21 has the consequence, which is that the spec's v1 yardstick extension cannot function.

## Downloads and persistence

Downloads are capped at 500 MiB, warn at 50 MiB, reserve 250 MiB free space, and allow three concurrent
transfers. Expected size is only an early rejection signal: progress and destination size are polled,
unknown/chunked responses are bounded while downloading, and low-disk/oversize transfers are cancelled.
WebKit writes to an internal hidden `.partial` path; only successful completion atomically moves it to a
sanitized unique visible filename. Startup reconciliation fails interrupted records, removes their
partials, marks missing completed files, deletes hidden orphan partials (including metadata-free private
transfers), and surfaces bounded safe untracked completed files as recovered downloads.

Tab, history, download, favicon, and snapshot stores bound file bytes/counts and normalize
attacker-controlled strings/URLs before persistence. Externally influenced files use a streaming bounded
reader, so growing a file after its metadata check cannot bypass the allocation limit. Malformed
oversized tab/history records are quarantined or reset. Direct-child scans for favicon directories are
streaming and bounded rather than materializing arbitrary directory contents. Atomic writes are used for metadata.

Data protection is centralized:

- browser state, metadata, snapshots, and favicons:
  `completeUntilFirstUserAuthentication`;
- user downloads: `completeUnlessOpen`;
- import staging/temporary sensitive files: `complete`.

These attributes require verification on a physical protected device; simulator/static inspection is
not equivalent evidence.

## Concurrency and lifecycle

UIKit/WebKit ownership stays on `@MainActor`, including the whole extension host — `WKWebExtension`
and its protocols are main-actor-isolated, so there is no choice there. Persistence, favicon
brokerage/cache, and repositories use actors. Download metadata writes are serialized. Async work rechecks tab/web-view identity and URL after suspension;
favicon requests and idle injection support cancellation. Late download callbacks are idempotently
discarded after tracking is removed.

Memory warnings snapshot and suspend background tabs. Favicon memory/disk caches, tab count, images, payloads,
downloads, and persisted collections have explicit caps.

## CI and verification status

`project.yml` is the Xcode project source. CI pins Xcode 16.4, XcodeGen 2.46.0 with checksum verification,
third-party action commits, and ZIPFoundation 0.9.20. Private-API and ad-SDK scans run in repository
scripts.

The hardening changes can be statically inspected on Windows, but Windows has no Apple SDK, WebKit, or
iOS simulator. A green macOS `xcodebuild test`, Release build, and device checks for data protection,
VoiceOver, memory, and WebKit network behavior remain required release evidence. Do not mark those
runtime gates passed based on source parsing alone.
