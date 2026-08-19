# Quyết định kiến trúc KiwiX / ExtensionBrowser v3

Trạng thái: **ĐÃ DUYỆT — M0 CI xanh; DoD thiết bị chờ signing/provisioning**
Cập nhật: 2026-08-17

Tài liệu này là cổng quyết định bắt buộc trước khi sửa runtime hiện tại hoặc bắt đầu M0. Các mục ghi
`CHƯA CHẠY` không được diễn giải thành kết quả tương thích.

## 1. Baseline của repository

> **Ảnh chụp lúc ra quyết định (trước M0), giữ nguyên để đối chiếu — không phải trạng thái hôm nay.**
> Tính đến cuối M2: deployment target đã là 18.4 (`project.yml`), `WKWebExtension`/
> `WKWebExtensionContext`/`WKWebExtensionController` đã có và chạy, repo đã có commit và remote.
> Runtime `chrome.*` tự viết (`ExtensionKit/`) và UI quản lý của nó (`ExtensionUI/`) **đã bị gỡ khỏi
> production path** — xem §2.1. Không còn điểm nào trong ảnh chụp này còn đúng.

Repository hiện tại là PoC theo hướng cũ:

- deployment target đang là iOS 17.0;
- app tự parse manifest, inject `WKUserScript` và giả lập một phần `chrome.*`;
- `WebViewConfigurationProvider` còn dùng `WKProcessPool`;
- chưa có `WKWebExtension`, `WKWebExtensionContext` hoặc `WKWebExtensionController`;
- Git repository chưa có commit và chưa cấu hình remote;
- máy làm việc hiện tại là Windows, không có Xcode hay iOS Simulator, nên chưa có bằng chứng build/run Apple nào.

Vì vậy code hiện tại **không phải baseline v3**. Có thể giữ lại phần app shell, tab/session, history,
installer safety và một phần UI sau khi review; compatibility runtime tự viết không được tiếp tục mở rộng.

## 2. ADR-001 — Chọn Path A

Quyết định: **Path A — dùng runtime `WKWebExtension` của WebKit, min iOS/iPadOS 18.4.**

Lý do:

1. WebKit công bố bộ `WKWebExtension`, `WKWebExtensionContext` và
   `WKWebExtensionController` cho browser nhúng extension từ iOS/iPadOS 18.4.
2. `WKWebViewConfiguration.webExtensionController` là public API và configuration chỉ có hiệu lực
   khi tạo web view.
3. Tự duy trì runtime WebExtensions là sai trọng tâm của sản phẩm và tạo thêm bề mặt bảo mật lớn.
4. Alternative browser engine entitlement không phải đường phân phối IPA sideload chung; Path A vẫn
   dùng WebKit hệ thống.

Hệ quả được chấp nhận nếu phê duyệt:

- bỏ hỗ trợ iOS < 18.4;
- không hỗ trợ TrollStore: dự án TrollStore chỉ liệt kê tới iOS 17.0 và nói 17.0.1+ không được hỗ trợ
  nếu không xuất hiện CoreTrust bug mới;
- không hứa 100% Chrome/Firefox WebExtensions API;
- loại runtime `chrome.*` tự viết khỏi production path; chỉ giữ fixture/harness độc lập nếu cần test;
- extension trong private tab mặc định tắt và dùng controller/data store non-persistent riêng nếu sau
  này cho phép opt-in.

Nguồn:

