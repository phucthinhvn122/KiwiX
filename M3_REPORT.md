# M3 report — Đo thi hành mạng của extension bằng server nội bộ

M2 dừng ở "API có mặt". M3 chỉ có một câu hỏi, và nó là câu hỏi quyết định sản phẩm:

> Khi extension cài một rule `declarativeNetRequest` chặn một URL, **request đó có thật sự không đi ra không?**

Không phải "API có tồn tại không". Không phải "runtime có báo cài thành công không". Cả hai câu đó M2
đã trả lời là *có*, và cả hai đều **sai lệch**.

## Vì sao M2 không trả lời được

Trang harness của M2 do `loadSimulatedRequest` phục vụ, và subresource của nó trỏ tới
`blocked.kiwix.test` — một host không ai sở hữu. Host đó fail DNS. Nên "bị `declarativeNetRequest`
chặn" và "tên miền không phân giải được" tạo ra **đúng cùng một sự im lặng**. Không có cách nào phân
biệt, nên M2 ghi `skipped` chứ không đoán (DECISIONS §4.2.5).

## Phạm vi đã hoàn thành

| Thành phần | File | Vai trò |
|---|---|---|
| HTTP server thật trên loopback | `ExtensionBrowserTests/Support/LocalHTTPServer.swift` | `NWListener` giới hạn `requiredInterfaceType = .loopback`, ghi lại **mọi path được yêu cầu**. Đây là nguồn bằng chứng duy nhất |
| Extension đo | `Tests/Fixtures/WebExtensions/NetworkProbe/` | MV3: 2 static rule, 1 dynamic rule, listener `webRequest`, content script đánh dấu phạm vi, poll `getMatchedRules` |
| Bài đo | `ExtensionBrowserTests/ExtensionHost/WebExtensionNetworkEnforcementTests.swift` | 4 pha: `baseline` → `early` → `late` → `control` |
| Kênh tín hiệu | `ExtensionBrowser/ExtensionHost/WebExtensionHarnessChannel.swift` | Thêm `onHandshake` — tái dùng transport native messaging M2 đã chứng minh chạy được, không phát minh transport thứ hai |

### Ba lựa chọn thiết kế gánh toàn bộ lập luận

1. **Server ở `127.0.0.1`.** Loopback không cần DNS. Im lặng ở đây chỉ còn một cách giải thích.
2. **Pha `baseline` không nạp extension.** Chứng minh cả 6 subresource vốn dĩ tới nơi bình thường.
   Không có nó, sự vắng mặt không chứng minh gì.
3. **`allowed.js` đứng cuối mọi trang.** Nó tới nơi nghĩa là các script phía trên **đã được đưa vào
   network stack rồi**. Thứ tự là lập luận, không phải chi tiết.

## Cách chạy

```bash
make project
make test
```

Chỉ chạy riêng bài đo:

```bash
xcodebuild test \
  -project ExtensionBrowser.xcodeproj \
  -scheme ExtensionBrowser \
  -destination 'platform=iOS Simulator,name=iPhone 16,OS=18.4' \
  -only-testing:ExtensionBrowserTests/WebExtensionNetworkEnforcementTests
```

Server chỉ bind loopback nên không có cổng nào lộ ra LAN của runner. Không cần cấu hình mạng;
`NSAllowsLocalNetworking` đã có sẵn trong `project.yml`.

## Cách kiểm chứng

Bài đo in 4 dòng marker ra console **dù pass hay fail** — số đo phải sống sót trong log CI cả hai chiều.

```bash
gh run view <run-id> --log | grep -E "KIWIX_DNR_"
```

Kỳ vọng (đã đo, run `32236350621`):

```
KIWIX_DNR_PROBE_READY   phase: ready, enabledRulesets: network-probe-static,
                        dynamicRules: installed:1, webRequest: registered, webRequestType: object
KIWIX_DNR_CONTEXT       hasContentModificationRules=true hasAccessToAllHosts=true
KIWIX_DNR_ENFORCEMENT   earlyStatic=reached  earlyDynamic=reached  earlyBare=reached
                        lateStatic=reached   lateDynamic=reached   lateBare=reached
                        controlBare=blocked  controlDotted=blocked
                        lateInScope=yes      webRequestObserved=0
KIWIX_DNR_MATCHED       state: none-after-8-polls
```

Đọc bảng: `control*` là rule **của chính test** biên dịch qua `WKContentRuleListStore` → chặn được.
`late*` là rule **của extension** → không chặn. Cùng server, cùng URL, cùng configuration.

## Kết quả đo

| Rule do ai cấp | urlFilter không dấu chấm | urlFilter có dấu chấm |
|---|---|---|
| Tự biên dịch qua `WKContentRuleListStore` | `blocked` | `blocked` |
| `declarativeNetRequest` static của extension | `reached` | `reached` |
| `declarativeNetRequest` dynamic của extension | — | `reached` |

