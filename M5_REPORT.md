# M5 report — Ba lỗi giao diện thiết bị thật tìm ra, và lý do 134 test không thấy

Đây là milestone đầu tiên không bắt đầu từ spec. Nó bắt đầu từ một người cầm máy và nói: thanh tìm
kiếm gõ không hiện chữ, không có cách nào tắt bàn phím, giao diện bị phần cứng che.

Cả ba đều là lỗi thật, tái tạo được từ code, và cả ba đều **lọt qua 134 test đang xanh**. Lý do là một
câu duy nhất, đáng ghi lại hơn cả ba bản vá:

CI run `32344527822`: **140 test, 0 failure**.

> Trước hôm nay, **không một test nào dựng view hierarchy của trình duyệt**. Suite đo parser, store,
> policy, package, adapter — mọi thứ trừ cái người dùng nhìn thấy.

---

## Lỗi 1 — Gõ vào thanh địa chỉ không thấy chữ

> **ĐÍNH CHÍNH (2026-08-20, sau M6).** Bản vá dưới đây **không sửa được lỗi người dùng báo.** M6 dựng
> target UI test, chụp ảnh app đang chạy, và đếm pixel: với tám ký tự trong ô, dải chữ chỉ có đúng ba
> màu — nền, viền focus, và màu pha giữa hai cái đó. Lúc nghỉ thì cả placeholder cũng không vẽ. Tức là
> **không có glyph nào được vẽ, màu gì cũng không**, nên nguyên nhân không thể là `textColor`:
> placeholder do UIKit tự tô màu, `textColor` không đụng tới nó được. Phân tích bên dưới về `textColor`
> vẫn đúng như một thiếu sót thật sự trong code, nhưng nó **không phải** nguyên nhân của lỗi. Nguyên
> nhân thật vẫn chưa biết và đang được đo, không đoán — xem R-23 trong `RISKS.md`.


`addressField` **chưa bao giờ được gán `textColor`**. Không có dòng nào, ở bất kỳ đâu trong repo:

```
$ grep -rn "textColor" ExtensionBrowser/ --include=*.swift
BrowserStartPageView.swift:73:  subtitleLabel.textColor = .secondaryLabel
BrowserErrorView.swift:29:      messageLabel.textColor = .secondaryLabel
SettingsViewController.swift:196: detailLabel.textColor = .secondaryLabel
TabSwitcherViewController.swift:202: urlLabel.textColor = .secondaryLabel
...
```

Toàn label. Không có `addressField`.

Trong khi đó **nền** của nó thì có ba màu, cả ba đều là `UIColor { traits in ... }` đổi theo dark mode:

| Trạng thái | Nền | Dark mode |
|---|---|---|
| Bình thường | `KiwiTheme.fieldSurface` | RGB(0.235, 0.239, 0.251) |
| Đang gõ | `KiwiTheme.elevatedSurface` | RGB(0.18, 0.184, 0.196) |
| Private tab | `privateAccent` alpha 0.14 | tối |

Nền tự đổi theo giao diện, chữ thì không. Ở dark mode, chữ tối trên nền tối.

Hai chi tiết xác nhận đúng chẩn đoán này chứ không phải cái khác:

- **Con trỏ nháy vẫn thấy.** Caret lấy `window.tintColor`, mà `SceneDelegate` gán
  `KiwiTheme.accentDeep` (xanh). Nên triệu chứng là "con trỏ chạy mà không ra chữ" — đúng như anh mô
  tả — chứ không phải "ô trống trơ".
- **Placeholder vẫn thấy.** UIKit có gán mặc định *động* cho placeholder (`.placeholderText`), nhưng
  không gán cho `textColor`. Đúng cái ranh giới đó là chỗ lỗi nằm.

**Bản vá:** `addressField.textColor = .label`, và gán luôn `tintColor` cho tường minh.

## Lỗi 2 — Không có cách nào tắt bàn phím

Không phải "thiếu tính năng nhỏ", nó là ngõ cụt:

- `textFieldDidBeginEditing` **ẩn cả hàng nút** (`controlsStack.isHidden = true`) → không còn nút nào
  để bấm ra ngoài.
- Không có nút Cancel.
- Không có tap gesture ở đâu cả.
- Chỉ có `scrollView.keyboardDismissMode = .interactive` — tức **phải kéo** trang xuống mới tắt được.

Nếu đang ở tab mới (trang trống, không kéo được gì) thì lối ra duy nhất là gõ một địa chỉ và Enter.

**Bản vá:** một `UITapGestureRecognizer` trên vùng nội dung. Hai nửa đều quan trọng:

```swift
func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
    guard gestureRecognizer.name == Self.dismissKeyboardTapName else { return true }
    return addressField.isFirstResponder
}
```

- **Không gõ → recognizer không bao giờ begin.** Nghĩa là chạm link, chạm nút trên trang, mọi thứ y
  như cũ. Một recognizer không begin thì không nuốt touch nào.
- **Đang gõ → nó nuốt touch** (`cancelsTouchesInView` mặc định `true`). Cố ý: cú chạm để tắt bàn phím
  không được đồng thời bấm luôn cái nằm dưới nó. Safari cũng vậy.

## Lỗi 3 — Giao diện bị phần cứng che

Chỉ **cạnh trên** theo safe area:

```swift
webContentContainer.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
webContentContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),   // ← cạnh thô
webContentContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor), // ← cạnh thô
```

Và `project.yml` **không khai `UISupportedInterfaceOrientations`**, nên mặc định iPhone cho phép cả hai
chiều ngang. Xoay ngang máy có tai thỏ thì inset chuyển sang cạnh bên — nội dung trang chui thẳng
xuống dưới phần khuyết.

