# M2 report — Runtime extension qua `WKWebExtensionController`

Milestone M2 gắn runtime extension của Apple vào browser và đo xem runtime đó thật sự làm được gì.
Đây là Path A theo ADR-001: WebKit sở hữu runtime, app chỉ cung cấp mô hình tab/window, câu trả lời
permission và các bề mặt UI. Không có dòng nào trong M2 parse manifest hay tự hiện thực `chrome.*`.

## Phạm vi đã hoàn thành

| Hạng mục | File | Ghi chú |
|---|---|---|
| Host sở hữu controller | `ExtensionBrowser/ExtensionHost/WebExtensionHost.swift` | Vòng đời context, session, chính sách permission |
| Delegate đầy đủ | `ExtensionBrowser/ExtensionHost/WebExtensionHost+Delegate.swift` | 12 callback + bộ đếm chứng minh runtime có gọi |
| Tab adapter | `ExtensionBrowser/ExtensionHost/WebExtensionTabAdapter.swift` | Đọc thẳng từ `TabManager`, không cache |
| Window adapter | `ExtensionBrowser/ExtensionHost/WebExtensionWindowAdapter.swift` | Một scene, một window (ADR-004) |
| Cổng quan sát tab | `ExtensionBrowser/Tabs/TabWebExtensionObserver.swift` | Giữ `TabManager` sạch WebKit-extension |
| Gắn controller vào web view | `ExtensionBrowser/BrowserCore/WebView/WebViewFactory.swift` | Chỉ tab thường, §7 |
| Khởi động runtime | `ExtensionBrowser/App/SceneDelegate.swift` | Dựng trước khi restore session |
| Kênh nhận báo cáo | `ExtensionBrowser/ExtensionHost/WebExtensionHarnessChannel.swift` | Native messaging, fallback beacon |
| Harness extension | `Tests/Fixtures/WebExtensions/APIHarness/` | MV3, tự viết, không copy bảng của ai |
| Fixture service worker | `Tests/Fixtures/WebExtensions/ServiceWorkerProbe/` | Trả lời riêng câu hỏi §2.4 |
| Test dựng bảng | `ExtensionBrowserTests/ExtensionHost/WebExtensionHarnessTests.swift` | In bảng, ghi JSON, đính artifact |

### Vì sao tab adapter đọc thẳng, không cache

Extension có thể nhắm vào một tab đã bị suspend. Nếu adapter cache `title`/`url` tại thời điểm tạo,
`tabs.query` sẽ trả về dữ liệu cũ cho đúng những tab mà người dùng ít đụng tới nhất. Mọi accessor
đều đi qua `TabManager` để trạng thái chỉ có một nguồn.

### Vì sao controller gắn ở `WKWebViewConfiguration`, không gắn sau

`WKWebViewConfiguration` bị **copy** lúc khởi tạo web view. Gán `webExtensionController` sau khi tạo
không có tác dụng. Vì thế nó nằm trong `WebViewConfigurationProvider.configuration(tabID:isPrivate:)`,
bên trong nhánh `if !isPrivate` — đây chính là chỗ thực thi ràng buộc §7 "extension tắt trong private
tab": tab riêng tư không nhận controller nên với extension chúng không tồn tại.

### Harness tự đo, không tin lời khai

Ba cơ chế để bảng kết quả không nói dối:

1. **Hai transport độc lập.** Harness thử `runtime.sendNativeMessage` trước; nếu không tới thì rơi
   xuống beacon `tabs.create` chia chunk base64url. Bản thân transport là một probe: nó cho biết
   native messaging có chạm được delegate hay không.
2. **`WebExtensionHostCallCounter`.** `WKWebExtensionControllerDelegate` toàn method optional, nên
   một chữ ký sai chỉ làm callback im lặng chứ không lỗi build. Bộ đếm ghi lại callback nào thật sự
   nổ, và test assert trên đó.
3. **`available` không phải `pass`.** Theo DECISIONS §4.2.5, sự tồn tại của property không phải bằng
   chứng API chạy. Feature detection ghi `available`; chỉ thao tác thật mới được `pass`.

## Cách chạy

```bash
# Dựng project (XcodeGen, không sửa .xcodeproj bằng tay)
make generate

# Chạy toàn bộ test trên simulator iOS 18.4+
make test
```

Chỉ chạy riêng harness:

```bash
xcodebuild test \
  -project ExtensionBrowser.xcodeproj \
  -scheme ExtensionBrowser \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.4' \
  -only-testing:ExtensionBrowserTests/WebExtensionHarnessTests
```

Lưu ý: runner CI (macos-15 + Xcode 16.4) **không có runtime 18.4**, chỉ có 18.5. Mọi số đo bên dưới là
18.5. Muốn đo đúng deployment floor mà `project.yml` khai báo thì phải cài thêm runtime 18.4 — chưa làm.

