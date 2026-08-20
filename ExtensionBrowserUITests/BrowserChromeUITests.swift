import UIKit
import XCTest

/// The app driven from outside its own process: launched, tapped, typed into, photographed.
///
/// `BrowserChromeAppearanceTests` already checks the same screen from inside, and does it faster and
/// more precisely. What it cannot do is press anything. Every defect a user reported on an iPhone XS
/// was reachable only by pressing something, so this target exists to press it.
final class BrowserChromeUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
        app = XCUIApplication()
        app.launch()
        settleToNotEditing()
    }

    /// Launch does not always land in the same place: `createNewTab` focuses the address bar, so a
    /// run that starts with no restored session comes up with the keyboard already open and the
    /// toolbar's control row hidden. Every test starts from "not editing" instead.
    ///
    /// This leans on the tap-to-dismiss gesture that `testTappingThePageAreaPutsTheKeyboardAway`
    /// covers. That is a real dependency and worth naming: if that gesture breaks, several tests
    /// here go red together, and the one with the plain name is the one that explains why.
    private func settleToNotEditing() {
        let keyboard = app.keyboards.element
        guard keyboard.waitForExistence(timeout: 3) else { return }
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        _ = waitForDisappearance(of: keyboard, timeout: 5)
    }

    override func tearDown() {
        // Rotation is device state, not app state — it survives a terminate and would leak into
        // whatever test runs next.
        XCUIDevice.shared.orientation = .portrait
        app?.terminate()
        app = nil
        super.tearDown()
    }

    // MARK: - The address bar actually draws what is typed

    /// The defect that shipped, measured the only way it shows: in pixels.
    ///
    /// One character is photographed, then eight, and the ink between the two is counted. Everything
    /// that is not a glyph — the magnifying glass, the clear button, the caret, the field's own
    /// background — is present in both shots and cancels out, so the difference is the text and
    /// nothing else. With the shipped bug the difference was approximately zero while
    /// `field.value` read back perfectly, which is exactly why no assertion on `value` would help.
    func testTypingIntoTheAddressBarPutsInkOnTheScreen() throws {
        let field = try addressField()
        field.tap()
        XCTAssertTrue(
            app.keyboards.element.waitForExistence(timeout: 10),
            "No keyboard came up, so nothing below this measures typing."
        )

        field.typeText("W")
        let single = field.screenshot().image
        attach(single, named: "address-bar-one-character")

        field.typeText("WWWWWWW")
        let eight = field.screenshot().image
        attach(eight, named: "address-bar-eight-characters")

        XCTAssertEqual(field.value as? String, "WWWWWWWW", "The field did not accept the text.")

        let inkForOne = try ScreenInk.inkPixelCount(in: single)
        let inkForEight = try ScreenInk.inkPixelCount(in: eight)
        let drawn = inkForEight - inkForOne

        XCTAssertGreaterThan(
            drawn,
            1000,
            """
            Seven more characters added \(drawn) pixels of ink (1 char: \(inkForOne), 8 chars: \
            \(inkForEight)). The text is in the field but is not being drawn against its background.
            """
        )
    }

    // MARK: - The keyboard has a way out

    /// There is no Cancel button, and `textFieldDidBeginEditing` hides the control row, so a tap on
    /// the page is the only exit. Before this was built there was none at all on a blank tab.
    func testTappingThePageAreaPutsTheKeyboardAway() throws {
        let field = try addressField()
        field.tap()
        let keyboard = app.keyboards.element
        XCTAssertTrue(keyboard.waitForExistence(timeout: 10), "The keyboard never appeared.")

        // Upper middle of the window: page content in every layout, and never the toolbar.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()

        XCTAssertTrue(
            waitForDisappearance(of: keyboard),
            "The keyboard stayed up. On a blank tab that leaves the user with no way to dismiss it."
        )
        attachScreen(named: "after-dismissing-the-keyboard")
    }

    /// The other half of the same gate. A recogniser that always begins would eat the first tap on
    /// every page, so it must be inert when the address bar is not being edited.
    func testATapOnThePageIsNotSwallowedWhenNotEditing() throws {
        let field = try addressField()
        field.tap()
        XCTAssertTrue(app.keyboards.element.waitForExistence(timeout: 10))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()
        XCTAssertTrue(waitForDisappearance(of: app.keyboards.element))

        // Not editing any more. This tap must reach the page, which here means it must not put the
        // keyboard back or otherwise change the chrome.
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.25)).tap()

        XCTAssertFalse(
            app.keyboards.element.waitForExistence(timeout: 2),
            "A tap on the page brought the keyboard back — the recogniser is not gated on editing."
        )
        XCTAssertTrue(field.exists, "The chrome disappeared after a plain tap on the page.")
    }

    // MARK: - Hardware

    /// Held sideways, a notched phone puts its inset on the side. The toolbar always cleared it —
    /// its controls hang off `layoutMarginsGuide` — so the address bar's own position is the ruler
    /// this test measures the content area against, and no device dimension is hardcoded.
    func testPageContentClearsTheNotchInLandscape() throws {
        XCUIDevice.shared.orientation = .landscapeLeft

        let field = try addressField()
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        let content = app.otherElements["browser.content"]
        XCTAssertTrue(
            content.waitForExistence(timeout: 10),
            "The content area is not in the accessibility tree, so its frame cannot be checked."
        )
        attachScreen(named: "landscape")

        // The toolbar insets its own contents by 12pt on top of the safe area (see
        // `configureToolbar`), so backing that out of the address bar's origin gives the inset
        // the system reported for this device.
        let safeAreaInset = field.frame.minX - 12

        XCTAssertGreaterThan(
            safeAreaInset,
            1,
            """
            This simulator reports no horizontal safe-area inset in landscape, so it cannot show \
            the defect. Pick a device with a notch or Dynamic Island — see scripts/ci/select-simulator.py.
            """
        )
        XCTAssertEqual(
            content.frame.minX,
            safeAreaInset,
            accuracy: 2,
            "Page content starts at \(content.frame.minX) while the safe area starts at \(safeAreaInset)."
        )
        XCTAssertEqual(
            content.frame.maxX,
            app.frame.maxX - safeAreaInset,
            accuracy: 2,
            "Page content runs past the right inset."
        )
    }

    // MARK: - Controls

    func testEveryToolbarControlIsPresentAndCanBeHit() {
        for label in ["Back", "Forward", "New tab", "Show tabs", "Browser menu"] {
            let button = app.buttons[label]
            XCTAssertTrue(button.waitForExistence(timeout: 10), "Missing toolbar control: \(label)")
            XCTAssertTrue(button.isHittable, "Toolbar control is not hittable: \(label)")
        }
        attachScreen(named: "start-page")
    }

    /// M4b's screens have never been opened by anything but a person. This does not press Add — that
    /// needs a package to arrive through the document picker — but it does prove the route exists
    /// and leaves a picture of where it lands.
    func testTheExtensionsScreenOpensFromTheMenu() throws {
        app.buttons["Browser menu"].tap()

        let item = try menuItem(titled: "Extensions")
        item.tap()

        XCTAssertTrue(
            app.navigationBars["Extensions"].waitForExistence(timeout: 10),
            "The Extensions screen did not come up."
        )
        attachScreen(named: "extensions-screen")
    }

    // MARK: - Lookups

    private func addressField() throws -> XCUIElement {
        let field = app.textFields["browser.addressField"]
        XCTAssertTrue(field.waitForExistence(timeout: 15), "The address bar never appeared.")
        return field
    }

    /// A `UIMenu` raised by `showsMenuAsPrimaryAction` surfaces under different element types across
    /// OS versions, so the title is looked up rather than the type guessed at.
    private func menuItem(titled title: String) throws -> XCUIElement {
        let candidates = [app.menuItems[title], app.buttons[title], app.staticTexts[title]]
        for candidate in candidates where candidate.waitForExistence(timeout: 3) {
            return candidate
        }
        // Deliberately a failure and not an `XCTSkip`. A skip here would report green for a menu
        // that never opened, which is the same blind spot this whole target was built to close.
        attachScreen(named: "menu-not-found")
        throw MenuLookupFailure(title: title)
    }

    private struct MenuLookupFailure: Error, CustomStringConvertible {
        let title: String
        var description: String {
            "No menu element titled \(title) appeared as a menu item, button, or label."
        }
    }
}
