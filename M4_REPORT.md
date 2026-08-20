# M4 report — Cài extension từ file, có kiểm chứng nguồn gốc

M3 trả lời câu hỏi *runtime có thi hành không*. M4 trả lời câu hỏi đứng trước nó:

> Làm sao một file `.crx` / `.zip` do người dùng chọn trở thành một extension đang chạy — **mà không
> lúc nào người dùng bị cài hộ thứ họ chưa nhìn thấy?**

Spec §7 đặt ra bốn ràng buộc, và cả bốn đều là ràng buộc về *thứ tự*, không phải về tính năng:
quyền phải hiện **trước** khi cài; `<all_urls>` phải in đậm; chữ ký không verify được thì **banner +
xác nhận 2 bước, không im lặng cài**; và không log URL người dùng.

M4 chia làm hai lượt: **M4a** là phần không có UI (đọc gói, verify chữ ký, catalog), **M4b** là phần
người dùng chạm vào.

---

## M4a — Đọc gói và ghi sổ

CI run `32334802328`: **124 test, 0 failure**, Release build + binary private-API check + IPA đều xanh.

| Thành phần | File | Vai trò |
|---|---|---|
| Đọc CRX3 | `ExtensionHost/Install/CRX3Package.swift` | Parse `Cr24` header, verify RSA PKCS#1 v1.5 SHA-256, dẫn xuất publisher id |
| Phân loại gói | `ExtensionHost/Install/ExtensionPackageReader.swift` | `.crx3` hay `.zip`; trả về `ExtensionPackageSignature` |
| Giải nén + commit | `ExtensionHost/Install/ExtensionPackageInstaller.swift` | `stage` → thư mục tạm; `commit` → `Application Support/ExtensionBrowser/Extensions/<id>/` |
| Sổ cái | `ExtensionHost/Install/InstalledExtensionStore.swift` | Actor, JSON có schema version, quarantine file hỏng |
| Chính sách quyền | `ExtensionHost/WebExtensionHostTypes.swift` | Thêm case thứ ba `.userGranted(permissions:matchPatterns:)` |

### Quyết định mang nhiều sức nặng nhất: kiểu dữ liệu không có case "chữ ký sai"

```swift
public enum ExtensionPackageSignature {
    case verified(publisherIdentifier: String)
    case unsigned(UnsignedReason)   // .plainArchive | .noSupportedProof
}
```

Không có `.failed`. Chữ ký **sai** là lỗi cứng ném ra từ `CRX3Reader`, gói không bao giờ tới được UI.
Chỉ chữ ký **vắng mặt** — file zip trần, hoặc CRX3 chỉ mang proof ECDSA mà `SecKey` không nhận — mới
đi vào đường "banner + xác nhận 2 bước" của §7. Nếu gộp hai thứ đó vào một case, sớm muộn sẽ có chỗ
nào đó xử lý "signature không ok" bằng một cái cảnh báo mềm.

Ba chi tiết của định dạng được làm theo Chromium chứ không theo suy đoán:

- Payload ký là `"CRX3 SignedData\x00" || uint32_le(len(header)) || header || archive`, không phải chỉ
  archive.
- Header bị từ chối nếu chứa `PK\x05\x06`, `PK\x06\x07`, `PK\x06\x06` — chống đánh lừa bộ tìm EOCD.
- Extension id = `SHA256(DER SPKI)[0..16]`, mỗi nibble map sang bảng `abcdefghijklmnop`.

`SecKeyCreateWithData` chỉ nhận `RSAPublicKey` PKCS#1, nên vỏ SPKI được bóc và OID `rsaEncryption`
được kiểm trước. `SecKeyIsAlgorithmSupported` **không** dùng — nó trả lời câu hỏi khác với câu hỏi
"chữ ký này có đúng không".

### Một lỗi thật đã sửa trên đường đi

`apply(policy:)` trước đây đọc `requestedPermissionMatchPatterns`, thứ **không** bao gồm `matches` của
content script. Một extension lấy quyền host hoàn toàn qua content script sẽ được cấp đúng con số
không, và im lặng không chạy. Nay dùng `allRequestedMatchPatterns`.

