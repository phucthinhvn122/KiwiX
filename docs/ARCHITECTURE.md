# KiwiX architecture and security contract

This document describes the implementation currently in this repository. `project.yml` and the Swift
source remain authoritative. `DECISIONS.md` records a possible future migration to Apple's
`WKWebExtension`; KiwiX does **not** currently claim that migration or Chrome compatibility is complete.

## Runtime shape

```text
Address/search input -> URLInputParser -> TabManager -> WKWebView
                                      -> History / tabs / snapshots / downloads

ZIP or folder -> bounded extractor -> manifest validator -> package identity
              -> install confirmation -> ExtensionRepository
              -> explicit grants -> content scripts / popup / native bridge
```

- `BrowserCore` owns navigation policy, the active web view, trusted browser chrome, dialogs, favicon
  discovery/fetching, and the browser/extension boundary.
- `Tabs` owns logical tab identity, the 50-tab global cap, normal-session restoration, snapshots, and
  ACTIVE/WARM/SUSPENDED lifecycle planning.
- `ExtensionKit` owns package validation, installed-tree integrity, declared/granted permissions,
  content-script preparation, IPC routing, API quotas, and extension-local storage.
- `ExtensionUI` owns provenance/permission confirmation, grant/revoke controls, extension actions, and
  local-only popup rendering.
- `History`, `Downloads`, `Settings`, and `Security` own their bounded stores and centralized policies.

The current extension runtime is deliberately small. Unsupported `chrome.*` methods fail closed; they
are not silently shimmed.

## Browser profiles and private mode

Normal tabs share the default `WKWebsiteDataStore`. Private tabs use a separate non-persistent data
store and process pool; closing the last private tab replaces both and ends that in-memory private
profile. Private tabs are excluded from session restoration, history, snapshots, favicon disk cache,
extension configuration, and extension storage.

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

## Extension installation and integrity

Default package limits are 50 MiB compressed, 2,000 entries, 16 MiB per entry, 100 MiB expanded, and a
250:1 compression-ratio threshold for large entries. ZIP and folder imports reject absolute/traversal
paths, empty/dot components, backslashes, drive paths, NUL/control bytes, case/Unicode collisions,
symlinks, unsupported objects, executable extensions, and native binary magic. CRC is checked while
extracting, and staging is protected as temporary sensitive data.

Manifest JSON is limited to 1 MiB and receives a depth/string preflight before Codable decoding.
Manifest collections, strings, match patterns, resource references, and action metadata have explicit
caps. Unknown API permissions are rejected.

The package SHA-256 covers normalized relative paths, lengths, and file bytes; the first 128 bits form
the extension ID. The install confirmation shows name, version, ID, local source, SHA-256, publisher
state (`Not verified`), requested APIs/sites, and a prominent `<all_urls>` warning. Installation
recomputes the staged identity. Every full repository scan/reload recomputes a bounded tree identity and
checks the directory name, manifest, metadata, ID, and digest. Resource reads then reuse that verified
in-process snapshot. The runtime manifest copy must match the package manifest byte-for-byte, so a
metadata-preserving manifest substitution cannot bypass the package digest. This avoids a 100 MiB tree
rehash for each referenced file. Package commit reuses the same bounded folder copier as import rather
than recursively copying an unbounded tree. Repository enumeration has a hard inspection bound and
fails closed if truncated; at most 128 extensions are installed by default. Repository mutations
invalidate or replace the snapshot and trigger a full runtime reload. One corrupt extension is
quarantined without hiding valid peers, and a later valid package with that ID may replace the
quarantined directory.

Packages are not signed and publisher identity is not authenticated. Hashes identify exact bytes only.

## Permission contract

Permission state separates:

```text
declared API capabilities
persisted granted API capabilities
declared host/content-script patterns
persisted host grants (which may be narrower than declarations)
temporary activeTab origin keyed by tab UUID
enabled state
```

Install does not grant `<all_urls>`, broad hosts, `tabs`, or `scripting`. `storage` and `activeTab` may
start enabled when declared: storage is quota-bound/namespaced, and activeTab remains inert until the
user invokes the extension. Legacy metadata without grant fields migrates fail-closed.

Extension Details offers Ask, Current Website, Selected Websites, and All Requested Websites. Selected
domains are converted to conservative exact-host patterns that preserve the manifest scheme/path and
must be subsets of a declaration. Domains can be added/removed. Enabling all requested access is a
separate confirmation, with stronger text for `<all_urls>`. API capability grants are displayed and
revoked separately with human-readable explanations.

Revocation updates the permission actor, immediately suspends bridge dispatch, rebuilds owned
scripts/handlers, and reloads tracked normal web views so previously installed user scripts cannot
silently survive. Reload requests are serialized; only the newest successful generation resumes bridge
dispatch, and in-flight operations are cancelled before side effects. A failed repository reload clears
prepared permissions, handlers, user scripts, idle jobs, and reloads tracked pages while leaving the
bridge suspended; stale DOM-only scripts are not retained as a fallback. Future API calls and content
scripts fail the new policy. A user-invoked extension action can create an activeTab grant only for the
current normal tab/origin; it is revoked on navigation, tab close, disable, action failure, active-tab
change, or revocation of the `activeTab` capability itself.

