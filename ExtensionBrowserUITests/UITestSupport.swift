import UIKit
import XCTest

/// The XCUI-only half of the test support: everything here needs a running app to point at, so it
/// cannot live alongside `ScreenInk`, which the unit-test target shares.
extension XCTestCase {
    /// Keeps a screenshot in the result bundle whether the test passed or not.
    ///
    /// `.deleteOnSuccess` would throw away the only picture of a screen that is otherwise never
    /// looked at — the point of this target is that somebody can open the artifact and see the app.
    func attach(_ image: UIImage, named name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func attachScreen(named name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// XCTest's own `waitForNonExistence` is avoided here so this target keeps working on the
    /// toolchains that predate it.
    func waitForDisappearance(of element: XCUIElement, timeout: TimeInterval = 8) -> Bool {
        let gone = expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: element)
        return XCTWaiter().wait(for: [gone], timeout: timeout) == .completed
    }
}
