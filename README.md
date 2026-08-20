# KiwiX — ExtensionBrowser v3

> Trạng thái: runtime là **`WKWebExtension` của Apple**, min iOS 18.4 (Path A, ADR-001). Compatibility
> layer `chrome.*` tự viết đã bị gỡ hẳn ở cuối M2 — app không parse manifest và không giả lập API nào.
> Mọi con số về compatibility trong repo này là **đo được** trên runtime thật, không phải suy đoán:
> xem [COMPATIBILITY.md](COMPATIBILITY.md). Cảnh báo lớn nhất: `declarativeNetRequest` **không chặn
> gì** (R-21), nên uBlock Origin Lite chưa dùng được.

Các quyết định đã chốt nằm trong [DECISIONS.md](DECISIONS.md), rủi ro và stop-ship conditions nằm
trong [RISKS.md](RISKS.md). Bằng chứng theo từng milestone nằm trong
[M0_REPORT.md](M0_REPORT.md) → [M2_REPORT.md](M2_REPORT.md) → [M3_REPORT.md](M3_REPORT.md) →
[M4_REPORT.md](M4_REPORT.md).

ExtensionBrowser là proof-of-concept browser native cho iPhone, viết bằng Swift, UIKit và WebKit. Hai
nửa: một browser nhiều tab có quản lý bộ nhớ, và một host cho WebExtension chạy trên `WKWebExtension`
— nhập gói `.crx`/`.zip` từ Files, verify chữ ký CRX3 khi có, hiện toàn bộ quyền trước khi cài, rồi
giao thư mục đã giải nén cho WebKit.

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
|   |-- ExtensionHost/
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
- `ExtensionHost`: Path A (ADR-001). Giữ `WKWebExtensionController`, adapter tab/window, delegate trả lời runtime của Apple, harness channel đo API matrix. `Install/` là đường cài đầy đủ: đọc CRX3, verify chữ ký, giải nén an toàn, catalog, sheet đồng ý quyền và màn hình quản lý. Không parse manifest, không giả lập `chrome.*` — WebKit hiểu manifest, app chỉ hỏi lại nó.
- `Settings`: search engine built-in/custom và thông tin privacy. `History` có actor store + màn hình xem/xóa/mở lại; `Downloads` nhận file trực tiếp từ WebKit, hiển thị tiến độ và cho phép mở/xóa file.
- `Shared`: logging, signpost, diagnostics.

Normal tabs dùng persistent website data store và chia sẻ process pool. Private tabs dùng non-persistent store/process pool riêng, không ghi history/session, và `webExtensionController` để `nil` — `WKWebViewConfiguration` được copy lúc tạo web view nên đây là điểm duy nhất ép được §7.

Browser MVP hiện có start page KiwiX, bottom toolbar hai hàng Back/Forward, address-or-search, Reload/Stop, tab count và menu; progress KVO, page title/URL tracking, Share, Open in External App, History, Downloads, lỗi navigation + Retry, JavaScript alert/confirm/prompt và mở `target=_blank` thành tab mới. Tab switcher hiển thị snapshot/lifecycle, normal session được persist; memory warning snapshot rồi release toàn bộ background web view. Debug build có metrics URL/tab/live web-view/navigation/memory cùng trạng thái attach của extension host. Menu ⋯ có mục **Extensions** khi scene dựng được extension host: danh sách đã cài, công tắc bật/tắt, vuốt để gỡ, và nút **+** để nhập gói từ Files.

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

## Cài extension

Nguồn duy nhất là một file trên máy — không có store, không có ô nhập URL, không có auto-update. Nhận
`.crx` (CRX3) và `.zip`; `manifest.json` phải ở root, hoặc trong đúng một thư mục bọc.

Tạo ZIP mẫu từ repository root:

```powershell
Compress-Archive -Path .\Examples\HelloExtension\* -DestinationPath .\HelloExtension.zip -Force
```

Trong app: menu ⋯ → **Extensions** → **+** → chọn file. Cũng có thể mở gói từ Files hoặc share sheet;
đường đó đi qua đúng màn hình đồng ý, không được cấp thêm gì.

Trước khi cài, KiwiX hiện tên, phiên bản, toàn bộ permission, toàn bộ site access, và nguồn gốc gói:

| Tình huống | KiwiX làm gì |
|---|---|
| CRX3 chữ ký hợp lệ | Hiện `Signed by <publisher id>`. Id là fingerprint khoá công khai, **không** phải một cái tên đã được ai đó chứng thực |
| CRX3 chữ ký sai / payload bị sửa | Từ chối thẳng. Không có nút để đi tiếp |
| `.zip` hoặc CRX3 không có proof kiểm được | Banner đỏ, và nút **Add** mở thêm một alert xác nhận thứ hai (spec §7) |
| Xin `<all_urls>` | Dòng cảnh báo **in đậm, màu đỏ**, đặt trên cùng |
| Tên chứa ký tự ẩn (bidi, zero-width) | Cảnh báo riêng — đây là cách một bản "uBlock" giả được cài |

Quyền được đóng băng lúc bấm Add. `optional_permissions` bị **từ chối cứng**: extension có xin lúc
chạy cũng không được. Muốn thu hồi thì tắt công tắc (giữ file) hoặc Remove (xoá cả file lẫn quyền).

Đừng cài extension không tin cậy lên thiết bị có dữ liệu quan trọng. Content script được cho phép vẫn
đọc và thay đổi DOM của trang khớp — `WKContentWorld` cô lập biến toàn cục, không cô lập DOM.

## Manifest và extension API hiện tại

App **không** parse manifest (ADR-001). `WKWebExtension` đọc nó, và app hỏi lại runtime — nên câu hỏi
"hỗ trợ trường nào" là câu hỏi về WebKit, không về repository này. Câu trả lời được đo, không được
đoán: harness tự viết probe 90 API trong runtime thật ở mỗi lần chạy CI, và bảng đầy đủ nằm ở
[COMPATIBILITY.md](COMPATIBILITY.md).

Tóm tắt lần đo gần nhất (simulator iOS 18.5): 42 PASS, 0 FAIL, 18 available-nhưng-chưa-chứng-minh,
26 không có, 4 skip. Ba kết quả đáng nhớ hơn cả con số:

- **`background.service_worker` nạp không lỗi và không bao giờ chạy.** Phải dùng `background.scripts`
  + `persistent: false`. Đa số extension MV3 ngoài đời không thoả điều này.
- **`declarativeNetRequest` không chặn gì**, `webRequest` listener không nổ lần nào. Đo bằng server
  thật trên loopback, không suy đoán.
- `notifications`, `debugger`, `proxy`, `devtools_*` vắng mặt hoàn toàn.

## Security model tóm tắt

Phần liên quan tới extension:

- **Quyền là opt-in một lần, hiện đầy đủ trước khi cài.** Tập được cấp dựng *từ* chính yêu cầu của
  manifest, nên một pattern manifest không xin thì không có đường vào record. Context nào không có
  policy ghi lại thì mặc định `.denyAll`; ba runtime prompt trong delegate trả về rỗng.
- **Chữ ký sai ≠ không có chữ ký.** CRX3 verify RSA PKCS#1 v1.5 SHA-256 trên đúng payload Chromium
  quy định (`"CRX3 SignedData\0" || uint32_le(len(header)) || header || archive`); chữ ký sai là lỗi
  cứng. Header bị từ chối nếu chứa token EOCD giả (`PK\x05\x06`, `PK\x06\x07`, `PK\x06\x06`).
- **Giải nén có giới hạn cứng**: số entry, kích thước từng file, tổng dung lượng, tỉ lệ nén; chuẩn hoá
  và từ chối absolute path, `..`, path trùng, symlink, entry không hỗ trợ; từ chối Mach-O và dylib.
- **Identifier là digest của gói**, và mọi identifier đọc từ catalog phải qua
  `ExtensionIdentifier(rawValue:)` trước khi trở thành path component.
- **Private tab không chạy extension** (spec §7). `webExtensionController` để `nil` trên configuration
  của private web view — `WKWebViewConfiguration` được copy lúc tạo web view, nên đây là điểm duy nhất
  ép được điều đó.
- **Không log chuỗi bắt nguồn từ người dùng.** Lỗi nạp extension log một câu tĩnh, vì error của runtime
  có thể mang theo đường dẫn.

Phần còn lại của app:

- Favicon fetch resolve DNS rồi chặn địa chỉ local/private/reserved, validate mọi redirect, stream có
  giới hạn byte và kích thước ảnh.
- Downloads ghi vào hidden partial rồi atomic-rename, enforce byte/disk/concurrency policy và reconcile
  partial/orphan lúc khởi động.
- Persisted state đọc streaming có hard cap; JSON hỏng bị quarantine thay vì làm chết startup.
- Mở external scheme cần gesture foreground ở top-level, có allowlist/xác nhận và rate limit theo tab.