Declarative `content_scripts.matches` authorizes only that rule; it does not create programmatic host
access. `exclude_matches` remains effective. `tabs` and `scripting` require their API grants, and script
execution additionally requires a persisted programmatic host grant or matching activeTab grant.

## Content scripts, IPC, storage, and popup isolation

Each extension receives a named `WKContentWorld` and a native-owned message handler; identity comes
from that handler/world, not message data. One owner-aware user-script registry composes browser,
security, and per-extension scripts before the necessary WebKit-wide rebuild. A dedicated per-tab
`document_idle` scheduler defers work after navigation finish, replaces stale jobs, and cancels/rechecks
across commit, failure, and tab close.

The JavaScript bridge accepts only a flat serialized JSON string. Native code checks its UTF-8 byte
length, nesting, string length, and structural-token budget before `JSONSerialization` or recursive
conversion; dictionary/object message bodies are rejected. Responses cross WebKit as bounded JSON
strings and are parsed in JavaScript. Standard limits include 256 KiB incoming, 512 KiB outgoing,
depth 16, 4,096 JSON nodes, 1,024 aggregate object members/array elements, 64 KiB strings, 20
requests/second per extension/API/tab, 40-request extension bursts, eight outstanding per extension,
four per extension/API, and a ten-second timeout. Completion accounting is idempotent.

`tabs.create` also has a per-extension creation window and the browser-wide 50-tab cap.
`scripting.executeScript` limits inline source, file count, each file, aggregate source, result size, and
parallel executions; runtime content-script preparation also has a 16 MiB / 512-script aggregate budget
across all enabled extensions, rather than multiplying a per-extension allowance. Script execution rechecks the
live URL before and inside evaluation. Storage validates keys and
values before merge, limits each operation, validates persisted JSON depth before decode, and enforces a
5 MiB per-extension encoded quota. Oversized or malformed local storage is moved to a protected
`local.corrupt-*.json` file and the namespace recovers empty; genuine read I/O failures remain errors.

Popups use a non-persistent store, load only files contained in the verified extension root, cancel
non-file navigation, and install both a content-rule blocklist and locked JavaScript stubs for fetch,
XHR, WebSocket, EventSource, workers, and sendBeacon. This is a deny-all network boundary; host grants
do not currently enable popup network access.

Content worlds are not DOM sandboxes: an authorized content script can read/change the matching page.
The bridge supports Promise-style `runtime.sendMessage`, `storage.local`, `tabs.query/create`,
`scripting.executeScript`, and `action.getTitle/setTitle`; background service workers, native messaging,
webRequest/DNR, long-lived ports, and broad Chrome parity are unsupported.

## Downloads and persistence

Downloads are capped at 500 MiB, warn at 50 MiB, reserve 250 MiB free space, and allow three concurrent
transfers. Expected size is only an early rejection signal: progress and destination size are polled,
unknown/chunked responses are bounded while downloading, and low-disk/oversize transfers are cancelled.
WebKit writes to an internal hidden `.partial` path; only successful completion atomically moves it to a
sanitized unique visible filename. Startup reconciliation fails interrupted records, removes their
partials, marks missing completed files, deletes hidden orphan partials (including metadata-free private
transfers), and surfaces bounded safe untracked completed files as recovered downloads.

Tab, history, download, extension, favicon, and snapshot stores bound file bytes/counts and normalize
attacker-controlled strings/URLs before persistence. Externally influenced files use a streaming bounded
reader, so growing a file after its metadata check cannot bypass the allocation limit. Malformed
oversized tab/history records are quarantined or reset; corrupt extension storage and packages are
isolated individually. Direct-child scans for extension and favicon directories are streaming and
bounded rather than materializing arbitrary directory contents. Atomic writes are used for metadata.

Data protection is centralized:

- browser state, metadata, extension files/storage, snapshots, and favicons:
  `completeUntilFirstUserAuthentication`;
- user downloads: `completeUnlessOpen`;
- import staging/temporary sensitive files: `complete`.

These attributes require verification on a physical protected device; simulator/static inspection is
not equivalent evidence.

## Concurrency and lifecycle

UIKit/WebKit ownership stays on `@MainActor`. Persistence, permissions, request limiting, matching,
storage, favicon brokerage/cache, and repositories use actors. Extension setting mutations and download
metadata writes are serialized. Async work rechecks tab/web-view identity and URL after suspension;
favicon requests and idle injection support cancellation. Late download callbacks are idempotently
discarded after tracking is removed.

Memory warnings snapshot and suspend background tabs. Favicon memory/disk caches, tab count, extension
source preparation, images, payloads, storage, downloads, and persisted collections have explicit caps.

## CI and verification status

`project.yml` is the Xcode project source. CI pins Xcode 16.4, XcodeGen 2.46.0 with checksum verification,
third-party action commits, and ZIPFoundation 0.9.20. Private-API and ad-SDK scans run in repository
scripts.

The hardening changes can be statically inspected on Windows, but Windows has no Apple SDK, WebKit, or
iOS simulator. A green macOS `xcodebuild test`, Release build, and device checks for data protection,
VoiceOver, memory, and WebKit network behavior remain required release evidence. Do not mark those
runtime gates passed based on source parsing alone.
