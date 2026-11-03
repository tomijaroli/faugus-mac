import AppKit
import FaugusCore
import ImageIO
import SwiftUI

/// Loads and caches downsampled images (icons and covers). Decoding happens off the main
/// thread; the cache key includes the file's modification time so replaced artwork refreshes.
final class ArtworkCache: @unchecked Sendable {
    static let shared = ArtworkCache()
    private let cache = NSCache<NSString, NSImage>()

    private init() { cache.countLimit = 400 }

    static func key(path: String, maxPixel: Int) -> String {
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)?
            .timeIntervalSince1970 ?? 0
        return "\(path)|\(mtime)|\(maxPixel)"
    }

    func cached(path: String, maxPixel: Int) -> NSImage? {
        cache.object(forKey: Self.key(path: path, maxPixel: maxPixel) as NSString)
    }

    func load(path: String, maxPixel: Int) async -> NSImage? {
        let key = Self.key(path: path, maxPixel: maxPixel)
        if let hit = cache.object(forKey: key as NSString) { return hit }
        let image = await Task.detached(priority: .utility) { () -> NSImage? in
            let url = URL(fileURLWithPath: path) as CFURL
            guard let src = CGImageSourceCreateWithURL(url, nil) else { return nil }
            let options: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maxPixel,
            ]
            guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, options as CFDictionary) else { return nil }
            return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
        }.value
        if let image { cache.setObject(image, forKey: key as NSString) }
        return image
    }
}

/// An image file shown at `size`, or `placeholder` while it loads or when it is missing.
struct ArtworkView<Placeholder: View>: View {
    let path: String
    let size: CGSize
    var fill = false
    @ViewBuilder var placeholder: () -> Placeholder

    @State private var image: NSImage?
    @Environment(\.displayScale) private var scale

    private var maxPixel: Int { Int(max(size.width, size.height) * scale) }

    var body: some View {
        Group {
            if let image {
                if fill {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(nsImage: image).resizable().scaledToFit()
                }
            } else {
                placeholder()
            }
        }
        .frame(width: size.width, height: size.height)
        .clipped()
        .task(id: ArtworkCache.key(path: path, maxPixel: maxPixel)) {
            guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { image = nil; return }
            if let hit = ArtworkCache.shared.cached(path: path, maxPixel: maxPixel) { image = hit; return }
            image = await ArtworkCache.shared.load(path: path, maxPixel: maxPixel)
        }
    }
}