Cái này **không** có: sandbox hoàn hảo cho content script, per-site grant, revoke từng phần khi
extension đang chạy, và bất kỳ giới hạn nào do app đặt lên storage/IPC volume của extension — nửa đó
thuộc về WebKit và chưa được đo.

Chi tiết threat model và giới hạn nằm trong [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md).

## Testing

Unit tests hiện bao phủ: CRX3 (magic, version, header, token EOCD giả, chữ ký sai, payload bị sửa, id
lệch), bóc DER SPKI, staging/commit của installer, catalog round-trip và quarantine, registry + policy
fallback `denyAll`, luồng cài đầu-cuối (prepare/cancel/install/enable/disable/remove/restore), tab
adapter + rate limit, favicon destination/image policy, navigation/dialog policy, download
byte/disk/reconciliation, bounded persistence/directory scans, data protection, private-mode
boundaries, và enforcement thật của `declarativeNetRequest`/`webRequest` đo bằng server loopback.

Không có test nào thay được phần nhìn bằng mắt của sheet đồng ý quyền (§7) — danh sách kiểm ở
[M4_REPORT.md](M4_REPORT.md). Workflow Simulator là nguồn xác nhận compile/test chính thức.

Do máy Windows không có Xcode/WebKit SDK iOS, không dùng kết quả parse Swift hay artifact giả để thay thế `xcodebuild test`. Nếu workflow đầu tiên phát hiện sai khác SDK/Xcode, sửa source/config rồi push lại và giữ log/`.xcresult` làm bằng chứng.

## Giới hạn hiện tại

- iOS yêu cầu browser dùng WebKit; dự án không nhúng Chromium và không thể đạt parity Chrome/Kiwi đầy đủ.
- Không có background service worker (nạp không lỗi nhưng không chạy), binary module, Chrome Web Store auto-install hoặc sync.
- `declarativeNetRequest` và `webRequest` **có mặt nhưng không thi hành**: rule cài được, runtime báo enabled, và không request nào bị chặn hay bị quan sát. Đo bằng server nội bộ trên loopback, không phải suy đoán — `COMPATIBILITY.md` và `RISKS.md` R-21. Hệ quả: uBlock Origin Lite chưa chạy được.
- Không hỗ trợ Manifest V2; extension update/rollback, service worker và long-lived ports chưa có.
- Extension permission là all-or-nothing theo từng extension, đóng băng lúc cài. Không có per-site grant, không có revoke từng phần khi extension đang chạy; `optional_permissions` bị từ chối cứng (R-05).
- Popup và options page **chưa làm** — app tự trả `actionPopupUnsupported`. Cần `WKWebExtensionContext.webViewConfiguration`, thứ chưa chỗ nào trong repo dùng (R-08).
- Tab suspension khôi phục URL/snapshot, không serialize toàn bộ JavaScript heap, form state hay back-forward list của trang.
- History chỉ ghi navigation HTTP(S) của tab thường. Downloads ghi vào hidden partial rồi mới atomic-rename khi hoàn tất, enforce byte/disk/concurrency policy và reconcile partial/orphan files; private metadata không persist nhưng file user chọn tải vẫn tồn tại với warning. Favicon được discover, fetch bằng public-destination policy, validate/decode và cache có quota (private mode không ghi disk cache).
- Simulator build không chạy trực tiếp trên Windows; signed device build không thể tồn tại nếu thiếu Apple signing assets hợp lệ.
- Chưa có bằng chứng build từ macOS cho đến khi workflow GitHub Actions đầu tiên chạy thành công.

## Roadmap đề xuất

1. Chạy CI/macOS cho commit hardening, sửa mọi lỗi SDK hoặc Swift concurrency và lưu `.xcresult`.
2. Chạy test thiết bị cho DNS/redirect, popup network capture, downloads, file protection, VoiceOver và memory pressure.
3. Bổ sung runtime permission prompt ngoài activeTab, audit log quyền và E2E revoke/content-world isolation.
4. Cải thiện restore tab/back-forward state, snapshot cache eviction và đo memory/tab-switch latency trên thiết bị thật.
5. Chốt hướng content blocking (R-21), phát hiện `service_worker` chết lúc cài (R-18), dựng popup/options page (R-08), rồi mới tới extension update/migration và fuzz corpus cho ZIP/CRX3.
6. Tạo release workflow riêng cho TestFlight/App Store khi có App Store Connect credentials và policy sản phẩm rõ ràng.
