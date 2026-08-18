# KiwiX — ExtensionBrowser v3

> Trạng thái: runtime hiện tại là compatibility layer `chrome.*` giới hạn, min iOS 18.4, đã được
> harden theo contract trong `docs/ARCHITECTURE.md`. `WKWebExtension` vẫn là một quyết định migration
> tương lai trong `DECISIONS.md`, không phải implementation hay bằng chứng compatibility hiện tại.

Các quyết định đã chốt nằm trong [DECISIONS.md](DECISIONS.md), rủi ro và stop-ship conditions nằm
trong [RISKS.md](RISKS.md). Bằng chứng build/test M0 và gate còn lại nằm trong
[M0_REPORT.md](M0_REPORT.md).

ExtensionBrowser là proof-of-concept browser native cho iPhone, viết bằng Swift, UIKit và WebKit. MVP tập trung vào browser nhiều tab có quản lý bộ nhớ và một compatibility layer nhỏ cho WebExtensions: nhập ZIP Manifest V3, kiểm tra package, cài đặt, match URL rồi inject content script JavaScript/CSS.

Repository được thiết kế để phát triển từ Windows: sửa code bằng VS Code, push lên GitHub, và để GitHub Actions macOS sinh Xcode project, chạy test, tạo build Simulator cùng artifact device. Không cần Mac local cho vòng lặp phát triển thông thường; tuy nhiên Apple vẫn yêu cầu Xcode/macOS ở bước compile và yêu cầu certificate/provisioning profile hợp lệ để tạo IPA cài được.

> Trạng thái kiểm chứng: source, project spec, scripts và workflow được tạo/kiểm tra tĩnh trên Windows. Compile/test thực tế phải được xác nhận bởi lần chạy GitHub Actions macOS đầu tiên; repository không tuyên bố đã build IPA cục bộ trên Windows.

## Luồng phát triển từ Windows

```text
Windows + VS Code
      |
      | git push / pull request
      v
GitHub Actions (macOS + Xcode + XcodeGen 2.46.0)
      |------------------------------|
      v                              v
test + Simulator build              device archive
ExtensionBrowser-Simulator.zip      unsigned artifacts luôn có
      |                              signed IPA khi đủ secrets
      v                              v
Appetize (tùy chọn)                 iPhone / công cụ re-sign
```

Apple iOS Simulator không chạy native trên Windows. `ExtensionBrowser-Simulator.zip` chứa đúng bundle `ExtensionBrowser.app` để tải lên dịch vụ simulator như Appetize; file này không phải ứng dụng Windows và không cài lên iPhone thật.

## Yêu cầu

Trên máy Windows:

- Windows 10/11, Git, PowerShell và editor như VS Code.
- Repository GitHub có Actions được bật.
- Không cần cài Xcode, Swift hay XcodeGen trên Windows.
- Để cài lên iPhone: Apple Developer signing assets phù hợp hoặc một quy trình re-sign/sideload do bạn tự quản lý.

CI dùng runner `macos-15`, pin Xcode 16.4 qua `DEVELOPER_DIR`, Swift Package Manager và XcodeGen `2.46.0`. Binary XcodeGen được tải từ release chính thức và kiểm tra SHA-256 trước khi chạy. `ZIPFoundation` được khóa ở `0.9.20` trong `project.yml`; GitHub Actions bên thứ ba được pin bằng commit SHA.

## Bắt đầu nhanh

```powershell
git clone <repository-url>
Set-Location ExtensionBrowser
git checkout -b feature/my-change
code .
```

Sau khi sửa code:

```powershell
git add .
git commit -m "Describe the change"
git push -u origin feature/my-change
```

Mở pull request để workflow **Build Simulator** compile và chạy unit tests. Xem tab **Actions** trong repository để theo dõi log Xcode thực tế.

## Cấu trúc repository