**Bản vá:** hai cạnh ngang cũng theo `safeAreaLayoutGuide`; `progressView` bám theo vùng nội dung thay
vì cạnh view; nền `view` đổi từ `.systemBackground` sang `KiwiTheme.canvas` để dải phần cứng chiếm chỗ
không còn là một mảng màu tương phản.

`toolbar` **cố ý giữ nguyên full width** — lớp blur nên chạy dưới phần khuyết và dưới home indicator.
Thứ phải tránh là các nút bên trong nó, và chúng đã bám `layoutMarginsGuide`, thứ tự inset khỏi safe
area rồi. Tab switcher cũng đã an toàn: collection view để `contentInsetAdjustmentBehavior` mặc định
nên tự trừ safe area.

**Chưa xác nhận:** bản vá này chắc chắn đúng cho **chiều ngang**. Nếu anh thấy lỗi khi cầm **dọc** thì
nguyên nhân là chỗ khác — cần một screenshot để chỉ đúng chỗ.

---

## Cách chạy

```bash
make generate
make test
```

(`make project` không tồn tại — đã sửa lại trong M2/M3/M4 report và COMPATIBILITY.md.)

## Cách kiểm chứng

### 1. Bộ test mới

`ExtensionBrowserTests/BrowserChromeAppearanceTests.swift` — 6 test. **Cả 6 đều fail trên code cũ.**

| Test | Đo cái gì |
|---|---|
| `testTheAddressBarStatesItsTextColourRatherThanInheritingOne` | `textColor != nil` |
| `testTypedTextIsReadableOnEveryBackgroundTheAddressBarCanWear` | Tỉ lệ tương phản WCAG 2.1 > 4.5:1 trên **3 nền × 2 giao diện = 6 tổ hợp** |
| `testTheContentAreaCarriesATapToDismissRecogniser` | Vùng nội dung có mang recognizer tên `browser.dismissKeyboardTap` |
| `testContentStaysInsideTheSafeAreaWhenTheInsetIsHorizontal` | Đặt `additionalSafeAreaInsets` trái/phải 44pt, khung nội dung phải nằm trong safe area |
| `testTheDismissTapBeginsOnlyWhileTheAddressBarIsBeingEdited` | Delegate trả `false` khi không gõ, `true` khi đang gõ, `false` lại sau khi resign |
| `testTheDelegateDoesNotGateRecognisersItDoesNotOwn` | Recognizer khác trên cùng view không bị chặn nhầm |

Test tương phản tính luminance tương đối thật, không so màu bằng `==`:

```swift
0.2126 * linear(r) + 0.7152 * linear(g) + 0.0722 * linear(b)
```

Nghĩa là nó bắt được cả những cặp màu "khác nhau nhưng vẫn không đọc được", không chỉ cặp trùng khít.

Kỳ vọng: `Executed 140 tests, with 0 failures` (134 + 6).

Đo thật trên CI run `32344527822`:

```
Test Suite 'BrowserChromeAppearanceTests' passed
Executed 140 tests, with 0 failures (0 unexpected)
```

Cả 6 test đều chạy thật, không cái nào rơi vào `XCTSkip` — `becomeFirstResponder` nhận trên runner
(`testTheDismissTapBeginsOnlyWhileTheAddressBarIsBeingEdited` passed, 0.253s), nên nhánh đang-gõ được
kiểm thật chứ không bị bỏ qua.

### 2. Hai cổng chạy được ngay trên máy

```bash
bash scripts/check_private_api.sh --source ExtensionBrowser
bash scripts/check_ad_sdks.sh
```

Kỳ vọng: `Private API guard passed`, `Advertising SDK guard passed`.

### 3. Kiểm bằng mắt trên máy anh

| Việc | Kỳ vọng |
|---|---|
| Bật dark mode, chạm thanh địa chỉ, gõ | ~~Chữ hiện rõ~~ — **sai, xem đính chính ở đầu mục Lỗi 1.** Ô vẫn không vẽ chữ (R-23). |
| Bật light mode, gõ | Vẫn rõ (light mode trước giờ vẫn đúng, đừng để bản vá làm hỏng) |
| Mở tab mới, chạm thanh địa chỉ, rồi chạm vùng trang trống | Bàn phím tắt, không điều hướng đi đâu |
| Đang gõ, chạm đúng một cái link | Bàn phím tắt, **link không mở** |
| Không gõ, chạm link | Link mở bình thường — bản vá không được đụng vào đường này |
| Xoay ngang | Nội dung trang không chui dưới tai thỏ |

---

## Còn thiếu gì

- **Extension không chạy — chưa chẩn đoán được.** Cài được không có nghĩa chạy được, và
  `COMPATIBILITY.md` đã liệt ba lý do có sẵn (`background.service_worker` là án tử, DNR không chặn,
  không có popup). Nhưng chưa biết trường hợp của anh là cái nào — cần tên extension.
- **Vẫn chưa có cổng kiểm chứng giao diện thật.** 6 test trên đo *thuộc tính* của view. Không test nào
  **bấm** nút. Muốn thế phải có target `bundle.ui-testing` + `XCUIScreenshot` xuất ra artifact — đó là
  việc còn treo, và là thứ duy nhất biến mục "kiểm bằng mắt" ở trên thành tự động.
- **Chưa chốt hướng xử lý cho chiều dọc** nếu lỗi phần cứng che vẫn còn ở portrait.
- **R-21 vẫn chưa đổi:** đang chờ anh quyết (DECISIONS §7).
