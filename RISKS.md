# Risk register — KiwiX / ExtensionBrowser v3

Trạng thái: **ĐÃ CHẤP NHẬN LÀM BASELINE — cập nhật theo milestone**
Cập nhật: 2026-08-17

Thang điểm: xác suất (P) và tác động (I) từ 1–5; mức ưu tiên = P × I.

| ID | Rủi ro | P | I | Ưu tiên | Biện pháp bắt buộc | Bằng chứng đóng rủi ro |
|---|---|---:|---:|---:|---|---|
| R-01 | Extension độc hại đọc/sửa dữ liệu trên site được cấp quyền | 4 | 5 | 20 | Permission preview trước install; cảnh báo nổi bật cho `<all_urls>`; grant/revoke theo host; mặc định tắt private; không log URL | UI/integration test grant-revoke và review threat model |
| R-02 | CRX3 tải ngoài không được xác minh chữ ký/origin nhưng người dùng hiểu nhầm là đáng tin | 4 | 5 | 20 | Không gắn nhãn “verified”; hiển thị source + SHA-256; xác nhận hai bước; lưu provenance; quarantine package lỗi | Test tampered package và ảnh chụp warning flow |
| R-03 | Tải trực tiếp từ Chrome Web Store/AMO vi phạm hoặc bị chặn bởi ToS/endpoint thay đổi | 4 | 4 | 16 | Legal/ToS review trước ship; chỉ user-initiated; feature flag/kill switch; không scrape bằng credential; file import luôn là fallback | Biên bản review và integration test fallback |
| R-04 | App Store Review Guideline 2.5.2 cấm download/install/execute code làm thay đổi chức năng | 5 | 5 | 25 | App Store là non-goal v1; sideload-only; không xem public WebKit API là miễn trừ policy; review lại trước bất kỳ submission/notarization nào | Quyết định phân phối và policy review cập nhật |
| R-05 | Apple Account miễn phí làm app hết hạn sau 7 ngày | 5 | 4 | 20 | Khuyến nghị Developer Program; nếu dùng AltStore/SideStore phải hiển thị ngày hết hạn và runbook refresh | Sideload/refresh drill trên thiết bị |
| R-06 | `WKWebExtension` mới, hành vi/API surface đổi giữa bản iOS | 4 | 4 | 16 | Ma trận OS; pin Xcode trong CI sau baseline; harness chạy trên mỗi OS hỗ trợ; compatibility report theo build OS | Artifact harness theo từng runtime |
| R-07 | Extension mục tiêu phụ thuộc API WebKit không hỗ trợ hoặc semantics khác Chrome/Firefox | 5 | 4 | 20 | Không shim âm thầm; probe hành vi; ghi `COMPATIBILITY.md`; ưu tiên DNR; unsupported có lý do rõ | E2E cho 4 extension mục tiêu trên thiết bị |
| R-08 | Tab adapter sai identity/event ordering khi suspend/resume gây lỗi `tabs.*` | 4 | 5 | 20 | Registry adapter ổn định theo UUID; suspend không phát close/open; test event trace; mọi controller callback trên MainActor | Unit + integration event-order tests |
| R-09 | Extension page cần configuration riêng; dùng nhầm web view làm navigation fail | 3 | 5 | 15 | Dùng `WKWebExtensionContext.webViewConfiguration` cho extension-origin page; swap web view khi đi vào/ra origin extension; test popup/options | Popup/options navigation tests |
| R-10 | Private data rò sang normal profile hoặc extension chạy trong private ngoài ý muốn | 3 | 5 | 15 | Data store/controller non-persistent riêng; deny-by-default; không persist private tab/history; test process restart | Privacy integration suite |
| R-11 | ZIP/XPI/CRX gây path traversal, zip bomb hoặc resource exhaustion | 4 | 5 | 20 | Giữ lại validator/extraction limits hiện có sau review; giải nén off-main; reject symlink/duplicate/absolute/`..`; quota file/count/size | Unit/fuzz corpus và peak-memory test |
| R-12 | Gỡ runtime cũ làm hỏng app shell đang dùng chung integration boundary | 4 | 4 | 16 | Migration theo vertical slice; inventory dependency; không bulk-delete trước build xanh; giữ test tab/history độc lập | CI xanh sau từng slice |
| R-13 | Không có môi trường Apple nên tài liệu bị nhầm thành bằng chứng runtime | 5 | 5 | 25 | Mọi kết quả chưa chạy ghi `CHƯA CHẠY`; không ký DoD trên Windows; yêu cầu `.xcresult`/JSON artifact và device metadata | CI/device artifact hợp lệ |
| R-14 | Unsigned IPA artifact bị hiểu nhầm là cài trực tiếp được | 4 | 3 | 12 | Tên artifact và docs ghi rõ unsigned; signed output chỉ tạo khi profile/cert validate; test IPA structure và signature | CI summary + `codesign --verify` |
| R-15 | URL/source extension lọt vào analytics/log hoặc crash report | 3 | 5 | 15 | Structured log chỉ dùng extension ID/hash và error category; redact URL; analytics opt-in; audit log statements | Static scan + privacy test |
| R-16 | DNR/EasyList compile/apply làm block main thread, tăng RAM | 4 | 4 | 16 | Native content blocker độc lập; compile off-main; cache theo hash; signpost; regression >15% fail | Benchmark artifact trên iPhone 12+ |
| R-17 | Direct update thay package đang chạy gây corruption hoặc rollback khó | 3 | 5 | 15 | Download staging; validate/load thử; atomic directory swap; giữ một bản rollback; serialize update/uninstall | Fault-injection tests |

## Policy notes

- [App Review Guideline 2.5.2](https://developer.apple.com/app-store/review/guidelines/) hiện nói app không được
  tải/cài/chạy code làm thay đổi feature/functionality, trừ ngoại lệ hẹp. V1 không nhắm App Store.
- [Chrome Web Store Terms](https://developer.chrome.com/docs/webstore/program-policies/terms) và
  [Mozilla Add-ons policies](https://extensionworkshop.com/documentation/publish/add-on-policies/) phải được
  legal/product owner kiểm tra ở thời điểm triển khai one-click; kỹ thuật không tự tuyên bố compliance.
- AltStore Classic ghi rõ app sideload hết hạn sau 7 ngày; đây là giới hạn vận hành, không chỉ là UX nhỏ.

## Stop-ship conditions

Không phát hành IPA test cho người dùng ngoài nhóm phát triển nếu có một trong các điều kiện:

- package không rõ provenance được cài mà không có cảnh báo/xác nhận hai bước;
- permission `<all_urls>` bị grant mặc định hoặc không revoke được;
- private tab dùng chung persistent controller/data store với normal tab;
- report API được đánh dấu pass nhưng không có artifact runtime;
- signing/profile không khớp bundle ID hoặc IPA chỉ là unsigned package;
- private API scan thất bại;
- crash/data corruption khi update hoặc uninstall extension.