## Cách kiểm chứng

### 1. Bảng pass/fail lên console (DoD của M2)

```bash
make test 2>&1 | grep -A200 "WebExtension API matrix"
```

Kỳ vọng: một bảng cột cố định `API | AREA | STATUS | DETAIL`, phần `env` ở đầu có `osVersion`,
`deviceModel`, `hardwareIdentifier`, `isSimulator`, `extensionVersion`, `timestamp`, và dòng tổng kết
`total N pass N fail N timeout N available N unsupported N skipped N` ở cuối.

### 2. Dòng marker duy nhất (DECISIONS §4.2.4)

```bash
make test 2>&1 | grep KIWIX_HARNESS_REPORT
```

Kỳ vọng: đúng một dòng dạng

```
KIWIX_HARNESS_REPORT channel=<native|urlBeacon> total=… pass=… fail=… timeout=… available=… unsupported=… skipped=… json=/…/KiwiXHarness/webextension-api-matrix.json
```

`channel` cho biết transport nào thắng. `json=` là đường dẫn Application Support của artifact ổn định.

### 3. Artifact JSON trong xcresult

```bash
xcrun xcresulttool get object --legacy --path build/Tests.xcresult --format json \
  | grep -o "webextension-api-matrix.json"
```

Kỳ vọng: tìm thấy tên attachment. JSON dùng `sortedKeys` nên diff giữa hai lần chạy chỉ hiện thay đổi
hành vi, không hiện xáo trộn thứ tự khoá.

### 4. Runtime thật sự gọi ngược vào app

Test assert `host.delegateCalls.called("openNewTabUsing")`. Nếu chữ ký delegate sai, assert này đỏ
kèm danh sách callback đã nổ:

```
Delegate callbacks observed: didUpdateAction=1 focusedWindowFor=1 openNewTabUsing=1 openWindowsFor=1 sendMessage=2
```

### 5. Ràng buộc §7 vẫn đứng

```bash
make private-api      # không có private API
make ad-free          # không có ad SDK
```

Ngoài ra, kiểm tra bằng mắt rằng `configuration.webExtensionController` chỉ được gán trong nhánh
`if !isPrivate`:

```bash
grep -B4 "webExtensionController = webExtensionHost" ExtensionBrowser/BrowserCore/WebView/WebViewFactory.swift
```

## Kết quả đo

CI run `32223595806`: `** TEST SUCCEEDED **`, 143 test, 0 failure, 19.6s. Dòng marker:

```
KIWIX_HARNESS_REPORT channel=native total=90 pass=42 fail=0 timeout=0 available=18 unsupported=26 skipped=4
```

`channel=native` nghĩa là `runtime.sendNativeMessage` tới được delegate — transport dự phòng không cần
dùng tới. Runtime chạy trên **iOS 18.5** simulator (`arm64`, `isSimulator=true`), MV3, và cả `browser`
lẫn `chrome` đều tồn tại làm global.

Delegate thật sự bị runtime gọi ngược: `didUpdateAction=1 focusedWindowFor=1 openNewTabUsing=1
openWindowsFor=1 sendMessage=2`. Đây là bằng chứng chữ ký delegate đúng — với một protocol toàn method
optional thì đây là cách duy nhất biết được, vì sai chữ ký chỉ làm callback im lặng chứ không lỗi build.

Bốn kết quả đáng chú ý hơn con số tổng:

1. **MV3 `background.service_worker` không khởi động.** Manifest được chấp nhận, `errors=[]`,
   `hasBackgroundContent=true`, nhưng `loadBackgroundContent` không bao giờ gọi completion handler
   trong 15s. Không lỗi, chỉ im lặng. Bắt buộc dùng `background.scripts` + `persistent:false`. Phần
   lớn extension MV3 trên Chrome Web Store dùng `service_worker`, nên đây là rủi ro tương thích lớn
   nhất của v1 — đã ghi thành R-18 trong `RISKS.md`.
2. **Tab adapter chạy hết vòng.** `tabs.create/query/get/activate/remove` đều pass qua adapter thật, và
   bốn event `onCreated/onUpdated/onActivated/onRemoved` **thật sự nổ** chứ không chỉ đăng ký được.
   `tabs.activate` chuyển sang tab khác rồi quay lại, browser báo đúng cả hai lần. §5 gọi đây là phần
   rủi ro nhất, và nó đứng vững.
