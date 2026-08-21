import UIKit
import XCTest
@testable import ExtensionBrowser

/// The address bar must never name a page that was not loaded.
///
/// `didStartProvisionalNavigation` commits `WKWebView.url`, which during a provisional load is the
/// *target* rather than what is rendered. If that load never commits — `window.stop()` from a
/// script, the user pressing Stop — the previous document stays live, and without a rollback the
/// chrome goes on naming somewhere the browser never went, with the padlock the target's scheme
/// earned. These tests pin the rollback at the level it is implemented: `TabManager`.
@MainActor
final class AddressRollbackTests: XCTestCase {
    func testRevertingToACommittedURLReplacesTheProvisionalOne() throws {
        let manager = TabManager(maximumWarmTabs: 0, maximumTabCount: 4)
        let tab = try manager.createTab(select: true)
        let rendered = try XCTUnwrap(URL(string: "https://rendered.example/page"))
        let provisional = try XCTUnwrap(URL(string: "https://spoofed.example/"))

        manager.updateTab(id: tab.id, url: rendered)
        manager.updateTab(id: tab.id, url: provisional)
        XCTAssertEqual(tab.url, provisional, "Precondition: the provisional target is on display")

        manager.revertToCommittedURL(tabID: tab.id, committedURL: rendered)

        XCTAssertEqual(tab.url, rendered, "The address must name the document that is on screen")
    }

    /// A tab whose very first load is cancelled committed nothing, so it has no address. `nil` has
    /// to be a value here — `updateTab(id:url:)` treats it as "leave it alone", which is exactly
    /// the behaviour that would strand the target of a load that never happened.
    func testRevertingWithNoCommittedLoadClearsTheAddress() throws {
        let manager = TabManager(maximumWarmTabs: 0, maximumTabCount: 4)
        let tab = try manager.createTab(select: true)
        let provisional = try XCTUnwrap(URL(string: "https://spoofed.example/"))

        manager.updateTab(id: tab.id, url: provisional)
        XCTAssertEqual(tab.url, provisional)

        manager.revertToCommittedURL(tabID: tab.id, committedURL: nil)

        XCTAssertNil(tab.url)
    }

    func testRevertingDropsTheFaviconOfThePageThatWasNeverLoaded() throws {
        let manager = TabManager(maximumWarmTabs: 0, maximumTabCount: 4)
        let tab = try manager.createTab(select: true)
        let rendered = try XCTUnwrap(URL(string: "https://rendered.example/"))
        let provisional = try XCTUnwrap(URL(string: "https://spoofed.example/"))

        manager.updateTab(id: tab.id, url: rendered)
        tab.favicon = UIImage(systemName: "lock.fill")
        manager.updateTab(id: tab.id, url: provisional)

        manager.revertToCommittedURL(tabID: tab.id, committedURL: rendered)

        XCTAssertNil(tab.favicon, "An icon fetched for one address must not survive onto another")
        XCTAssertEqual(tab.url, rendered)
    }

    func testRevertingToTheAddressAlreadyShownChangesNothing() throws {
        let manager = TabManager(maximumWarmTabs: 0, maximumTabCount: 4)
        let tab = try manager.createTab(select: true)
        let rendered = try XCTUnwrap(URL(string: "https://rendered.example/"))
        manager.updateTab(id: tab.id, url: rendered)
        tab.favicon = UIImage(systemName: "globe")

        manager.revertToCommittedURL(tabID: tab.id, committedURL: rendered)

        XCTAssertEqual(tab.url, rendered)
        XCTAssertNotNil(tab.favicon, "A no-op rollback must not throw away a good icon")
    }
}
