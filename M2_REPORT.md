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
make project

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
Delegate callbacks observed: focusedWindowFor=1 openNewTabUsing=2 openWindowsFor=1 promptForPermissions=1
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

> Điền từ lần chạy CI xanh gần nhất. Xem `COMPATIBILITY.md` cho bảng đầy đủ và `DECISIONS.md` §4.1
> cho kết luận theo nhóm API.

## Khoảng trống đã ghi nhận, không che

Ba mục dưới đây lệch so với contract DECISIONS §4.2. Chúng được ghi thành `skipped`/`available` trong
chính bảng kết quả chứ không bị bỏ qua im lặng.

| Yêu cầu §4.2 | Trạng thái M2 | Lý do |
|---|---|---|
| DNR phải xác nhận request bị block bằng quan sát thật | `declarativeNetRequest.enforcement` = `skipped` | Trang harness do `loadSimulatedRequest` phục vụ, không có origin subresource nào dự án kiểm soát. Một host `.test` sẽ fail DNS, nên kết quả "bị block" không phân biệt được với "không phân giải được tên". Cần test server nội bộ — đẩy sang M3. |
| Probe popup phải kiểm tra nội dung render | Chưa có | `presentActionPopup` hiện trả `actionPopupUnsupported`; UI popup là phạm vi M3. |
| Fixture MV2 riêng cho probe cần persistent background | Chưa có | M2 chỉ cần trả lời MV3 + service worker. Sẽ thêm khi có probe thật sự cần persistent background. |

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
| Build xanh | Xem mục Bằng chứng CI |

## Cảnh báo về giá trị của kết quả

Theo DECISIONS §4.2.10, mọi con số trong lần chạy này đến từ **simulator** và chỉ là smoke test.
`storage.sync`, hành vi request, permission UI và hiệu năng phải được đo lại trên thiết bị iOS 18.4+
thật trước khi được coi là kết luận. Trường `isSimulator` trong JSON tồn tại để không ai đọc nhầm.