```text
.
|-- .github/workflows/
|   |-- ci.yml
|   `-- build-device.yml
|-- docs/ARCHITECTURE.md
|-- Examples/HelloExtension/
|-- ExtensionBrowser/
|   |-- App/
|   |-- BrowserCore/
|   |-- Tabs/
|   |-- ExtensionKit/
|   |-- ExtensionUI/
|   |-- History/
|   |-- Settings/
|   |-- Shared/
|   `-- Resources/
|-- ExtensionBrowserTests/
|-- scripts/ci/
|-- project.yml
`-- README.md
```

`project.yml` là source of truth cho Xcode project; file `.xcodeproj` sinh ra không được commit. Chi tiết dependency, boundary, luồng extension, tab lifecycle và security nằm trong [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Kiến trúc ở mức cao

- `BrowserCore`: UIKit browser shell, address/search parsing, `WKWebView` configuration và navigation.
- `Tabs`: model/session store, tạo/chọn/đóng tab, snapshot và lifecycle `ACTIVE` / `WARM` / `SUSPENDED`.
- `ExtensionKit`: manifest parser/validator, ZIP installer, deterministic extension ID, URL matcher, permission gate, storage namespace, content-script injection và bridge message.
- `ExtensionUI`: Files picker, preview permission trước khi install, danh sách bật/tắt/xóa extension và details.
- `Settings`: search engine built-in/custom và thông tin privacy. `History` có actor store + màn hình xem/xóa/mở lại; `Downloads` nhận file trực tiếp từ WebKit, hiển thị tiến độ và cho phép mở/xóa file.
- `Shared`: logging, signpost, diagnostics và boundary hẹp giữa browser với extension runtime.

Normal tabs dùng persistent website data store và chia sẻ process pool. Private tabs dùng non-persistent store/process pool riêng, không ghi history/session và không cấu hình extension runtime trong MVP.

Browser MVP hiện có start page KiwiX, bottom toolbar hai hàng Back/Forward, address-or-search, Reload/Stop, tab count và menu; progress KVO, page title/URL tracking, Share, Open in External App, History, Downloads, lỗi navigation + Retry, JavaScript alert/confirm/prompt và mở `target=_blank` thành tab mới. Tab switcher hiển thị snapshot/lifecycle, normal session được persist; memory warning snapshot rồi release toàn bộ background web view. Debug build có metrics URL/tab/live web-view/navigation/memory cùng extension diagnostics khi runtime đã đăng ký.

## GitHub Actions

### Simulator: build và test trên mọi push/PR

[`.github/workflows/ci.yml`](.github/workflows/ci.yml) thực hiện:

1. Kiểm tra toolchain Apple trên `macos-15`.
2. Tải XcodeGen `2.46.0`, xác minh checksum, rồi generate `ExtensionBrowser.xcodeproj`.
3. Chọn một iPhone Simulator có sẵn thay vì hardcode tên device/runtime.
4. Chạy toàn bộ `ExtensionBrowserTests`.
5. Build cấu hình Release cho `iphonesimulator` với signing tắt.
6. Kiểm tra bundle và đóng gói `ExtensionBrowser-Simulator.zip` với `ExtensionBrowser.app` ở root ZIP.
7. Upload artifact **ExtensionBrowser-Simulator**. Nếu test thất bại, workflow cố upload `.xcresult` để chẩn đoán.

Để tải build: mở **Actions > Build Simulator > run cần dùng > Artifacts > ExtensionBrowser-Simulator**. Giải nén artifact GitHub một lần để lấy `ExtensionBrowser-Simulator.zip`; giữ nguyên ZIP bên trong khi upload lên Appetize.

Appetize là tùy chọn:

- Không có `APPETIZE_API_TOKEN`: step được skip và workflow vẫn pass.
- Có token: push hoặc manual run sẽ gọi API upload; pull request luôn skip để không đưa secret vào code chưa tin cậy.
- Có thêm `APPETIZE_PUBLIC_KEY`: workflow update app đó. Không có public key: workflow tạo app mới.
- Token sai hoặc API upload lỗi: step fail rõ ràng, không nuốt lỗi.

### Device: unsigned luôn có, signed khi đủ secrets

[`.github/workflows/build-device.yml`](.github/workflows/build-device.yml) chạy trên push hoặc manual dispatch:

- Luôn archive `iphoneos` với code signing tắt và upload artifact **ExtensionBrowser-Unsigned-Device** gồm:
  - `ExtensionBrowser-Unsigned.ipa`: ZIP theo layout `Payload/ExtensionBrowser.app`, nhưng không có Apple signature/provisioning profile dùng được.
  - `ExtensionBrowser-Unsigned.xcarchive.zip`: phù hợp hơn cho các công cụ re-sign/export.
- Khi cả sáu signing secrets đều có, workflow tạo keychain tạm, kiểm tra team/bundle của profile, archive có ký, sinh `ExportOptions.plist` an toàn và upload **ExtensionBrowser-Signed-IPA/ExtensionBrowser.ipa**.
- Nếu không có signing secret nào, unsigned build thành công và signed export được skip có thông báo.
- Nếu chỉ có một phần secrets, unsigned artifact vẫn được upload nhưng job kết thúc lỗi, đồng thời liệt kê tên secrets còn thiếu trong workflow summary.

Unsigned IPA không thể cài trực tiếp. Signed IPA chỉ cài được trên thiết bị/môi trường được provisioning profile cho phép. Với `development`, thiết bị phải thuộc development profile; với `ad-hoc`, UDID phải nằm trong ad-hoc profile.

## Cấu hình signing

Tạo repository secrets tại **Settings > Secrets and variables > Actions**:

| Secret | Nội dung |
|---|---|
| `BUILD_CERTIFICATE_BASE64` | Toàn bộ file `.p12` mã hóa Base64 |
| `P12_PASSWORD` | Mật khẩu export của `.p12` |
| `PROVISIONING_PROFILE_BASE64` | File `.mobileprovision` mã hóa Base64 |
| `KEYCHAIN_PASSWORD` | Chuỗi ngẫu nhiên mạnh, chỉ dùng cho keychain tạm của CI |
| `APPLE_TEAM_ID` | Team ID trong provisioning profile/certificate |
| `BUNDLE_IDENTIFIER` | Bundle ID được profile cho phép, ví dụ `com.example.ExtensionBrowser` |

Mã hóa file trên PowerShell mà không tạo bản copy chứa text:

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\secure\certificate.p12")) | Set-Clipboard
[Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\secure\profile.mobileprovision")) | Set-Clipboard
```

