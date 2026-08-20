import UIKit

/// A fixed-size host for a `UITextField` overlay view (`leftView` / `rightView`).
///
/// `UITextField` decides how much of itself to hand an overlay by asking the overlay how big it is.
/// A plain `UIView` answers `noIntrinsicMetric`, and the measured consequence — not a theory, this
/// came out of an in-process rect dump on the simulator — is that the field hands it *everything*:
///
///     bounds        (0, 0, 305.67, 44)
///     leftViewRect  (0, 0, 305.67, 44)   <- the icon container swallowed the whole field
///     textRect      (305.67, 0, 0, 44)   <- nothing left, 0pt wide
///
/// A zero-width text rect draws no glyphs, no placeholder and no caret, while the background, the
/// border and the clear button (laid out from the right edge) all keep drawing normally. That is
/// exactly the symptom the address bar had: type into it and nothing appears, though the field is
/// holding the text and reporting it to accessibility. Setting a `frame` on the container is not
/// enough, because the frame is what the field overwrites.
///
/// So this answers the size question three ways - `intrinsicContentSize`, `sizeThatFits(_:)` and the
/// initial `frame` - to cover whichever route UIKit takes to ask.
final class AddressAccessoryView: UIView {
    private let fixedSize: CGSize

    init(size: CGSize) {
        fixedSize = size
        super.init(frame: CGRect(origin: .zero, size: size))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override var intrinsicContentSize: CGSize { fixedSize }

    override func sizeThatFits(_ size: CGSize) -> CGSize { fixedSize }
}
