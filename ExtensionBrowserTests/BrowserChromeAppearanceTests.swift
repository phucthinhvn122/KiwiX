import UIKit
import XCTest
@testable import ExtensionBrowser

/// The browser's own chrome, checked the way a person looks at it: is the text readable, does the
/// layout stay out from under the hardware, does a tap put the keyboard away.
///
/// This file exists because a real device turned up three defects that 134 passing tests could not
/// see — nothing in the suite had ever built the browser's view hierarchy. Every assertion below
/// fails against the code as it shipped.
@MainActor
final class BrowserChromeAppearanceTests: XCTestCase {
    private var window: UIWindow!
    private var controller: BrowserViewController!

    override func setUp() async throws {
        try await super.setUp()
        controller = BrowserViewController()
        window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 844))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        controller.loadViewIfNeeded()
        controller.view.layoutIfNeeded()
    }

    override func tearDown() async throws {
        window?.isHidden = true
        window?.rootViewController = nil
        window = nil
        controller = nil
        try await super.tearDown()
    }

    // MARK: - Readability

    /// The defect that shipped: no `textColor` was ever assigned, so what the user typed was drawn
    /// in UIKit's fixed default while the field's background followed the interface style. The
    /// caret was visible — it takes the window tint — which is why the bar looked like it was
    /// swallowing keystrokes rather than like it had a colour problem.
    func testTheAddressBarStatesItsTextColourRatherThanInheritingOne() throws {
        let field = try addressField()
        XCTAssertNotNil(
            field.textColor,
            "The address bar must state a text colour: its background is style-dependent, so the default cannot be right in both."
        )
    }

    func testTypedTextIsReadableOnEveryBackgroundTheAddressBarCanWear() throws {
        let field = try addressField()
        let textColor = try XCTUnwrap(field.textColor)

        // Every background `updatePrivateAppearance` and `textFieldDidBeginEditing` can assign.
        let backgrounds: [(String, UIColor)] = [
            ("idle", KiwiTheme.fieldSurface),
            ("editing", KiwiTheme.elevatedSurface),
            ("private", KiwiTheme.privateAccent.withAlphaComponent(0.14))
        ]

        for style in [UIUserInterfaceStyle.light, .dark] {
            let traits = UITraitCollection(userInterfaceStyle: style)
            let text = textColor.resolvedColor(with: traits)
            for (name, background) in backgrounds {
                // The translucent private tint sits over the canvas, so it is judged composited.
                let surface = Self.blend(
                    background.resolvedColor(with: traits),
                    over: KiwiTheme.canvas.resolvedColor(with: traits)
                )
                let ratio = Self.contrastRatio(text, surface)
                XCTAssertGreaterThan(
                    ratio,
                    4.5,
                    "Address text on the \(name) background in \(style == .dark ? "dark" : "light") mode is only \(String(format: "%.2f", ratio)):1"
                )
            }
        }
    }

    // MARK: - Hardware

    /// A notched phone held sideways puts the inset on the side. Pinning to the raw view edge —
    /// which is what the top-only safe-area constraint left in place — slides page content under
    /// the cut-out.
    func testContentStaysInsideTheSafeAreaWhenTheInsetIsHorizontal() throws {
        let content = try contentContainer()

        controller.additionalSafeAreaInsets = UIEdgeInsets(top: 0, left: 44, bottom: 0, right: 44)
        controller.view.layoutIfNeeded()

        let safeFrame = controller.view.safeAreaLayoutGuide.layoutFrame
        let contentFrame = content.frame

        XCTAssertGreaterThanOrEqual(
            contentFrame.minX,
            safeFrame.minX,
            "Content starts \(safeFrame.minX - contentFrame.minX)pt under the left inset."
        )
        XCTAssertLessThanOrEqual(
            contentFrame.maxX,
            safeFrame.maxX,
            "Content runs \(contentFrame.maxX - safeFrame.maxX)pt past the right inset."
        )
        XCTAssertFalse(contentFrame.isEmpty, "The content area collapsed instead of being inset.")
    }

    /// Vertically the content area is *supposed* to escape the safe area: a browser's page fills the
    /// screen and scrolls under the status bar, and `WebViewFactory` sets
    /// `contentInsetAdjustmentBehavior = .always` so the scroll view holds the text clear of the
    /// notch instead. Pinning the container below the safe area instead — which is what shipped —
    /// leaves a band of app background above every site, and on a dark theme over a light page that
    /// reads as the page being cut off.
    ///
    /// Horizontal is the opposite case and is covered above: there the container really is inset,
    /// because a landscape notch has to be cleared by geometry rather than by scrolling.
    func testTheContentAreaReachesTheTopOfTheWindowSoThePageCanPaintUnderTheNotch() throws {
        let content = try contentContainer()
        controller.additionalSafeAreaInsets = UIEdgeInsets(top: 44, left: 0, bottom: 0, right: 0)
        controller.view.layoutIfNeeded()

        XCTAssertEqual(
            content.frame.minY,
            controller.view.bounds.minY,
            accuracy: 0.5,
            "The page cannot paint behind the status bar if its container starts below it."
        )
    }

    /// The other half of the same contract. Only a web page may draw under the notch, because only a
    /// web page brings its own background; the app's own surfaces have to stay inside the safe area
    /// or their text sits under the clock.
    func testTheStartPageStaysInsideTheSafeAreaEvenThoughItsContainerDoesNot() throws {
        let startPage = try XCTUnwrap(
            findView(UIView.self, identifier: "browser.startPage"),
            "No view identified as browser.startPage."
        )
        controller.additionalSafeAreaInsets = UIEdgeInsets(top: 44, left: 0, bottom: 0, right: 0)
        controller.view.layoutIfNeeded()

        let safeFrame = controller.view.safeAreaLayoutGuide.layoutFrame
        XCTAssertGreaterThanOrEqual(
            startPage.frame.minY,
            safeFrame.minY - 0.5,
            "The start page is the app's own surface and must not run under the status bar."
        )
    }

    // MARK: - Keyboard

    func testTheContentAreaCarriesATapToDismissRecogniser() throws {
        XCTAssertNotNil(try dismissKeyboardTap())
    }

    /// Both halves matter. A recogniser that always begins would swallow the first tap on every
    /// link; one that never begins is the missing feature.
    func testTheDismissTapBeginsOnlyWhileTheAddressBarIsBeingEdited() throws {
        let tap = try dismissKeyboardTap()
        let delegate = try XCTUnwrap(tap.delegate, "The recogniser has no delegate to gate it.")
        let field = try addressField()

        XCTAssertFalse(
            delegate.gestureRecognizerShouldBegin?(tap) ?? true,
            "Not editing: this tap must not begin, or an ordinary tap on a page would be eaten."
        )

        guard field.becomeFirstResponder() else {
            throw XCTSkip("The test window would not take first responder.")
        }
        XCTAssertTrue(
            delegate.gestureRecognizerShouldBegin?(tap) ?? false,
            "Editing: a tap on the page is how the keyboard goes away — there is no Cancel button."
        )

        XCTAssertTrue(field.resignFirstResponder())
        XCTAssertFalse(delegate.gestureRecognizerShouldBegin?(tap) ?? true)
    }

    /// Other recognisers on the same view are not this delegate's business, and answering false for
    /// them would disable them.
    func testTheDelegateDoesNotGateRecognisersItDoesNotOwn() throws {
        let tap = try dismissKeyboardTap()
        let delegate = try XCTUnwrap(tap.delegate)
        let unrelated = UITapGestureRecognizer()

        XCTAssertTrue(delegate.gestureRecognizerShouldBegin?(unrelated) ?? false)
    }

    // MARK: - Lookups

    private func addressField() throws -> UITextField {
        try XCTUnwrap(
            findView(UITextField.self, identifier: "browser.addressField"),
            "No view identified as browser.addressField."
        )
    }

    private func contentContainer() throws -> UIView {
        try XCTUnwrap(
            findView(UIView.self, identifier: "browser.content"),
            "No view identified as browser.content."
        )
    }

    private func dismissKeyboardTap() throws -> UIGestureRecognizer {
        let content = try contentContainer()
        return try XCTUnwrap(
            content.gestureRecognizers?.first { $0.name == BrowserViewController.dismissKeyboardTapName },
            "The content area has no tap-to-dismiss recogniser."
        )
    }

    private func findView<T: UIView>(_ type: T.Type, identifier: String) -> T? {
        func search(_ view: UIView) -> T? {
            if let match = view as? T, match.accessibilityIdentifier == identifier {
                return match
            }
            for subview in view.subviews {
                if let found = search(subview) {
                    return found
                }
            }
            return nil
        }
        return search(controller.view)
    }

    // MARK: - Colour maths (WCAG 2.1 relative luminance)

    private static func contrastRatio(_ first: UIColor, _ second: UIColor) -> CGFloat {
        let a = relativeLuminance(first)
        let b = relativeLuminance(second)
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }

    private static func relativeLuminance(_ color: UIColor) -> CGFloat {
        let (red, green, blue, _) = components(of: color)
        func linear(_ value: CGFloat) -> CGFloat {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(red) + 0.7152 * linear(green) + 0.0722 * linear(blue)
    }

    private static func blend(_ top: UIColor, over bottom: UIColor) -> UIColor {
        let (topRed, topGreen, topBlue, alpha) = components(of: top)
        guard alpha < 1 else { return top }
        let (baseRed, baseGreen, baseBlue, _) = components(of: bottom)
        return UIColor(
            red: topRed * alpha + baseRed * (1 - alpha),
            green: topGreen * alpha + baseGreen * (1 - alpha),
            blue: topBlue * alpha + baseBlue * (1 - alpha),
            alpha: 1
        )
    }

    private static func components(of color: UIColor) -> (CGFloat, CGFloat, CGFloat, CGFloat) {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        guard color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
            var white: CGFloat = 0
            color.getWhite(&white, alpha: &alpha)
            return (white, white, white, alpha)
        }
        return (red, green, blue, alpha)
    }
}