Không commit `.p12`, `.mobileprovision`, mật khẩu hoặc chuỗi Base64. `.gitignore` chặn các định dạng signing phổ biến nhưng không thay thế secret scanning/review.

Manual run của **Build Device** cho phép chọn `development` hoặc `ad-hoc`. Certificate và profile phải cùng loại/phù hợp với method. Workflow sinh plist bằng [`scripts/ci/generate-export-options.py`](scripts/ci/generate-export-options.py), dùng `plistlib` để escape đúng team ID, bundle ID và profile name; không dùng `sed` trên secret. Muốn hỗ trợ App Store/TestFlight cần bổ sung method/credentials và quy trình release riêng — MVP không giả vờ xuất bản App Store.

## Generate Xcode project

CI luôn chạy:

```bash
xcodegen generate --spec project.yml
```

Trên Mac tùy chọn, hãy dùng đúng XcodeGen `2.46.0`. Cách tái tạo giống CI:

```bash
export RUNNER_TEMP="$(mktemp -d)"
export GITHUB_PATH="${RUNNER_TEMP}/github-path"
bash scripts/ci/install-xcodegen.sh
export PATH="$(cat "${GITHUB_PATH}"):${PATH}"
xcodegen generate --spec project.yml
```

Script sẽ fail nếu checksum hoặc version không đúng. Windows developer không cần chạy lệnh này và cũng không thể compile target iOS bằng Xcode trên Windows.

