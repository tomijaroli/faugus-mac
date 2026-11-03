import CoreGraphics
import Foundation
import ImageIO

/// Builds the `AppIcon.icns` of a shortcut bundle from a PNG, with ImageIO only (no AppKit).
public enum ShortcutIconBuilder {
    /// The pixel sizes of a full icon, smallest first.
    public static let standardSizes = [16, 32, 64, 128, 256, 512, 1024]

    /// The icns chunk type that holds each standard size. ImageIO's `com.apple.icns` encoder
    /// writes 16, 32, 128, 256 and 512 (`is32`/`il32` with masks, `ic07`..`ic09`) but drops 64
    /// and 1024, so those two are appended as PNG chunks (`icp6`, `ic10`) after encoding.
    public static let chunkTypes: [Int: String] = [
        16: "is32", 32: "il32", 64: "icp6", 128: "ic07", 256: "ic08", 512: "ic09", 1024: "ic10",
    ]

    private static let appendedPNGSizes: Set = [64, 1024]

    /// Sizes that do not upscale the source: every standard size up to the source's longest
    /// side, or just the smallest one for a tiny source.
    public static func sizes(forLongestSide longestSide: Int) -> [Int] {
        let fitting = standardSizes.filter { $0 <= longestSide }
        return fitting.isEmpty ? [standardSizes[0]] : fitting
    }

    /// The icns data for the first of `iconPath` and `fallbackIconPath` that decodes, or `nil`
    /// when neither does.
    public static func icnsData(iconPath: String?, fallbackIconPath: String) -> Data? {
        for candidatePath in [iconPath, fallbackIconPath].compactMap(\.self) where !candidatePath.isEmpty {
            if let data = FileManager.default.contents(atPath: candidatePath),
               let image = ImageTools.decode(data),
               let icnsData = icnsData(from: image)
            {
                return icnsData
            }
        }
        return nil
    }

    public static func icnsData(from image: CGImage) -> Data? {
        let sizes = sizes(forLongestSide: max(image.width, image.height))
        let encodedSizes = sizes.filter { !appendedPNGSizes.contains($0) }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, "com.apple.icns" as CFString, encodedSizes.count, nil
        )
        else { return nil }
        for size in encodedSizes {
            guard let squareImage = squareImage(from: image, side: size) else { return nil }
            CGImageDestinationAddImage(destination, squareImage, nil)
        }
        guard CGImageDestinationFinalize(destination) else { return nil }

        var chunks = parseChunks(output as Data) ?? []
        guard !chunks.isEmpty else { return output as Data }
        // The table of contents would no longer list every chunk; icns does not require one.
        chunks.removeAll { $0.type == "TOC " }
        for size in sizes where appendedPNGSizes.contains(size) {
            guard let squareImage = squareImage(from: image, side: size),
                  let pngData = ImageTools.png(squareImage),
                  let chunkType = chunkTypes[size]
            else { continue }
            chunks.append((chunkType, pngData))
        }
        return assemble(chunks)
    }

    // MARK: icns container

    /// The `type` / payload pairs of an icns file, or `nil` when it is not a well-formed icns.
    static func parseChunks(_ data: Data) -> [(type: String, payload: Data)]? {
        func bigEndianLength(at offset: Int) -> Int {
            data[data.startIndex + offset ..< data.startIndex + offset + 4].reduce(0) { ($0 << 8) | Int($1) }
        }
        guard data.count >= 8, String(decoding: data.prefix(4), as: UTF8.self) == "icns",
              bigEndianLength(at: 4) == data.count
        else { return nil }
        var chunks: [(type: String, payload: Data)] = []
        var offset = 8
        while offset < data.count {
            guard offset + 8 <= data.count else { return nil }
            let chunkLength = bigEndianLength(at: offset + 4)
            guard chunkLength >= 8, offset + chunkLength <= data.count else { return nil }
            let type = String(decoding: data[data.startIndex + offset ..< data.startIndex + offset + 4], as: UTF8.self)
            let payload = data[data.startIndex + offset + 8 ..< data.startIndex + offset + chunkLength]
            chunks.append((type, Data(payload)))
            offset += chunkLength
        }
        return chunks
    }

    static func assemble(_ chunks: [(type: String, payload: Data)]) -> Data {
        func bigEndianBytes(_ value: Int) -> [UInt8] {
            [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
        }
        let totalLength = 8 + chunks.reduce(0) { $0 + 8 + $1.payload.count }
        var data = Data("icns".utf8)
        data.append(contentsOf: bigEndianBytes(totalLength))
        for chunk in chunks {
            data.append(Data(chunk.type.utf8))
            data.append(contentsOf: bigEndianBytes(8 + chunk.payload.count))
            data.append(chunk.payload)
        }
        return data
    }

    // MARK: Drawing

    /// Scales `image` to fit a transparent `side` x `side` canvas, centred, keeping its aspect ratio.
    static func squareImage(from image: CGImage, side: Int) -> CGImage? {
        guard side > 0,
              let context = CGContext(
                  data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
              )
        else { return nil }
        context.interpolationQuality = .high
        let scale = Double(side) / Double(max(image.width, image.height))
        let drawnWidth = Double(image.width) * scale
        let drawnHeight = Double(image.height) * scale
        context.draw(
            image,
            in: CGRect(
                x: (Double(side) - drawnWidth) / 2, y: (Double(side) - drawnHeight) / 2,
                width: drawnWidth, height: drawnHeight
            )
        )
        return context.makeImage()
    }
}
