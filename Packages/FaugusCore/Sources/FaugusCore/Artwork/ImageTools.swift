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
              let properties = CGImageSourceCopyPropertiesAtIndex(source, frame, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0, width * height <= maxPixels
        else { return nil }
        return CGImageSourceCreateImageAtIndex(source, frame, nil)
    }

    /// Pixel size from the file header, without decoding the image.
    public static func pixelSize(atPath path: String) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
              CGImageSourceGetCount(source) > 0,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0
        else { return nil }
        return (width, height)
    }

    public static func isValid(_ data: Data) -> Bool {
        !data.isEmpty && decode(data) != nil
    }

    public static func isValid(path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path) else { return false }
        return isValid(data)
    }

    /// The frame with the most pixels (`icon.info["sizes"]` sorted descending upstream).
    public static func largestFrame(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var largest: (index: Int, pixels: Int)?
        for frameIndex in 0 ..< CGImageSourceGetCount(source) {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, frameIndex, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width * height <= maxPixels
            else { continue }
            if largest == nil || width * height > largest!.pixels {
                largest = (frameIndex, width * height)
            }
        }
        guard let largest else { return nil }
        return CGImageSourceCreateImageAtIndex(source, largest.index, nil)
    }

    /// `img.convert("RGBA").resize((w, h), LANCZOS)`: stretches to exactly `width` x `height`.
    public static func resized(_ image: CGImage, width: Int, height: Int) -> CGImage? {
        guard width > 0, height > 0,
              let context = CGContext(
                  data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    public static func png(_ image: CGImage) -> Data? {
        let pngData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(pngData, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? pngData as Data : nil
    }

    /// `resize_image_file`: any readable image to a PNG of exactly `width` x `height`.
    public static func resizeFile(from sourcePath: String, to destinationPath: String, width: Int, height: Int) throws {
        guard let data = FileManager.default.contents(atPath: sourcePath),
              let image = decode(data) else { throw Failure.invalidImage }
        guard let scaled = resized(image, width: width, height: height),
              let pngData = png(scaled) else { throw Failure.writeFailed }
        try JSONFile.atomicWrite(pngData, to: destinationPath)
    }

    /// `normalize_icon_bytes` + `resize_icon_bytes`: any image (an `.ico` uses its largest frame)
    /// as a square PNG.
    public static func iconPNG(from data: Data, size: Int = 256) -> Data? {
        guard let frame = largestFrame(data) ?? decode(data) else { return nil }
        if frame.width == size, frame.height == size, let same = png(frame) {
            return same
        }
        guard let scaled = resized(frame, width: size, height: size) else { return nil }
        return png(scaled)
    }
}
