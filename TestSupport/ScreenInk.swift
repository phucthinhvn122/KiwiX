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

    /// Anything at all, as opposed to anything readable.
    static let faintThreshold: CGFloat = 2.0 / 255.0

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
            // A hair above the rounding noise a bitmap context introduces, so this catches
            // dark-on-dark text that the main threshold is deliberately blind to.
            if distance > faintThreshold { faint += 1 }
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
        // Only the drawing happens against the raw pointer, which stops being valid the moment the
        // closure returns. The pixels it wrote stay in `buffer`, so everything else reads that.
        let drawn: Bool = buffer.withUnsafeMutableBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return false }
            let context = CGContext(
                data: base,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
            guard let context else { return false }
            context.draw(source, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw InkError.noContext }

        var result = [Sample]()
        result.reserveCapacity(width * height)
        var index = 0
        while index + 2 < buffer.count {
            let red = buffer[index]
            let green = buffer[index + 1]
            let blue = buffer[index + 2]
            result.append(Sample(packed: pack(red, green, blue), luminance: luminance(red, green, blue)))
            index += 4
        }
        return (result, width, height)
    }

    /// Rec. 709 weights, on sRGB values without linearising them. This is a distance measure for "is
    /// anything drawn here", not a WCAG contrast claim — `BrowserChromeAppearanceTests` makes that
    /// claim properly, on colours rather than pixels.
    ///
    /// Every step is typed. Written as one mixed-literal expression inline, this is the line that
    /// made the Swift type-checker give up and fail the build.
    private static func luminance(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> CGFloat {
        let scaledRed: CGFloat = 0.2126 * CGFloat(red)
        let scaledGreen: CGFloat = 0.7152 * CGFloat(green)
        let scaledBlue: CGFloat = 0.0722 * CGFloat(blue)
        return (scaledRed + scaledGreen + scaledBlue) / 255.0
    }

    private static func pack(_ red: UInt8, _ green: UInt8, _ blue: UInt8) -> UInt32 {
        let high: UInt32 = UInt32(red) << 16
        let mid: UInt32 = UInt32(green) << 8
        return high | mid | UInt32(blue)
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