---

## M4b — Người dùng nhìn thấy gì

| Thành phần | File | Vai trò |
|---|---|---|
| Tóm tắt quyền | `ExtensionHost/Install/ExtensionPermissionSummary.swift` | Đọc lại từ `WKWebExtension`, không tự parse manifest |
| Điều phối | `ExtensionHost/Install/ExtensionInstallCoordinator.swift` | `prepare` → `install`/`cancel`; `restore()` lúc khởi động |
| Màn hình đồng ý | `ExtensionHost/Install/ExtensionPermissionSheetViewController.swift` | §7: banner, `<all_urls>` in đậm, xác nhận 2 bước |
| Danh sách | `ExtensionHost/Install/ExtensionsViewController.swift` | Bật/tắt, gỡ, nhập file |

### Vì sao bảng quyền không đọc `manifest.json`

ADR-001 giao việc hiểu manifest cho WebKit. Nên sheet được điền bằng cách dựng
`WKWebExtension(resourceBaseURL:)` trên thư mục staging rồi **hỏi lại runtime**:

```swift
permissions:  webExtension.requestedPermissions.map(\.rawValue).sorted()
matchPatterns: webExtension.allRequestedMatchPatterns.map(\.string).sorted()
```

Đây không phải chuyện gọn gàng. Chuỗi hiện trên màn hình là **đúng chuỗi** được ghi vào catalog và
sau đó đem so với `WKWebExtension.Permission` lúc cấp quyền. Nếu sheet đánh vần khác runtime, nó đang
mô tả một sự cho phép không bao giờ xảy ra.

Tên extension đi qua `SafeInput.displayText` — WebKit không sanitize nó. Nếu tên **cần** sanitize
(bidi override, zero-width joiner), sheet nói thẳng điều đó, vì giả danh tên là cách một "uBlock"
giả được cài.

### Cấp quyền là đóng băng, không phải kế thừa

`install` ghi đúng tập quyền sheet vừa hiện. Một bản cập nhật sau này xin thêm quyền **không** thừa
hưởng gì: quyền mới đơn giản là không có trong record, và `apply(policy:)` từ chối mọi thứ record
không gọi tên. Quyền `optional_permissions` hiện bị **từ chối cứng** — sheet nói đúng như vậy thay vì
hứa một hộp thoại chưa tồn tại.

### Bốn chỗ dễ sai đã xử lý

1. **Vuốt tắt sheet không phải là câu trả lời.** `isModalInPresentation = true` trên navigation
   controller; thư mục staging luôn có chủ cho tới khi một trong hai nút được bấm.
2. **Cài sau khi sheet đóng xong**, không song song với animation — `showError` từ chối chồng lên một
   presentation khác, nên lỗi phát trong lúc animate sẽ biến mất.
3. **Identifier lấy từ file trên đĩa không được đem đi xoá thư mục.** Mọi path component đều qua
   `ExtensionIdentifier(rawValue:)` trước khi chạm filesystem.
4. **Không nội suy lỗi vào log.** Lỗi runtime có thể mang theo đường dẫn; §7 cấm ghi chuỗi bắt nguồn
   từ người dùng.

### File mở từ app khác

`.crx` khai báo UTI riêng `com.extensionbrowser.crx-extension` conform `public.data` — **không** phải
`public.zip-archive`, vì CRX3 mở đầu bằng `Cr24` chứ không phải `PK`. Khai sai là một lời nói dối hệ
điều hành sẽ hành động theo.

App không khai `LSSupportsOpeningDocumentsInPlace`, nên mọi file đến đều là bản sao trong inbox —
`SceneDelegate` còn kiểm `!options.openInPlace` lần nữa trước khi chuyển tiếp, vì đường nhập file
**xoá thứ nó đọc**, và thứ đó không bao giờ được phép là file gốc của người dùng.

---

## Cách chạy

```bash
make project
make test
```

Trong app: menu ⋯ → **Extensions** → **+** → chọn `.crx` hoặc `.zip`.

## Cách kiểm chứng

### 1. Bộ test

```bash
make test
```

