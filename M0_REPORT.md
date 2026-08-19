# M0 report — Skeleton, IPA và CI

Trạng thái: **CI PASS; nghiệm thu trên iPhone thật đang chờ signing assets**
Ngày: 2026-08-17

## Phạm vi đã hoàn thành

- XcodeGen là source of truth; deployment target app/test đã chuyển sang iOS 18.4.
- Bundle ID mặc định là `com.phucthinhvn122.KiwiX` và có thể override bằng biến môi trường
  `BUNDLE_IDENTIFIER`.
- Có `Makefile` cho `build`, `test`, `ipa`, `bench` và `private-api`.
- `scripts/build_ipa.sh` hỗ trợ `unsigned`, `development` và `ad-hoc`.
- `scripts/check_private_api.sh` scan source và Mach-O binary.
- CI chọn Xcode stable mới nhất có trên runner, ghép runtime simulator không vượt SDK, boot simulator,
  chạy test có timeout, Release build, benchmark, private-API guard và đóng gói artifact.
- GitHub repository private: <https://github.com/phucthinhvn122/KiwiX>.

## Bằng chứng CI

- Commit được kiểm chứng: `d4b684f55a924779f6182f0088ec7c3f9b107ec3`.
- Workflow run: <https://github.com/phucthinhvn122/KiwiX/actions/runs/31997160982>, attempt 2.
- Kết quả: pass trong 7 phút 5 giây.
- Toolchain: Xcode 26.3, Swift 6.2.4; simulator iOS 26.2.
- **Đã đổi từ M2:** `ci.yml` hiện ghim cứng `Xcode_16.4` và runner chỉ có simulator iOS 18.5.
  Dòng trên là toolchain của đúng run `31997160982`, không phải của CI hiện tại. Ghim là cố ý —
  chọn "Xcode mới nhất trên runner" khiến kết quả đổi theo image của GitHub, không tái tạo được.
- Các bước pass:
  - generate Xcode project;
  - unit tests;
  - Release Simulator build;
  - source và binary private-API guard;
  - M0 benchmark;
  - unsigned device archive/IPA;
  - Simulator ZIP;
  - artifact upload.
- Artifact: `KiwiX-d4b684f55a924779f6182f0088ec7c3f9b107ec3`, ID `9277408962`, retention 14 ngày.

Artifact đã được tải về máy làm việc và kiểm tra ZIP:

| File | Kích thước | `Info.plist` | App binary |
|---|---:|---:|---:|
| `ExtensionBrowser-Unsigned.ipa` | 610,905 byte | Có | Có |
| `ExtensionBrowser-Simulator.zip` | 2,168,174 byte | Có | Có |

## Cách chạy

Trên macOS có Xcode và XcodeGen:

```bash
make private-api
make test DESTINATION='platform=iOS Simulator,id=<UDID>'
make build CONFIGURATION=Release DESTINATION='generic/platform=iOS Simulator'
make bench DESTINATION='platform=iOS Simulator,id=<UDID>'
make ipa
```

Kết quả kỳ vọng của `make ipa` mặc định:

```text
artifacts/ipa/ExtensionBrowser-Unsigned.ipa
```

Signed development/ad-hoc build sau khi certificate/profile đã được cài vào keychain:

```bash
SIGNING_MODE=development \
APPLE_TEAM_ID='<TEAM_ID>' \
PROFILE_NAME='<PROFILE_NAME>' \
SIGNING_IDENTITY='<CERT_SHA1_OR_NAME>' \
BUNDLE_IDENTIFIER='com.phucthinhvn122.KiwiX' \
make ipa
```

## Definition of Done M0

- [x] XcodeGen generate thành công trên macOS CI.
- [x] Build/test xanh.
- [x] Private API guard chạy trên source và Mach-O binary.
- [x] Simulator app ZIP và unsigned IPA được tạo lặp lại qua CI.
- [x] Benchmark có `.xcresult` artifact.
- [ ] Tạo signed IPA bằng Apple Developer certificate/provisioning profile.
- [ ] Sideload và mở app trên iPhone XS, iOS 18.7.9.

Hai ô cuối chưa thể tự hoàn thành từ repository: GitHub hiện không có signing secret, iPhone không kết
nối với máy Windows, và certificate/provisioning profile hợp lệ phải do tài khoản Apple Developer cấp.
Không được gọi M0 là hoàn tất DoD cho tới khi hai kiểm tra này pass.

## Signing secrets còn thiếu

Workflow `Build Device` đã sẵn sàng nhận đúng sáu GitHub Actions secrets sau:

- `BUILD_CERTIFICATE_BASE64`
- `P12_PASSWORD`
- `PROVISIONING_PROFILE_BASE64`
- `KEYCHAIN_PASSWORD`
- `APPLE_TEAM_ID`
- `BUNDLE_IDENTIFIER`

Không commit các giá trị này vào repository. Khi đủ secret, chạy thủ công workflow `Build Device`, tải
`ExtensionBrowser-Signed-IPA`, cài lên iPhone XS và ghi phiên bản/build thiết bị cùng kết quả launch vào
tài liệu này.
