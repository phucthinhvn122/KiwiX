import UIKit
import XCTest
@testable import ExtensionBrowser

/// Does the address bar actually draw anything?
///
/// `BrowserChromeAppearanceTests` asks whether the colours are readable and gets "yes". The UI test
/// photographs the running app and finds a field that holds text, shows its clear button, and draws
/// no glyph, no placeholder and no caret — in a band containing exactly three colours: the surface,
/// the focus border, and the antialiasing between them. Both cannot be right, and the pixels win.
///
/// So this file renders the field directly and counts what came out, in-process, where every number
/// that could explain it is reachable. The dump attached by every test is the point as much as the
/// assertions: a colour that resolves correctly and a text rect that is 300pt wide would rule out
/// the two obvious causes at a stroke.
@MainActor
final class AddressFieldRenderingTests: XCTestCase {
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

    // MARK: - The gate

    /// The user's report, reduced to one number: type into the bar, and count the pixels that
    /// changed inside the rect the field says it draws text in.
    func testTheAddressBarDrawsTheTextItHolds() throws {
        for style in [UIUserInterfaceStyle.dark, .light] {
            let field = try preparedField(style: style)
            field.text = "WWWWWWWW"
            field.setNeedsLayout()
            field.layoutIfNeeded()

            let reading = try measureTextArea(of: field, editing: false, label: "text-\(styleName(for: style))")

            XCTAssertGreaterThan(
                reading.ink,
                50,
                """
                Eight capital Ws in \(styleName(for: style)) mode drew \(reading.ink) ink pixels \
                (\(reading.description)). The field holds the string and renders nothing. \
                See the attached diagnostic dump for the geometry and colours behind this.
                """
            )
        }
    }

    /// The placeholder is drawn by UIKit in its own colour, which `textColor` cannot affect. If the
    /// placeholder is missing too then no assignment on this field is the cause, and the fault is in
    /// the rect, the font, or the view tree.
    ///
    /// Gated on `faintInk`, not `ink`: `.placeholderText` in dark mode composites to roughly 0.44
    /// luminance over a 0.24 surface, which is deliberately below the ink threshold that exists to
    /// separate readable text from unreadable text.
    func testTheAddressBarDrawsItsPlaceholderWhenEmpty() throws {
        for style in [UIUserInterfaceStyle.dark, .light] {
            let field = try preparedField(style: style)
            field.text = nil
            field.setNeedsLayout()
            field.layoutIfNeeded()

            XCTAssertNotNil(field.placeholder, "The field has no placeholder to draw.")
            let reading = try measureTextArea(
                of: field,
                editing: false,
                label: "placeholder-\(styleName(for: style))"
            )

            XCTAssertGreaterThan(
                reading.faintInk,
                50,
                """
                The placeholder "\(field.placeholder ?? "")" drew \(reading.faintInk) pixels of any \
                colour at all in \(styleName(for: style)) mode (\(reading.description)). UIKit owns this \
                text, so nothing this app assigns to `textColor` can explain it.
                """
            )
        }
    }

    /// Geometry, asserted on its own so a failure names the cause instead of just the symptom. This
    /// needs no rendering at all and cannot be flaky.
    func testTheAddressBarLeavesItselfRoomToDrawText() throws {
        let field = try preparedField(style: .dark)
        field.text = "WWWWWWWW"
        field.setNeedsLayout()
        field.layoutIfNeeded()

        attach(dump(of: field), named: "geometry-dump")

        let textRect = field.textRect(forBounds: field.bounds)
        let editingRect = field.editingRect(forBounds: field.bounds)
        let font = try XCTUnwrap(field.font, "The field has no font, so it can draw no glyphs.")

        XCTAssertGreaterThan(font.pointSize, 8, "Font is \(font.pointSize)pt — too small to read.")
        XCTAssertGreaterThan(field.bounds.width, 200, "The field itself is only \(field.bounds.width)pt wide.")
        XCTAssertGreaterThan(textRect.width, 100, "The resting text rect is \(textRect) — no room for text.")
        XCTAssertGreaterThan(textRect.height, 10, "The resting text rect is \(textRect) — no room for text.")
        XCTAssertGreaterThan(editingRect.width, 100, "The editing text rect is \(editingRect).")
        XCTAssertGreaterThan(editingRect.height, 10, "The editing text rect is \(editingRect).")
        XCTAssertTrue(
            field.bounds.contains(textRect.intersection(field.bounds)) && !textRect.intersection(field.bounds).isNull,
            "The text rect \(textRect) falls outside the field's bounds \(field.bounds), so anything drawn in it is clipped away."
        )
        XCTAssertFalse(field.isHidden, "The field is hidden.")
        XCTAssertGreaterThan(field.alpha, 0.99, "The field's alpha is \(field.alpha).")
    }

    // MARK: - Measuring