## Import extension demo

Tạo ZIP mẫu từ repository root:

```powershell
Compress-Archive -Path .\Examples\HelloExtension\manifest.json, .\Examples\HelloExtension\content.js, .\Examples\HelloExtension\content.css -DestinationPath .\HelloExtension.zip -Force
```

`manifest.json` phải nằm ở root ZIP. Trong app, mở menu **Extensions**, chọn **Import Extension**, chọn `HelloExtension.zip`, kiểm tra permission rồi cài. Bật extension và mở một trang HTTP/HTTPS; badge nhỏ xuất hiện khoảng ba giây mà không nhận pointer event hoặc thay đổi flow layout.

Không import extension không tin cậy trên thiết bị chứa dữ liệu quan trọng. Compatibility layer giảm bề mặt quyền nhưng content script được cho phép vẫn đọc/thay đổi DOM của host phù hợp.

## Manifest và extension API hiện tại

MVP chỉ nhận Manifest V3 và parse các trường:

- `name`, `version`, `description`, `permissions`, `host_permissions`.
- `content_scripts`: `matches`, `exclude_matches`, `js`, `css`, `run_at`, `all_frames`; persistent scripts use the declared frame scope, while programmatic `executeScript` targets the main document.
- `action` metadata (`default_title`, `default_popup`, `default_icon`) và `icons`; browser menu hiển thị extension actions, popup dùng `WKWebView` non-persistent + bridge và deny toàn bộ remote network.
- Match pattern gồm `<all_urls>`, HTTP/HTTPS wildcard scheme/host/path và các pattern hợp lệ mà validator chấp nhận.

Compatibility bridge được giới hạn có chủ ý. Xem source/runtime và test để biết contract chính xác; API không nằm trong danh sách dưới đây phải trả lỗi unsupported thay vì âm thầm giả lập:

- `chrome.runtime.sendMessage` và listener `chrome.runtime.onMessage` trong phạm vi bridge MVP.
- `chrome.storage.local.get/set/remove/clear`, tách namespace theo extension.
- `chrome.tabs.query/create` với permission check.
- `chrome.scripting.executeScript` với permission/host gate.
- `chrome.action.getTitle/setTitle` cho title tạm thời. Bridge MVP trả Promise; kiểu callback của Chrome chưa được hỗ trợ.

## Security model tóm tắt

- Giới hạn kích thước archive, từng file, tổng dung lượng giải nén và số entry.
- Dừng duyệt ZIP ngay ở entry thứ 2.001; giới hạn rule/reference và tổng content-script source chuẩn bị để tránh resource amplification/OOM.
- Chuẩn hóa/reject absolute path, `..`, duplicate path, symlink và entry không hỗ trợ trước khi ghi file.
- Reject native executable/Mach-O, dynamic library và resource path không an toàn; extension chỉ cung cấp JS/CSS/HTML/data cho runtime WebKit.
- Manifest/permission/match pattern được validate trước install; index match được compile/cache, không parse lại manifest mỗi navigation.
- ID package deterministic từ digest; dữ liệu và storage đặt trong namespace riêng từng extension.
- Permission và host access được kiểm tra tại runtime trước API/injection nhạy cảm.
- Declared permission không đồng nghĩa granted permission: broad hosts, `<all_urls>`, `tabs` và `scripting` bắt đầu denied; details UI hỗ trợ Ask/current/selected/all-requested sites và revoke ngay.
- Favicon native fetch resolve DNS, chặn địa chỉ local/private/reserved, validate mọi redirect và stream với byte/image limits.
- IPC chỉ nhận JSON string phẳng và preflight byte/depth/token trước decode; tabs, script source/result/parallelism (kể cả budget tổng runtime 16 MiB), storage, persisted state và downloads đều có quota/rate/size limits.
- File và directory chịu ảnh hưởng từ dữ liệu ngoài được đọc/duyệt streaming với hard cap; repository fail closed khi scan bị truncate và mặc định giới hạn 128 extension đã cài.
- Permission reload khóa bridge ngay, serialize theo generation và cancel operation đang chạy; `document_idle` dùng scheduler theo tab có replace/cancel khi navigation đổi.
- Storage JSON hỏng/quá lớn được quarantine rồi phục hồi namespace rỗng; lỗi I/O thật vẫn trả lỗi thay vì bị che.
- Content scripts dùng `WKContentWorld` riêng theo extension khi API cho phép. Đây không phải sandbox hoàn hảo: script được phép vẫn tương tác DOM trang.
- Private browsing mặc định không chạy extension trong MVP.

