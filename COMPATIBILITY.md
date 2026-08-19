# COMPATIBILITY — WebExtension API surface đo thật trên `WKWebExtension`

Bảng này **không copy từ spec, không copy từ tài liệu Apple**. Mọi dòng đến từ một extension harness
tự viết (`Tests/Fixtures/WebExtensions/APIHarness/`) chạy bên trong runtime thật và gửi kết quả về app
qua native messaging. Nguồn dữ liệu là artifact `webextension-api-matrix.json` của lần chạy CI xanh.

## Lần chạy tham chiếu

| Trường | Giá trị |
|---|---|
| CI run | `32223595806` — `** TEST SUCCEEDED **`, 143 test, 0 failure |
| Kênh báo cáo | `native` (`runtime.sendNativeMessage` tới `WKWebExtensionControllerDelegate`) |
| OS | **iOS 18.5** simulator (không phải 18.4 — xem cảnh báo bên dưới) |
| Hardware | `arm64`, `deviceModel=iPhone`, `isSimulator=true` |
| User agent | `Mozilla/5.0 (iPhone; CPU iPhone OS 18_5 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Mobile/15E148` |
| Manifest | MV3, `background.scripts` + `persistent:false` |
| Global namespace | `browser` **và** `chrome` đều tồn tại |
| Extension ID cấp bởi runtime | `1dbcf887-ecaf-4c36-a5e5-35c8faaeb7a4` — UUID, **và đổi mỗi lần cài lại** (xem bên dưới) |
| Timestamp | `2026-08-19T06:33:52Z` |
| Global khác | `hasWindowGlobal=true`, `hasServiceWorkerGlobal=false` |

Tổng: **90 probe — 42 pass, 0 fail, 0 timeout, 18 available, 26 unsupported, 4 skipped.**

Không có dòng `fail` nào. Lần chạy trước đó (`32222870118`) có 1 fail ở `webNavigation.getAllFrames`;
truy ra là lỗi của chính harness — probe truyền `tabId: -1`, tức `tabs.TAB_ID_NONE`, và runtime từ chối
đúng. Sửa probe để dùng id tab thật thì nó pass (`frames=1`). Ghi lại ở đây vì một dòng FAIL do harness
sai mà đem báo cáo như giới hạn của WebKit thì tệ hơn là không đo.

`available` nghĩa là namespace có mặt nhưng chưa thao tác thật. Theo DECISIONS §4.2.5, nó **không**
được cộng vào pass. Đây là lý do 18 dòng `available` nằm riêng chứ không được làm tròn thành "chạy được".

## Kết luận theo nhóm

### Chạy được, đã thao tác thật (pass)

| API | Bằng chứng đo được |
|---|---|
| `runtime.getManifest` | trả về `manifest_version: 3` |
| `runtime.id` | `1dbcf887-ecaf-4c36-a5e5-35c8faaeb7a4` |
| `runtime.getURL` | `webkit-extension://<id>/manifest.json` — scheme là `webkit-extension`, không phải `chrome-extension` |
| `runtime.getPlatformInfo` | `{"os":"ios","arch":"arm"}` — **`os` trả về `ios`**, không phải `mac` |
| `runtime.onMessage` | đăng ký + nhận thật từ content script |
| `runtime.sendNativeMessage` | `handshake accepted` — tới được delegate của app |
| `storage.local` / `storage.session` / `storage.sync` | round-trip set→get→remove thành công cả ba |
| `tabs.query` / `.create` / `.get` / `.remove` | đi xuyên tab adapter thật; `tabs.create` trả `id=64` |
| `tabs.activate` | `switched=away+back onActivated=true` — chuyển sang tab khác rồi quay lại, browser báo đúng cả hai lần |
| `tabs.onCreated` / `onUpdated` / `onActivated` / `onRemoved` | listener **thật sự nổ**, không chỉ đăng ký được |
| `tabs.onMoved` / `windows.onFocusChanged` | đăng ký được (chưa kích hoạt — xem mục `skipped`) |
| `windows.getCurrent` / `.getAll` | `id=50 type=normal incognito=false`, count=1 |
| `scripting.executeScript` / `.insertCSS` | chạy được vào tab thật, kết quả trả về đúng |
| `contentScript.injection` | content script thấy `runtime.id` — injection thật sự xảy ra |
| `permissions.getAll` | `permissions=15 origins=1` |
| `permissions.contains` | `<all_urls>` = `true` |
| `declarativeNetRequest.getEnabledRulesets` | `harness-static` — static ruleset được nạp |
| `declarativeNetRequest` dynamic rules | thêm/đọc được, count=1 |
| `cookies.getAll` | count=0, không lỗi |
| `webRequest` blocking | **`extraInfoSpec: ["blocking"]` được chấp nhận** khi đăng ký listener |
| `action.setBadgeText` / `.setTitle` | delegate `didUpdateAction` nổ 1 lần |
| `contextMenus.create` | không lỗi |
| `alarms.create` | count=1 |
| `i18n.getUILanguage` | `en-US` |
| `webNavigation.getAllFrames` | `frames=1` trên tab thật |