    /// Renders the field twice and keeps the more generous answer.
    ///
    /// `drawHierarchy` is the accurate path but wants a live window and can come back blank in a
    /// test process; `layer.render(in:)` always draws but skips some hosted content. Taking the max
    /// means a limitation of either path cannot fail a field that is drawing properly — only a field
    /// that draws nothing under both fails, and that is the claim being made.
    private func measureTextArea(
        of field: UITextField,
        editing: Bool,
        label: String
    ) throws -> ScreenInk.Reading {
        let bounds = field.bounds
        XCTAssertFalse(bounds.isEmpty, "The field has no bounds to render.")
        let renderer = UIGraphicsImageRenderer(bounds: bounds)

        let viaHierarchy = renderer.image { _ in
            _ = field.drawHierarchy(in: bounds, afterScreenUpdates: true)
        }
        let viaLayer = renderer.image { context in
            field.layer.render(in: context.cgContext)
        }

        let region = editing ? field.editingRect(forBounds: bounds) : field.textRect(forBounds: bounds)
        let hierarchyCrop = try crop(viaHierarchy, to: region)
        let layerCrop = try crop(viaLayer, to: region)

        attach(image: hierarchyCrop, named: "\(label)-drawHierarchy")
        attach(image: layerCrop, named: "\(label)-layerRender")
        attach(image: viaHierarchy, named: "\(label)-whole-field")

        let hierarchyReading = try ScreenInk.read(hierarchyCrop)
        let layerReading = try ScreenInk.read(layerCrop)
        attach(
            """
            \(label)
              text rect used: \(region)
              drawHierarchy: \(hierarchyReading.description)
              layer.render:  \(layerReading.description)

            \(dump(of: field))
            """,
            named: "\(label)-dump"
        )

        let hierarchyMarks: Int = hierarchyReading.ink + hierarchyReading.faintInk
        let layerMarks: Int = layerReading.ink + layerReading.faintInk
        return hierarchyMarks >= layerMarks ? hierarchyReading : layerReading
    }

    private func crop(_ image: UIImage, to rect: CGRect) throws -> UIImage {
        let source = try XCTUnwrap(image.cgImage, "The render produced no bitmap.")
        let scale = image.scale
        let scaled = CGRect(
            x: rect.origin.x * scale,
            y: rect.origin.y * scale,
            width: rect.width * scale,
            height: rect.height * scale
        ).integral
        let clamped = scaled.intersection(CGRect(x: 0, y: 0, width: source.width, height: source.height))
        guard !clamped.isNull, clamped.width >= 1, clamped.height >= 1,
              let cropped = source.cropping(to: clamped) else {
            // A text rect that does not overlap the field is itself the finding, so this returns the
            // whole render rather than throwing and losing the picture.
            return image
        }
        return UIImage(cgImage: cropped, scale: scale, orientation: .up)
    }

    // MARK: - Diagnostics

    private func dump(of field: UITextField) -> String {
        let bounds = field.bounds
        let traits = field.traitCollection
        func rgba(_ colour: UIColor?) -> String {
            guard let colour else { return "nil" }
            var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
            let resolved = colour.resolvedColor(with: traits)
            guard resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
                return "\(resolved)"
            }
            return String(format: "r%.3f g%.3f b%.3f a%.3f", red, green, blue, alpha)
        }
        // Built line by line on purpose. As one multi-line literal with twenty-odd interpolations
        // this is a single expression, and that is exactly the shape that made the Swift
        // type-checker time out and fail a build in this same commit's first attempt.
        var lines = [String]()
        func row(_ label: String, _ value: String) {
            lines.append(label.padding(toLength: 20, withPad: " ", startingAt: 0) + value)
        }
        row("bounds", "\(bounds)")
        row("frame", "\(field.frame)")
        row("textRect", "\(field.textRect(forBounds: bounds))")
        row("editingRect", "\(field.editingRect(forBounds: bounds))")
        row("placeholderRect", "\(field.placeholderRect(forBounds: bounds))")
        row("leftViewRect", "\(field.leftViewRect(forBounds: bounds))")
        row("rightViewRect", "\(field.rightViewRect(forBounds: bounds))")
        row("clearButtonRect", "\(field.clearButtonRect(forBounds: bounds))")
        row("borderRect", "\(field.borderRect(forBounds: bounds))")
        row("leftView", "\(String(describing: field.leftView?.frame)) mode \(field.leftViewMode.rawValue)")
        row("rightView", "\(String(describing: field.rightView?.frame)) mode \(field.rightViewMode.rawValue)")
        row("font", "\(String(describing: field.font))")
        row("adjustsForCategory", "\(field.adjustsFontForContentSizeCategory)")
        row("textColor", rgba(field.textColor))
        row("backgroundColor", rgba(field.backgroundColor))
        row("tintColor", rgba(field.tintColor))
        row("text", "\(String(describing: field.text))")
        row("placeholder", "\(String(describing: field.placeholder))")
        row("attributedText", "\(String(describing: field.attributedText?.string))")
        row("borderStyle", "\(field.borderStyle.rawValue)")
        row("textAlignment", "\(field.textAlignment.rawValue)")
        row("alpha", "\(field.alpha)")
        row("isHidden", "\(field.isHidden)")
        row("clipsToBounds", "\(field.clipsToBounds)")
        row("isSecureTextEntry", "\(field.isSecureTextEntry)")
        row("isEnabled", "\(field.isEnabled)")
        row("contentVertAlign", "\(field.contentVerticalAlignment.rawValue)")
        row("interfaceStyle", "\(traits.userInterfaceStyle.rawValue)")
        row("contentSizeCategory", "\(traits.preferredContentSizeCategory.rawValue)")
        row("displayScale", "\(traits.displayScale)")
        for subview in field.subviews {
            let kind = "\(type(of: subview))"
            row("  subview", kind + " frame \(subview.frame) hidden \(subview.isHidden) alpha \(subview.alpha)")
        }
        return lines.joined(separator: "\n")
    }

    private func attach(_ text: String, named name: String) {
        let attachment = XCTAttachment(string: text)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func attach(image: UIImage, named name: String) {
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Lookups

    private func preparedField(style: UIUserInterfaceStyle) throws -> UITextField {
        window.overrideUserInterfaceStyle = style
        controller.view.layoutIfNeeded()
        let field = try XCTUnwrap(
            findView(UITextField.self, identifier: "browser.addressField"),
            "The address bar is not in the view hierarchy."
        )
        return field
    }

    private func styleName(for style: UIUserInterfaceStyle) -> String {
        style == .dark ? "dark" : "light"
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
}