Kỳ vọng: `Executed <n> tests, with 0 failures`. Các suite của M4:

| Suite | Đo cái gì |
|---|---|
| `CRX3PackageTests` | 11 test: magic sai, version 2, header 0/quá dài, token ZIP trong header, chữ ký sai, payload sửa, id lệch |
| `DERPublicKeyTests` | 7 test: bóc SPKI, OID sai, khoá yếu |
| `ExtensionPackageInstallerTests` | 8 test: staging, unwrap thư mục bọc, id ổn định, từ chối không manifest, commit/limit |
| `InstalledExtensionStoreTests` | 11 test: round-trip, byte ổn định, schema tương lai, JSON hỏng, id rác, tên rỗng |
| `WebExtensionHostRegistryTests` | 3 test: tra context theo id, unload một cái không ảnh hưởng cái kia, policy fallback = `denyAll` |
| `ExtensionInstallCoordinatorTests` | 10 test: prepare/cancel/install/enable/disable/remove/restore đầu-cuối |

### 2. Fixture là bằng chứng, nên phải sinh lại được y hệt

```bash
node scripts/make_crx3_fixtures.js
git diff --stat Tests/Fixtures/Packages
```

Kỳ vọng: **không có diff**. Script sinh khoá xác định, nên publisher id luôn là
`kliiopiebkklfgdplbapnchppieailka`.

| Fixture | sha256 (16 ký tự đầu) |
|---|---|
| `valid.crx` | `83bc048c21effd69` |
| `wrong-signature.crx` | `d019fe18a9a1f6be` |
| `tampered-payload.crx` | `383503bb8e40ee99` |
| `mismatched-id.crx` | `50b567ef2893f395` |
| `truncated-header.crx` | `3c912cd5d641ebbb` |
| `zero-header.crx` | `19523462e8ddfc82` |
| `crx2.crx` | `136e1b91c83cd8ae` |
| `unsigned.zip` | `7794f8aa0ae84c4a` |
| `nested.zip` | `57dba293870624ee` |
| `no-manifest.zip` | `b477dfc80d1c2f69` |

### 3. Hai cổng chạy được ngay trên máy, không tốn CI

```bash
bash scripts/check_private_api.sh --source ExtensionBrowser
bash scripts/check_ad_sdks.sh
```

Kỳ vọng: `Private API guard passed`, `Advertising SDK guard passed`.

### 4. Kiểm bằng mắt (bắt buộc, không test nào thay được)

| Việc | Kỳ vọng |
|---|---|
| Nhập `unsigned.zip` | Banner đỏ "no signature KiwiX can check", bấm **Add** → alert thứ hai, nút phá huỷ **Add Anyway**, nút mặc định là Cancel |
| Nhập một extension xin `<all_urls>` | Dòng đỏ **in đậm** ở trên cùng phần cảnh báo |
| Vuốt xuống để đóng sheet | Không đóng được |
| Tắt công tắc một extension | Biến mất khỏi `loadedContexts`, file vẫn còn |
| Khởi động lại app | Extension đang bật tự nạp lại; extension đã tắt thì không |

---

## Còn thiếu gì

- **Chưa chạy trên thiết bị thật.** Toàn bộ số liệu trên là simulator 18.5 (R-19).
- **`optional_permissions` bị từ chối cứng.** Sheet nói thật, nhưng đây vẫn là thiếu tính năng.
- **Cài lại đúng file cũ trả về lỗi `packageAlreadyInstalled`** thay vì cập nhật tại chỗ. Identifier
  là content digest nên "cùng bytes" đúng là "đã cài rồi" — nhưng thông báo nên là một câu, không
  phải một lỗi.
- **R-18 chưa đóng:** installer chưa phát hiện `background.service_worker` chết. Người dùng thấy
  "đã cài" cho một extension không bao giờ chạy vẫn là kết cục tệ hơn thấy một lời từ chối.
- **R-21 chưa đổi:** uBlock Origin Lite vẫn không chạy được vì `declarativeNetRequest` không thi
  hành. Cài được ≠ dùng được. Đây là câu hỏi đang chờ chủ dự án quyết (DECISIONS §7).
