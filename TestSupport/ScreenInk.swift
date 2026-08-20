import UIKit

/// Counting drawn glyphs by looking at pixels.
///
/// The defect this exists for was invisible to every other kind of check: the address bar reported
/// the right value to accessibility while the screen showed nothing at all. `field.value` passed the
/// whole time. The only witness is the image.
///
/// Shared by both test targets — the UI-test target photographs the running app, the unit-test
/// target renders a view directly — so it deliberately depends on nothing but UIKit.
enum ScreenInk {
    /// A pixel counts as ink when its luminance is this far from the surface it sits on.
    ///
    /// Sized against the two outcomes it has to separate, both in dark mode: `.label` white on
    /// `KiwiTheme.fieldSurface` is about 0.95 apart, and text drawn in UIKit's fixed dark default on
    /// that same dark surface is about 0.05. Anything between those two is a colour nobody should be
    /// shipping either.
    static let inkThreshold: CGFloat = 0.25

    /// Everything the pixels can say about one image, in one pass.
    ///
    /// `ink` alone answers "was anything drawn". When the answer is no, `distinctColours` and
    /// `faintInk` are what separate "drawn in the background colour" from "not drawn at all" — a
    /// glyph tinted to match its surface still produces no new colours, but a glyph drawn in *any*
    /// other colour, however close, shows up in `faintInk`.
    struct Reading {
        let width: Int
        let height: Int
        let background: CGFloat
        let ink: Int
        let faintInk: Int
        let distinctColours: Int

        var description: String {
            """
            \(width)x\(height) background-luminance \(String(format: "%.3f", background)) \
            ink \(ink) faint-ink \(faintInk) distinct-colours \(distinctColours)
            """
        }
    }

    /// Pixels in `image` that stand out from its own dominant colour.
    ///
    /// The background is measured rather than assumed, so this says nothing about *which* theme is
    /// on screen — only whether something was drawn on top of it.
    static func inkPixelCount(in image: UIImage) throws -> Int {
        try read(image).ink
    }

    static func read(_ image: UIImage) throws -> Reading {
        let (pixels, width, height) = try samples(of: image)
        guard !pixels.isEmpty else { throw InkError.emptyImage }

        let background = dominantLuminance(pixels.map(\.luminance))
        var ink = 0
        var faint = 0
        var colours = Set<UInt32>()
        for pixel in pixels {
            let distance = abs(pixel.luminance - background)
            if distance > inkThreshold { ink += 1 }
            // 2/255 is a hair above the rounding noise a bitmap context introduces, so this catches
            // dark-on-dark text that the main threshold is deliberately blind to.
            if distance > 2.0 / 255.0 { faint += 1 }
            colours.insert(pixel.packed)
        }
        return Reading(
            width: width,
            height: height,
            background: background,
            ink: ink,
            faintInk: faint,
            distinctColours: colours.count
        )
    }

    // MARK: - Internals

    enum InkError: Error, CustomStringConvertible {
        case noBitmap
        case noContext
        case emptyImage

        var description: String {
            switch self {
            case .noBitmap: "The image carried no bitmap to read."
            case .noContext: "Could not open a bitmap context over the image."
            case .emptyImage: "The image measured zero pixels."
            }
        }
    }

    private struct Sample {
        let packed: UInt32
        let luminance: CGFloat
    }

    private static func samples(of image: UIImage) throws -> ([Sample], Int, Int) {
        guard let source = image.cgImage else { throw InkError.noBitmap }
        let width = source.width
        let height = source.height
        guard width > 0, height > 0 else { throw InkError.emptyImage }

        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        // Drawing and reading both happen inside the closure: the pointer handed out here stops
        // being valid the moment it returns, so the CGContext must not outlive it.
        let result: [Sample]? = buffer.withUnsafeMutableBytes { raw -> [Sample]? in
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
            var samples = [Sample]()
            samples.reserveCapacity(width * height)
            for index in stride(from: 0, to: bytes.count, by: 4) {
                let red = bytes[index]
                let green = bytes[index + 1]
                let blue = bytes[index + 2]
                // Rec. 709 weights, on sRGB values without linearising them. This is a distance
                // measure for "is anything drawn here", not a WCAG contrast claim —
                // BrowserChromeAppearanceTests makes that claim properly, on colours not pixels.
                let luminance = (0.2126 * CGFloat(red) + 0.7152 * CGFloat(green) + 0.0722 * CGFloat(blue)) / 255
                let packed = UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue)
                samples.append(Sample(packed: packed, luminance: luminance))
            }
            return samples
        }

        guard let result else { throw InkError.noContext }
        return (result, width, height)
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
