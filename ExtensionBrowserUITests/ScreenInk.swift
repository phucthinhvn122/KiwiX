import UIKit
import XCTest

/// Counting drawn glyphs by looking at pixels.
///
/// The defect this exists for was invisible to every other kind of check: the address bar held the
/// right string, reported the right value to accessibility, and drew it in a colour that matched the
/// background. `field.value == "example.com"` passed the whole time. The only witness is the screen.
enum ScreenInk {
    /// A pixel counts as ink when its luminance is this far from the surface it sits on.
    ///
    /// Sized against the two outcomes it has to separate, both in dark mode: `.label` white on
    /// `KiwiTheme.fieldSurface` is about 0.95 apart, and the shipped defect — UIKit's fixed dark
    /// default on that same dark surface — is about 0.05. Anything between those two is a colour
    /// nobody should be shipping either.
    static let inkThreshold: CGFloat = 0.25

    /// Pixels in `image` that stand out from its own dominant colour.
    ///
    /// The background is measured rather than assumed, so this says nothing about *which* theme is
    /// on screen — only whether something was drawn on top of it.
    static func inkPixelCount(in image: UIImage) throws -> Int {
        let (pixels, count) = try luminances(of: image)
        guard count > 0 else {
            throw InkError.emptyImage
        }
        let background = dominantLuminance(pixels)
        return pixels.reduce(into: 0) { total, luminance in
            if abs(luminance - background) > inkThreshold {
                total += 1
            }
        }
    }

    // MARK: - Internals

    enum InkError: Error, CustomStringConvertible {
        case noBitmap
        case noContext
        case emptyImage

        var description: String {
            switch self {
            case .noBitmap: "The screenshot carried no bitmap to read."
            case .noContext: "Could not open a bitmap context over the screenshot."
            case .emptyImage: "The screenshot measured zero pixels."
            }
        }
    }

    private static func luminances(of image: UIImage) throws -> ([CGFloat], Int) {
        guard let source = image.cgImage else { throw InkError.noBitmap }
        let width = source.width
        let height = source.height
        guard width > 0, height > 0 else { throw InkError.emptyImage }

        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        // Drawing and reading both happen inside the closure: the pointer handed out here stops
        // being valid the moment it returns, so the CGContext must not outlive it.
        let result: [CGFloat]? = buffer.withUnsafeMutableBytes { raw -> [CGFloat]? in
            guard let base = raw.baseAddress,
                  let context = CGContext(
                      data: base,
                      width: width,
                      height: height,
                      bitsPerComponent: 8,
                      bytesPerRow: width * 4,
                      space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  )
            else {
                return nil
            }
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))

            let bytes = raw.bindMemory(to: UInt8.self)
            var luminances = [CGFloat]()
            luminances.reserveCapacity(width * height)
            for index in stride(from: 0, to: bytes.count, by: 4) {
                let red = CGFloat(bytes[index]) / 255
                let green = CGFloat(bytes[index + 1]) / 255
                let blue = CGFloat(bytes[index + 2]) / 255
                // Rec. 709 weights, on sRGB values without linearising them. This is a distance
                // measure for "is anything drawn here", not a WCAG contrast claim —
                // BrowserChromeAppearanceTests makes that claim properly, on colours not pixels.
                luminances.append(0.2126 * red + 0.7152 * green + 0.0722 * blue)
            }
            return luminances
        }

        guard let result else { throw InkError.noContext }
        return (result, width * height)
    }

    /// The most common luminance, to 64 buckets. A text field is overwhelmingly its own background,
    /// so the tallest bucket is the surface even when a glyph or an icon is on top of it.
    private static func dominantLuminance(_ pixels: [CGFloat]) -> CGFloat {
        let bucketCount = 64
        var histogram = [Int](repeating: 0, count: bucketCount)
        for luminance in pixels {
            let bucket = min(bucketCount - 1, max(0, Int(luminance * CGFloat(bucketCount))))
            histogram[bucket] += 1
        }
        let tallest = histogram.indices.max(by: { histogram[$0] < histogram[$1] }) ?? 0
        return (CGFloat(tallest) + 0.5) / CGFloat(bucketCount)
    }
}

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