Và `getMatchedRules({})` trả về **rỗng** sau 8 lần poll trong ~5,6 giây. Đây là chi tiết quan trọng
nhất: không phải "khớp rồi nhưng không chặn", mà là **engine không hề đối sánh**. Rule được nhận,
được liệt kê qua `getEnabledRulesets()`, được `WKWebExtensionContext.hasContentModificationRules` xác
nhận, và không tham gia vào bất kỳ request nào.

`webRequest.onBeforeRequest` đăng ký cho `<all_urls>` thành công và **nổ 0 lần** trên 21 request.

## Những cách giải thích khác đã bị loại, theo thứ tự

Một kết quả âm chỉ đáng tin khi đã giết hết cách giải thích thay thế — và phần lớn chúng là **lỗi của
tôi**, không phải của WebKit. Mỗi dòng dưới đây là một lần chạy CI riêng, không phải suy luận.

| # | Nghi ngờ | Cách loại | Run |
|---:|---|---|---|
| 1 | DNS fail chứ không phải bị chặn | Server loopback + pha `baseline` | `32233216520` |
| 2 | Rule chưa kịp biên dịch (mới 392 ms) | Lặp navigation y hệt sau 8 giây | `32234424615` |
| 3 | WebKit không áp content blocking lên loopback | Positive control tự biên dịch `WKContentRuleList` → **chặn được** | `32234424615` |
| 4 | Dạng filter khác nhau (control không dấu chấm, DNR có) | Ma trận 2×2 {có chấm, không chấm} × {rule mình, rule extension} | `32235139341` |
| 5 | Extension không có thẩm quyền trên host dạng IP | Content script `<all_urls>` chạy được trên chính trang loopback | `32236350621` |

Quyền không phải nguyên nhân: `WebExtensionHost.apply(policy:to:for:)` cấp `grantedExplicitly` cho
toàn bộ `requestedPermissions` **và** `requestedPermissionMatchPatterns`, gồm `declarativeNetRequest`
và `<all_urls>`.

Nghi ngờ #3 là cái tôi coi trọng nhất: nếu WebKit đơn giản không lọc gì trên loopback thì toàn bộ bộ
máy đo **không đo gì cả** và mọi con số trên đây vô nghĩa. Positive control tồn tại để một kết luận
âm không thể được rút ra từ một thiết bị đo hỏng.

## Hệ quả với sản phẩm

**uBlock Origin Lite — thước đo v1 của spec §3 — không thể hoạt động trên nền này.** uBOL là MV3
thuần: toàn bộ khả năng chặn của nó nằm trong `declarativeNetRequest`. Trên runtime đã đo, nó sẽ cài
được, báo cáo đúng, hiện ruleset enabled, và **không chặn một request nào**. Đây không phải "chưa
tối ưu", đây là "chức năng chính không tồn tại".

Ba lựa chọn, và đây là **quyết định của bạn chứ không phải của tôi** — cả ba đều đổi phạm vi so với spec:

1. Bỏ uBOL khỏi thước đo v1, khai báo thẳng là content blocking qua extension chưa chạy trên iOS.
2. Tự dựng đường chặn app-side bằng `WKContentRuleList` (đã chứng minh chặn được ở chính bài đo này),
   rồi tự dịch ruleset của uBOL sang định dạng của WebKit. Đây là công việc lớn và spec chưa cho phép.
3. Chờ Apple. Test đã ở dạng characterization nên hôm nào hành vi đổi, CI đỏ ngay và ta biết liền.

Ghi ở `RISKS.md` R-21 (P=5, I=5).

## Định nghĩa hoàn thành M3

- [x] Server thật, do dự án kiểm soát, quan sát được request ở mức path
- [x] Có pha baseline chứng minh subresource vốn dĩ tới nơi
- [x] Có positive control chứng minh bộ máy đo thật sự đo được
- [x] Mọi confound đã liệt kê đều bị loại bằng một lần chạy riêng, không bằng lập luận
- [x] Kết quả in ra console CI dù pass hay fail
- [x] Kết quả vào `COMPATIBILITY.md`, `DECISIONS.md` §4.1, `RISKS.md` R-21, và hai probe của harness
- [x] Test giữ kết quả dưới dạng characterization — Apple sửa thì CI đỏ, không im lặng

## Cảnh báo về giá trị của kết quả

**Simulator iOS 18.5, không phải thiết bị, không phải đúng sàn 18.4 mà `project.yml` khai báo** (R-19).
Runner CI không có runtime 18.4. Trước khi coi đây là giới hạn vĩnh viễn của nền tảng, phải đo lại
trên thiết bị thật và trên 18.4. Tôi không tuyên bố đây là bug của WebKit trên mọi phiên bản — tôi
tuyên bố đúng cái đã đo, ở đúng nơi đã đo.