Delegate callback runtime thật sự gọi ngược vào app: `didUpdateAction=1 focusedWindowFor=1
openNewTabUsing=1 openWindowsFor=1 sendMessage=2`.

### Không tồn tại (unsupported) — 26

`storage.managed`, `userScripts`, `webRequest.filterResponseData`, `proxy`, `debugger`, `dns`,
`notifications`, `omnibox`, `sidePanel`, `sidebarAction`, `devtools`, `commands`, `idle`,
`management`, `offscreen`, `identity`, `privacy`, `bookmarks`, `history`, `downloads`,
`browsingData`, `topSites`, `sessions`, `search`.

Hai trường hợp namespace có mặt nhưng method thì không:

- `declarativeNetRequest.getAvailableStaticRuleCount` → `is not a function`
- `notifications.create` → `undefined is not an object`

### Chỉ có mặt, chưa chứng minh (available) — 18

`runtime`, `storage`, `storage.session`, `storage.sync`, `tabs`, `windows`, `scripting`,
`declarativeNetRequest`, `webRequest`, `webNavigation`, `cookies`, `action`, `contextMenus`, `menus`,
`permissions`, `alarms`, `i18n`, và `webRequest.onBeforeRequest.register`.

`webRequest.onBeforeRequest.register` cố ý dừng ở `available`: đăng ký listener thành công **không**
chứng minh có traffic đi qua nó. Chỉ probe nào quan sát được request thật mới được `pass`.

### Chưa đo, có lý do (skipped) — 4

| Probe | Lý do |
|---|---|
| `declarativeNetRequest.enforcement` | Trang harness do `loadSimulatedRequest` phục vụ, không có subresource origin nào dự án kiểm soát. Host `.test` sẽ fail DNS, nên kết quả "bị block" không phân biệt được với "không phân giải được tên". Cần test server nội bộ → M3. |
| `tabs.onMoved.fired` | Chưa thực hiện reorder tab |
| `windows.onFocusChanged.fired` | Chỉ có một window (ADR-004) |
| `tabs.create.beacon` | Transport dự phòng không dùng tới vì native messaging đã thắng |

## `runtime.id` không ổn định giữa các lần cài

Hai lần chạy CI liên tiếp với **cùng một fixture không đổi một byte** trả về hai id khác nhau:

| Run | `runtime.id` |
|---|---|
| `32222870118` | `4c45c2a8-25cc-4872-89db-55d7618314bb` |
| `32223595806` | `1dbcf887-ecaf-4c36-a5e5-35c8faaeb7a4` |

Đây là UUID **mặc định** do runtime cấp cho mỗi lần cài, không phải id suy ra từ `key` trong manifest
như Chrome.

Nhưng đây không phải ngõ cụt. Tài liệu Apple cho `WKWebExtensionContext.uniqueIdentifier`:

```swift
var uniqueIdentifier: String { get set }
```

> The default value is a unique value that matches the host in the default base URL. The identifier can
> be any value that is unique. **Setting is only allowed when the context is not loaded.** This value is
> accessible by the extension via `browser.runtime.id`.

Nghĩa là app **phải chủ động gán** identifier ổn định của mình trước khi `controller.load(context)`.
Hệ quả cho M4/M5:

- app tự sinh identity bền cho mỗi extension (hash nội dung package — `ExtensionHost/Install/ExtensionIdentity.swift`
  đã làm việc này) rồi gán vào `context.uniqueIdentifier` **trước khi load**;
- nếu không gán, mọi thứ khoá theo `runtime.id` sẽ mất sau mỗi lần cài lại — kể cả storage của chính
  extension;
- gán sau khi context đã load là không có tác dụng, nên thứ tự trong installer là bắt buộc, không phải
  tuỳ chọn.

**Đã verify bằng thực nghiệm** (CI run 32226404376). `WebExtensionHost.loadExtension` gán
`uniqueIdentifier = "kiwix.harness.pinned-identity"` trước `controller.load(context)` — cố tình không
phải UUID, để nếu runtime bỏ qua phép gán và rơi về giá trị mặc định thì probe vẫn hiện ra một chuỗi
trông hợp lý và test sẽ pass sai. Kết quả:

```
runtime.id                    core            PASS         kiwix.harness.pinned-identity
```

Cộng với assert phía host trên `context.uniqueIdentifier`. Trong cùng log, WebKit cũng khoá storage nội
bộ của nó theo giá trị này (`[Extensions] Failed to release storage savepoint for extension
kiwix.harness.pinned-identity`), tức identifier không chỉ đi ra JavaScript mà còn là khoá partition
storage — đúng điều cần cho R-20.

Hai chi tiết còn mở: (1) log trên là một lỗi savepoint thật của WebKit lúc teardown controller
non-persistent, chưa rõ có ảnh hưởng gì ngoài test, chưa đo; (2) chưa có đường cài production nào dùng
tới, nên tính đúng đắn của thứ tự gán trong installer vẫn là việc của M4.

Lưu ý phạm vi của phép đo: hai lần chạy trên là hai container simulator sạch khác nhau, nên nó chứng
minh **id mặc định không bền qua cài mới**. Chưa chứng minh id đổi khi app khởi động lại với cùng
container.

## Phát hiện quan trọng nhất: MV3 `service_worker` không khởi động

Fixture riêng `Tests/Fixtures/WebExtensions/ServiceWorkerProbe/` khai báo `background.service_worker`.
Kết quả:

```
service_worker: WKWebExtension accepted the manifest.
service_worker: hasBackgroundContent=true
service_worker: errors=[]
service_worker: background content never started (no callback in 15s).
```

Đọc kỹ: manifest **được chấp nhận, không một lỗi nào**, `hasBackgroundContent` trả `true`, nhưng
`loadBackgroundContent` **không bao giờ gọi completion handler** — không lỗi, không timeout từ runtime,
chỉ im lặng vĩnh viễn.

Hệ quả thực tế:

1. **Không dùng `background.service_worker`.** Dùng `background.scripts` + `persistent: false`. Harness
   chính chạy đúng cấu hình này và pass 42 probe. Kiểm chứng phụ: trong background page của harness,
   `hasServiceWorkerGlobal=false` và `hasWindowGlobal=true` — nó thật sự là event page, không phải worker.
2. **Mọi tín hiệu "manifest hợp lệ" đều nói dối ở trường hợp này.** `errors` rỗng và
   `hasBackgroundContent == true` đều không phải bằng chứng extension chạy được. Installer ở M4 phải
   phát hiện được ca này, nếu không người dùng cài một extension im lặng chết mà app báo thành công.
3. Phần lớn extension MV3 trên Chrome Web Store dùng `service_worker`. Đây là rủi ro tương thích lớn
   nhất của v1, không phải chuyện vài API lẻ. Đã ghi vào `RISKS.md`.

Đây cũng là lý do `loadBackgroundContent` có tham số `timeout:`: không có deadline thì caller treo cho
tới khi xcodebuild giết test ở 60s, và ta học được đúng con số không.

## Hai cảnh báo bắt buộc đọc

**1. Đây là simulator, không phải thiết bị thật.** DECISIONS §4.2.10 nói rõ kết quả simulator là smoke
test. `storage.sync` pass trên simulator **không** có nghĩa nó đồng bộ thật qua iCloud; hành vi request,
permission UI và hiệu năng đều phải đo lại trên thiết bị iOS 18.4+ đã provisioning. Cột "Thiết bị"
trong `DECISIONS.md` §4.1 vì thế vẫn là `CHƯA CHẠY` một cách trung thực.

**2. Baseline CI là iOS 18.5, không phải 18.4.** Runner GitHub Actions (macos-15 + Xcode 16.4) chỉ có
simulator 18.5. Nghĩa là ta **chưa** chứng minh được gì trên đúng 18.4 — con số tối thiểu mà
`project.yml` khai báo. Một API có ở 18.5 nhưng không có ở 18.4 sẽ lọt lưới. Cần một lần chạy 18.4
trước khi ký compatibility v1.

## Cách tái tạo

```bash
make project
make test 2>&1 | grep KIWIX_HARNESS_REPORT
```

Kỳ vọng đúng một dòng:

```
KIWIX_HARNESS_REPORT channel=native total=90 pass=42 fail=0 timeout=0 available=18 unsupported=26 skipped=4 json=/…/KiwiXHarness/webextension-api-matrix.json
```

Bảng đầy đủ và JSON máy đọc được nằm trong `build/Tests.xcresult` dưới tên attachment
`webextension-api-matrix.json` / `webextension-api-matrix.txt`, và ở đường dẫn `json=` trên đĩa.