3. **`webRequest` blocking chấp nhận `extraInfoSpec` nhưng không chứng minh thêm được gì.** Ghi
   `available`, không phải `pass`. Tương tự, `declarativeNetRequest` nạp được static ruleset và dynamic
   rules nhưng **chặn thật chưa đo** — cần test server nội bộ, đẩy sang M3.
   *Cập nhật sau M3 (run `32236350621`): đã đo. Không chặn gì cả, và `webRequest` không nổ lần nào —
   xem `COMPATIBILITY.md` và R-21. Đoạn trên giữ nguyên vì đây là báo cáo trạng thái M2.*
4. **Không có dòng `fail` nào.** Lần chạy trước có 1 fail ở `webNavigation.getAllFrames`, truy ra là
   probe của chính harness truyền `tabId: -1` (`TAB_ID_NONE`) và bị runtime từ chối đúng. Sửa xong thì
   pass. Nói ra vì báo cáo một lỗi của mình như giới hạn của WebKit thì tệ hơn là không đo.
5. **`runtime.id` đổi giữa hai lần cài.** Cùng một fixture không đổi một byte, hai lần chạy CI trả về
   hai UUID khác nhau. Runtime cấp id mỗi lần cài chứ không suy ra từ `key` như Chrome, nên M4/M5
   không được dùng `runtime.id` làm khoá lưu trữ hay khoá permission. Chi tiết ở `COMPATIBILITY.md`.
6. **26 namespace không tồn tại**, trong đó có `notifications`, `debugger`, `proxy`, `devtools`,
   `userScripts`, `webRequest.filterResponseData`, `commands`, `sidePanel`, `management`, `identity`.

Bảng 90 dòng và phân tích theo nhóm nằm ở `COMPATIBILITY.md`; kết luận rút gọn đã thay thế toàn bộ ô
`CHƯA CHẠY` ở cột simulator trong `DECISIONS.md` §4.1. Cột thiết bị vẫn `CHƯA CHẠY`.

## Khoảng trống đã ghi nhận, không che

Ba mục dưới đây lệch so với contract DECISIONS §4.2. Chúng được ghi thành `skipped`/`available` trong
chính bảng kết quả chứ không bị bỏ qua im lặng.

| Yêu cầu §4.2 | Trạng thái M2 | Lý do |
|---|---|---|
| DNR phải xác nhận request bị block bằng quan sát thật | `declarativeNetRequest.enforcement` = `skipped` | Trang harness do `loadSimulatedRequest` phục vụ, không có origin subresource nào dự án kiểm soát. Một host `.test` sẽ fail DNS, nên kết quả "bị block" không phân biệt được với "không phân giải được tên". Cần test server nội bộ — đẩy sang M3. |
| Probe popup phải kiểm tra nội dung render | Chưa có | `presentActionPopup` hiện trả `actionPopupUnsupported`; UI popup là phạm vi M3. |
| Fixture MV2 riêng cho probe cần persistent background | Chưa có | M2 chỉ cần trả lời MV3 + service worker. Sẽ thêm khi có probe thật sự cần persistent background. |
| Trang của chính extension mở được trong tab | **Chưa làm** | Apple nói rõ với `WKWebExtensionContext.webViewConfiguration`: *"The app must use this configuration when initializing web views intended to navigate to a URL originating from this extension's base URL. The app must also swap web views in tabs when navigating to and from web extension URLs."* Hiện `WebViewConfigurationProvider` không đụng tới nó ở bất kỳ đâu, nên điều hướng tới `webkit-extension://…` sẽ hỏng. Ảnh hưởng options page, popup mở dạng tab và override new tab page — tất cả đều là M3. |

`webRequest.onBeforeRequest.register` cố tình chỉ đạt `available`: đăng ký listener thành công không
chứng minh có traffic đi qua nó. Riêng `webRequest.blocking.accepted` là probe thật vì việc runtime có
chấp nhận `extraInfoSpec` `"blocking"` hay không trả lời được mà không cần traffic.

## Định nghĩa hoàn thành M2

| Tiêu chí | Trạng thái |
|---|---|
| Gắn `WKWebExtensionController` vào `WKWebViewConfiguration` | Xong |
| Load được một extension đóng gói sẵn | Xong |
| Tab adapter tối thiểu | Xong — create/query/get/activate/close đi xuyên adapter thật |
| Harness chạy, in bảng pass/fail lên console | Xong |
| Build xanh | Xong — CI run `32223595806`, 143 test, 0 failure (xem mục Kết quả đo) |

## Cảnh báo về giá trị của kết quả

Theo DECISIONS §4.2.10, mọi con số trong lần chạy này đến từ **simulator** và chỉ là smoke test.
`storage.sync`, hành vi request, permission UI và hiệu năng phải được đo lại trên thiết bị iOS 18.4+
thật trước khi được coi là kết luận. Trường `isSimulator` trong JSON tồn tại để không ai đọc nhầm.