- [WebKit Features in Safari 18.4](https://webkit.org/blog/16574/webkit-features-in-safari-18-4/)
- [`WKWebExtensionController`](https://developer.apple.com/documentation/webkit/wkwebextensioncontroller)
- [`WKWebViewConfiguration.webExtensionController`](https://developer.apple.com/documentation/webkit/wkwebviewconfiguration/webextensioncontroller)
- [`WKWebExtension.init(resourceBaseURL:)`](https://developer.apple.com/documentation/webkit/wkwebextension/init(resourcebaseurl:))
- [Alternative browser engines in the EU](https://developer.apple.com/support/alternative-browser-engines/)
- [TrollStore supported versions](https://github.com/opa334/TrollStore)

### 2.1 Thực thi — dọn Path B (cuối M2)

Hai runtime song song là một lời nói dối về kiến trúc: đọc code không biết cái nào đang chạy thật.
Quét phụ thuộc 27 symbol cho thấy `ExtensionKit/` là một đồ thị liên thông, không có ranh giới nào cắt
được để giữ một phần cho gọn. Nên xoá cả cụm.

**Xoá** (~5.500 dòng): `ExtensionBrowser/ExtensionKit/` (20 file — manifest parser, match pattern,
permission manager, storage, repository, API registry, content-script injector, resource limits, bridge
JS, message codec), `ExtensionBrowser/ExtensionUI/` (7 file — manager view/viewmodel, action
coordinator, popup provider + network isolation, permission list), `Shared/BrowserExtensionIntegration.swift`
(seam Path B), `Shared/WebViewUserScriptRegistry.swift` (hết consumer), và 11 file test tương ứng
(67 test).

**Giữ**, chuyển sang `ExtensionHost/Install/`: `SafeZIPExtractor`, `ExtensionIdentity`,
`ExtensionResourcePath`, cùng `ExtensionInstallModels` (tách ra từ vốn từ lỗi cũ). Lý do: CRX3 ở M4 vẫn
phải giải nén một archive ra thư mục trước khi `WKWebExtension(resourceBaseURL:)` đọc được, và đây là
chỗ chặn package độc ghi ra ngoài thư mục của nó. Không file nào trong đó đọc manifest.

**Mất năng lực, ghi rõ để không tự lừa mình** — các bất biến sau mất điểm cưỡng chế trong app, và giờ
phụ thuộc hoàn toàn vào WebKit, chưa đo:

| Bất biến cũ | Trước | Sau |
|---|---|---|
| Permission fail-closed, grant hẹp hơn declaration | `ExtensionPermissionManager` + UI grant/revoke | `WebExtensionPermissionPolicy` chỉ có `trustFirstPartyBundle` / `denyAll`; UI dựng lại ở M4 |
| Quota storage 5 MiB/extension | `ExtensionLocalStorage` | WebKit quản, chưa đo |
| Giới hạn IPC/rate limit/script budget | `ExtensionResourceLimits` | WebKit quản, chưa đo |
| Match pattern đúng theo spec | `WebExtensionMatchPattern` + 7 test | `WKWebExtension.MatchPattern`, chưa đo |
| Popup deny-all network | `ExtensionPopupNetworkIsolation` | Chưa có popup; M4 |
| UI xác nhận permission trước install (§7) | `ExtensionManagerView` | **Không còn**. M4 phải dựng lại trước khi có bất kỳ đường cài extension nào cho người dùng |

Hệ quả trực tiếp: **không có đường nào để người dùng cài extension** cho tới M4. Chỉ fixture bundled
chạy qua harness. Đây là trạng thái an toàn hơn trạng thái cũ (không có bề mặt cài), không phải hồi quy
bị che.

Số test: 143 → 76.

## 3. ADR-002 — Kênh ký và phân phối

Trạng thái: **ĐÃ CHỌN APPLE DEVELOPER PROGRAM LÀM KÊNH CHÍNH**.

Khuyến nghị: **Apple Developer Program (99 USD/năm) làm kênh chính**, vì mục tiêu là IPA lặp lại
được qua CI và test thường xuyên trên thiết bị. AltStore Classic/SideStore chỉ là kênh dev/fallback.

| Lựa chọn | Ưu điểm | Giới hạn | Quyết định |
|---|---|---|---|
| Apple Developer Program | signing/CI ổn định hơn; membership theo năm | 99 USD/năm; vẫn cần certificate/profile đúng | **Đã chọn** |
| AltStore Classic / SideStore với Apple Account miễn phí | không cần mua membership để thử | app hết hạn sau 7 ngày và phải refresh; giới hạn sideload | Fallback |

Nguồn:

- [Apple Developer Program enrollment](https://developer.apple.com/programs/enroll/)
- [AltStore Classic: app hết hạn sau 7 ngày](https://faq.altstore.io/altstore-classic/your-altstore)
- [SideStore installation/refresh](https://docs.sidestore.io/docs/installation/install)

AltStore/SideStore vẫn là fallback cho build thử, không phải kênh nghiệm thu chính.

## 4. ADR-003 — Cách kiểm chứng API surface

Quyết định: **không copy bảng kỳ vọng trong spec thành kết quả**. Mỗi API phải được probe bởi extension
harness, lưu kết quả máy đọc được và có bằng chứng OS/device.

### 4.1 Ma trận hiện tại

Nguồn: harness tự viết chạy trong runtime thật, CI run `32223595806` (xanh, 143 test, 0 failure).
**Simulator iOS 18.5** — runner chỉ có 18.5, nên cột dưới đây chưa chứng minh gì trên đúng 18.4.
Bảng probe đầy đủ 90 dòng nằm ở `COMPATIBILITY.md`.

| Nhóm API | Simulator (18.5) | Thiết bị iOS 18.4+ | Kết luận hiện tại |
|---|---|---:|---|
| `runtime` | PASS | CHƯA CHẠY | Đủ dùng. `getPlatformInfo.os` = `ios`; URL scheme là `webkit-extension://`; id là UUID do runtime cấp |
| `storage.local` | PASS | CHƯA CHẠY | Round-trip set/get/remove |
| `storage.sync` | PASS (API) | CHƯA CHẠY | API chạy, **ngữ nghĩa đồng bộ chưa chứng minh** — cần thiết bị thật |
| `tabs` | PASS | CHƯA CHẠY | create/query/get/activate/remove xuyên adapter thật; 4 event thật sự nổ |
| `scripting` | PASS | CHƯA CHẠY | `executeScript` + `insertCSS` vào tab thật |
| `action` / popup / badge | MỘT PHẦN | CHƯA CHẠY | `setBadgeText`/`setTitle` pass, delegate `didUpdateAction` nổ. **Popup chưa đo** — `presentActionPopup` hiện app tự từ chối, là phạm vi M3 |
| `i18n` | MỘT PHẦN | CHƯA CHẠY | Mới đo `getUILanguage` = `en-US` |
| `declarativeNetRequest` | MỘT PHẦN | CHƯA CHẠY | Static ruleset nạp được, dynamic rules thêm/đọc được. `getAvailableStaticRuleCount` không tồn tại. **Chặn thật chưa đo** (cần test server, M3) |
| `webRequest` quan sát | AVAILABLE | CHƯA CHẠY | Đăng ký listener được, **chưa chứng minh có traffic đi qua**. Không tính là pass |
| `webRequest` blocking | AVAILABLE | CHƯA CHẠY | `extraInfoSpec: ["blocking"]` được chấp nhận lúc đăng ký. Chấp nhận ≠ chặn được; `filterResponseData` không tồn tại |
| `notifications` | KHÔNG CÓ | — | Namespace vắng mặt, `notifications.create` là `undefined` |
| `nativeMessaging` | PASS | CHƯA CHẠY | `sendNativeMessage` tới được `WKWebExtensionControllerDelegate` — đây là transport của chính harness |
| `debugger`, `proxy`, `devtools_*` | KHÔNG CÓ | — | Cả ba đều vắng mặt |

Ngoài bảng trên, một kết quả không thuộc nhóm API nào nhưng quan trọng hơn tất cả:
**MV3 `background.service_worker` được chấp nhận không lỗi, `hasBackgroundContent` trả `true`, nhưng
background content không bao giờ khởi động** (`loadBackgroundContent` không gọi completion handler
trong 15s). Bắt buộc dùng `background.scripts` + `persistent: false`. Chi tiết và hệ quả ở
`COMPATIBILITY.md`; rủi ro tương thích ở `RISKS.md`.

### 4.2 Contract của harness

Harness ở milestone kế tiếp phải là fixture extension riêng, không dùng compatibility bridge hiện tại.
Nó phải:

1. probe từng API bằng feature detection và ít nhất một thao tác thật;
2. phân biệt `available`, `pass`, `fail`, `timeout`, `not_applicable`;
3. ghi `osVersion`, model/simulator, manifest version, extension version và timestamp;
4. xuất JSON ổn định vào Application Support và in một dòng marker duy nhất vào console;
5. không coi sự tồn tại của property là bằng chứng API hoạt động;
6. reset state giữa test, đặc biệt với storage, permission và DNR dynamic rules;
7. có timeout cho service worker/background event và request observation;
8. đính kèm JSON vào XCTest/CI artifact;
9. chạy MV3 trước; thêm fixture MV2 riêng chỉ cho probe cần persistent background;
10. đánh dấu kết quả simulator là smoke test; `storage.sync`, request behavior, permission UI và hiệu
    năng phải được xác nhận lại trên thiết bị thật.

Probe DNR phải dùng một test server/fixture URL do dự án kiểm soát và xác nhận request bị block hoặc
redirect bằng quan sát mạng/trang, không chỉ dựa vào Promise resolve. Probe `tabs` phải đi xuyên qua
tab adapter thật và kiểm tra create/query/activate/close. Probe popup phải kiểm tra nội dung render và
thay đổi state có hiệu lực lên trang test.

### 4.3 Trình tự triển khai và lệnh kiểm chứng

Spec yêu cầu chạy harness trước M0 nhưng harness runtime lại phụ thuộc controller/tab adapter của M2.
Quyết định triển khai là: M0 dựng CI/Xcode toolchain trước; M1 giữ app shell xanh; M2 mới tích hợp
`WKWebExtension` và chạy harness. Đây là dependency kỹ thuật, không phải miễn trừ kiểm chứng. M2 không
được hoàn thành nếu thiếu report simulator; compatibility v1 không được ký nếu thiếu report thiết bị.

Các lệnh dưới đây là Definition of Done cho harness. **Đã chạy xanh ở M2** (CI run `32223595806`),
nhưng trên simulator 18.5 chứ không phải 18.4:

```bash
xcodegen generate --spec project.yml
xcodebuild \
  -project ExtensionBrowser.xcodeproj \
  -scheme ExtensionBrowser \
  -destination 'platform=iOS Simulator,name=<iPhone>,OS=18.4' \
  -resultBundlePath build/WebExtensionHarness.xcresult \
  test
```

Kết quả kỳ vọng:

- build/test xanh;
- `build/WebExtensionHarness.xcresult` chứa JSON report;
- không còn ô `CHƯA CHẠY` cho cột simulator (đạt ở M2);
- job fail nếu report thiếu probe, crash, timeout hoặc ghi `pass` mà không có assertion hành vi.

Sau đó chạy cùng harness trên thiết bị iOS 18.4+ đã provisioning. Chỉ cập nhật cột thiết bị khi report
có model, OS build và artifact; không dùng Appetize hay simulator thay bằng chứng thiết bị thật.

## 5. ADR-004 — Thiết kế tab/window adapter

Rủi ro kỹ thuật số 1 là giữ identity và lifecycle nhất quán giữa model của app và WebKit.

### 5.1 Identity và ownership

- Mỗi `Tab.id: UUID` ánh xạ 1:1 tới đúng một object adapter kế thừa `NSObject` và conform
  `WKWebExtensionTab` trong suốt vòng đời logical tab.
- Suspend chỉ giải phóng `WKWebView`; **không** hủy adapter hoặc đổi identity.
- `TabManager` sở hữu registry `[UUID: TabAdapter]`; adapter giữ tham chiếu yếu về manager để tránh
  cycle và không tự sửa mảng tab.
- Một app scene ở v1 ánh xạ tới một `WindowAdapter` conform `WKWebExtensionWindow`. Multi-window là
  non-goal cho tới khi adapter một cửa sổ qua harness.
- Normal/private tab không được trộn trong cùng permission state. Private extension controller chỉ
  được tạo khi có opt-in rõ ràng; mặc định private trả về tập extension rỗng.

### 5.2 Ánh xạ hành vi

| WebExtension yêu cầu | Nguồn sự thật của app | Hành vi khi tab suspended |
|---|---|---|
| tab ID / index / active / selected | `TabManager.tabs` và `selectedTabID` | Trả metadata hiện có, không đánh thức web view |
| title / URL | `Tab` persisted metadata | Trả snapshot metadata gần nhất |
| activate / select | `TabManager.selectTab` | Tạo web view rồi restore/navigate theo lifecycle hiện có |
| close | `TabManager.closeTab` | Đóng logical tab và báo controller đúng một lần |
| duplicate / create | `TabManager.createTab` + navigation | Tạo adapter trước khi phát event open |
| reload / navigate / go back-forward | live `WKWebView` | Resume tab trước; completion chỉ trả sau khi request được nhận hoặc lỗi |
| capture visible tab | selected live `WKWebView` | Từ chối nếu không active; không dùng snapshot cũ như ảnh chụp mới |

### 5.3 Event ordering

- Tạo tab: mutate model → tạo/register adapter → notify controller `didOpenTab` → select nếu cần →
  notify activation.
- Đóng tab: chụp adapter hiện tại → mutate model/chọn replacement → notify close đúng một lần → xóa
  adapter khỏi registry sau callback.
- Đổi URL/title/loading: cập nhật model trước, sau đó gửi `didChangeTabProperties` với đúng bitmask.
- Suspend/resume không phải close/open và không được phát event giả.
- Mọi call vào WebKit controller và adapter chạy trên `@MainActor`.

Các Swift signature cụ thể phải được compiler của Xcode SDK xác nhận; tài liệu này cố ý không bịa
method signature chưa compile.

Nguồn:

- [`WKWebExtensionTab`](https://developer.apple.com/documentation/webkit/wkwebextensiontab)
- [`WKWebExtensionWindow`](https://developer.apple.com/documentation/webkit/wkwebextensionwindow)
- [`WKWebExtensionController` lifecycle notifications](https://developer.apple.com/documentation/webkit/wkwebextensioncontroller)
- [`WKWebExtensionContext.webViewConfiguration`](https://developer.apple.com/documentation/webkit/wkwebextensioncontext/webviewconfiguration)

## 6. Gate trước M0

Chỉ chuyển sang M0 khi tất cả điều kiện sau đúng:

- [x] Chủ dự án phê duyệt Path A và min iOS 18.4.
- [x] Chọn Apple Developer Program làm kênh chính; AltStore/SideStore là fallback.
- [x] macOS/Xcode qua GitHub Actions tại repository private của dự án.
- [ ] Harness chạy xanh trên simulator iOS 18.4+ và report được lưu làm artifact.
- [x] Thiết bị nghiệm thu: iPhone XS, iOS 18.7.9.
- [x] `RISKS.md` được chấp nhận làm risk register ban đầu; cập nhật theo milestone.

## 7. Câu hỏi cần chủ dự án quyết

1. GitHub remote private đã tạo: <https://github.com/phucthinhvn122/KiwiX>.
2. Certificate `.p12` và provisioning profile của Apple Developer Program vẫn phải được chủ tài khoản
   Apple cấp qua GitHub Actions secrets; không thể tự sinh hợp lệ chỉ từ repository.
