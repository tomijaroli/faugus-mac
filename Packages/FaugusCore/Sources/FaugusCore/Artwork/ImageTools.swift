import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Image helpers behind the artwork features (PIL and GdkPixbuf upstream; ImageIO here).
public enum ImageTools {
    public enum Failure: Error { case invalidImage, writeFailed }

    /// Decoded images beyond this are rejected so a hostile file cannot exhaust memory.
    static let maxPixels = 100_000_000

    public static func decode(_ data: Data, frame: Int = 0) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
            CGImageSourceGetCount(source) > frame,
            let props = CGImageSourceCopyPropertiesAtIndex(source, frame, nil) as? [CFString: Any],
            let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
            w > 0, h > 0, w * h <= maxPixels
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, frame, nil)
    }

    public static func isValid(_ data: Data) -> Bool { !data.isEmpty && decode(data) != nil }

    public static func isValid(path: String) -> Bool {
        guard let d = FileManager.default.contents(atPath: path) else { return false }
        return isValid(d)
    }

    /// The frame with the most pixels (`icon.info["sizes"]` sorted descending upstream).
    public static func largestFrame(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var best: (index: Int, pixels: Int)?
        for i in 0..<CGImageSourceGetCount(source) {
            guard let props = CGImageSourceCopyPropertiesAtIndex(source, i, nil) as? [CFString: Any],
                let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int,
                w * h <= maxPixels
            else { continue }
            if best == nil || w * h > best!.pixels { best = (i, w * h) }
        }
        guard let best else { return nil }
        return CGImageSourceCreateImageAtIndex(source, best.index, nil)
    }

    /// `img.convert("RGBA").resize((w, h), LANCZOS)`: stretches to exactly `width` x `height`.
    public static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0,
            let ctx = CGContext(
                data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }

    public static func png(_ image: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest) ? out as Data : nil
    }

    /// `resize_image_file`: any readable image to a PNG of exactly `width` x `height`.
    public static func resizeFile(from src: String, to dst: String, width: Int, height: Int) throws {
        guard let data = FileManager.default.contents(atPath: src), let image = decode(data) else { throw Failure.invalidImage }
        guard let scaled = resized(image, width: width, height: height), let out = png(scaled) else { throw Failure.writeFailed }
        try JSONFile.atomicWrite(out, to: dst)
    }

    /// `normalize_icon_bytes` + `resize_icon_bytes`: any image (an `.ico` uses its largest frame)
    /// as a square PNG.
    public static func iconPNG(from data: Data, size: Int = 256) -> Data? {
        guard let frame = largestFrame(data) ?? decode(data) else { return nil }
        if frame.width == size, frame.height == size, let same = png(frame) { return same }
        guard let scaled = resized(frame, width: size, height: size) else { return nil }
        return png(scaled)
    }
}