Chi tiết threat model và giới hạn nằm trong [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Testing

Unit tests hiện bao phủ manifest/parser limits, favicon destination/image policy, permission + selected-site/revoke/reload races, bridge pre-decode/tab/script/storage quotas, repository integrity/corruption/count bounds, idle scheduling, navigation/dialog policy, download byte/disk/reconciliation, bounded persistence/directory scans, data protection và private-mode boundaries. Workflow Simulator là nguồn xác nhận compile/test chính thức.

Do máy Windows không có Xcode/WebKit SDK iOS, không dùng kết quả parse Swift hay artifact giả để thay thế `xcodebuild test`. Nếu workflow đầu tiên phát hiện sai khác SDK/Xcode, sửa source/config rồi push lại và giữ log/`.xcresult` làm bằng chứng.

## Giới hạn hiện tại

- iOS yêu cầu browser dùng WebKit; dự án không nhúng Chromium và không thể đạt parity Chrome/Kiwi đầy đủ.
- Không có background service worker, declarativeNetRequest, webRequest, native messaging, binary module, Chrome Web Store auto-install hoặc sync.
- Không hỗ trợ Manifest V2; extension update/rollback, service worker và long-lived ports chưa có.
- Permission UI có grant/revoke theo domain; runtime prompt ngoài one-time `activeTab` gesture chưa mô phỏng toàn bộ browser Chrome/Safari.
- Tab suspension khôi phục URL/snapshot, không serialize toàn bộ JavaScript heap, form state hay back-forward list của trang.
- History chỉ ghi navigation HTTP(S) của tab thường. Downloads ghi vào hidden partial rồi mới atomic-rename khi hoàn tất, enforce byte/disk/concurrency policy và reconcile partial/orphan files; private metadata không persist nhưng file user chọn tải vẫn tồn tại với warning. Favicon được discover, fetch bằng public-destination policy, validate/decode và cache có quota (private mode không ghi disk cache).
- Simulator build không chạy trực tiếp trên Windows; signed device build không thể tồn tại nếu thiếu Apple signing assets hợp lệ.
- Chưa có bằng chứng build từ macOS cho đến khi workflow GitHub Actions đầu tiên chạy thành công.

## Roadmap đề xuất

1. Chạy CI/macOS cho commit hardening, sửa mọi lỗi SDK hoặc Swift concurrency và lưu `.xcresult`.
2. Chạy test thiết bị cho DNS/redirect, popup network capture, downloads, file protection, VoiceOver và memory pressure.
3. Bổ sung runtime permission prompt ngoài activeTab, audit log quyền và E2E revoke/content-world isolation.
4. Cải thiện restore tab/back-forward state, snapshot cache eviction và đo memory/tab-switch latency trên thiết bị thật.
5. Thêm extension update/migration, signature/trust policy cho package và fuzz tests ZIP/manifest/matcher.
6. Tạo release workflow riêng cho TestFlight/App Store khi có App Store Connect credentials và policy sản phẩm rõ ràng.
