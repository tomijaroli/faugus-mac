import CoreGraphics
@testable import FaugusCore
import Foundation
import Testing

/// Builds a minimal PE32+ whose only section is `.rsrc` with an icon group, an icon and a
/// version resource, so the parser is tested without shipping a binary.
private enum FakePE {
    static func le16(_ v: Int) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)]
    }

    static func le32(_ v: Int) -> [UInt8] {
        le16(v & 0xFFFF) + le16((v >> 16) & 0xFFFF)
    }

    static func utf16(_ s: String, terminated: Bool = true) -> [UInt8] {
        (Array(s.utf16) + (terminated ? [0] : [])).flatMap { le16(Int($0)) }
    }

    static func pad4(_ b: [UInt8]) -> [UInt8] {
        b + [UInt8](repeating: 0, count: (4 - b.count % 4) % 4)
    }

    /// `{ len, valLen, type, key, pad, value }` with children appended by the caller.
    static func node(key: String, valueWords: Int, type: Int, value: [UInt8], children: [[UInt8]] = []) -> [UInt8] {
        var header: [UInt8] = le16(0)
        header += le16(valueWords)
        header += le16(type)
        header += utf16(key)
        var body = pad4(header)
        body += value
        body = pad4(body)
        for c in children {
            body += pad4(c)
        }
        var out = body
        out.replaceSubrange(0 ..< 2, with: le16(body.count))
        return out
    }

    static func versionBlob(strings: [(String, String)]) -> [UInt8] {
        let entries = strings.map { node(key: $0.0, valueWords: $0.1.utf16.count + 1, type: 1, value: utf16($0.1)) }
        let table = node(key: "040904b0", valueWords: 0, type: 1, value: [], children: entries)
        let info = node(key: "StringFileInfo", valueWords: 0, type: 1, value: [], children: [table])
        return node(
            key: "VS_VERSION_INFO",
            valueWords: 52,
            type: 0,
            value: [UInt8](repeating: 0, count: 52),
            children: [info]
        )
    }

    static func pngIcon(size: Int) -> Data {
        let ctx = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return ImageTools.png(ctx.makeImage()!)!
    }

    static func build(strings: [(String, String)], icon: Data?) -> Data {
        var blobs: [(type: Int, bytes: [UInt8])] = []
        if let icon {
            blobs.append((3, [UInt8](icon)))
            var group: [UInt8] = []
            group += le16(0)
            group += le16(1)
            group += le16(1)
            group += [32, 32, 0, 0]
            group += le16(1)
            group += le16(32)
            group += le32(icon.count)
            group += le16(1)
            blobs.append((14, group))
        }
        if !strings.isEmpty {
            blobs.append((16, versionBlob(strings: strings)))
        }
        blobs.sort { $0.type < $1.type }

        let rootSize = 16 + blobs.count * 8
        let blocksStart = rootSize
        var dataStart = blocksStart + blobs.count * 64
        dataStart = (dataStart + 7) & ~7
        var rsrc = [UInt8](repeating: 0, count: dataStart)
        func put(_ at: Int, _ bytes: [UInt8]) {
            rsrc.replaceSubrange(at ..< (at + bytes.count), with: bytes)
        }
        put(12, le16(0) + le16(blobs.count))
        var cursor = dataStart
        for (i, b) in blobs.enumerated() {
            let s = blocksStart + i * 64
            put(16 + i * 8, le32(b.type) + le32(0x8000_0000 | s))
            put(s + 12, le16(0) + le16(1))
            put(s + 16, le32(1) + le32(0x8000_0000 | (s + 24)))
            put(s + 24 + 12, le16(0) + le16(1))
            put(s + 24 + 16, le32(0x409) + le32(s + 48))
            var entry: [UInt8] = le32(0x1000 + cursor)
            entry += le32(b.bytes.count)
            entry += le32(0)
            entry += le32(0)
            put(s + 48, entry)
            rsrc += pad4(b.bytes)
            cursor += pad4(b.bytes).count
        }

        var file = [UInt8](repeating: 0, count: 0x40)
        file[0] = 0x4D
        file[1] = 0x5A
        file.replaceSubrange(0x3C ..< 0x40, with: le32(0x40))
        file += [0x50, 0x45, 0, 0]
        file += le16(0x8664)
        file += le16(1)
        file += le32(0)
        file += le32(0)
        file += le32(0)
        file += le16(240)
        file += le16(0x22)
        var opt = [UInt8](repeating: 0, count: 240)
        opt.replaceSubrange(0 ..< 2, with: le16(0x20B))
        opt.replaceSubrange((112 + 16) ..< (112 + 24), with: le32(0x1000) + le32(rsrc.count))
        file += opt
        var sec = [UInt8](repeating: 0, count: 40)
        sec.replaceSubrange(0 ..< 5, with: Array(".rsrc".utf8))
        sec.replaceSubrange(8 ..< 12, with: le32(rsrc.count))
        sec.replaceSubrange(12 ..< 16, with: le32(0x1000))
        sec.replaceSubrange(16 ..< 20, with: le32(rsrc.count))
        sec.replaceSubrange(20 ..< 24, with: le32(0x200))
        file += sec
        file += [UInt8](repeating: 0, count: 0x200 - file.count)
        file += rsrc
        return Data(file)
    }
}

@Suite("Executable resources and artwork")
struct ArtworkTests {
    @Test func titlePrefersProductNameThenFileDescription() {
        let both = FakePE.build(strings: [("FileDescription", "Desc"), ("ProductName", "My Game")], icon: nil)
        #expect(PEResources(data: both)?.title() == "My Game")
        let onlyDesc = FakePE.build(strings: [("FileDescription", "Just Desc"), ("ProductName", "  ")], icon: nil)
        #expect(PEResources(data: onlyDesc)?.title() == "Just Desc")
        let none = FakePE.build(strings: [("CompanyName", "Acme")], icon: nil)
        #expect(PEResources(data: none)?.title() == nil)
    }

    @Test func iconIsExtractedAsAnIcoAndScaledTo256() throws {
        let icon = FakePE.pngIcon(size: 32)
        let exe = FakePE.build(strings: [], icon: icon)
        let pe = try #require(PEResources(data: exe))
        let ico = try #require(pe.iconFile())
        #expect(Array(ico.prefix(4)) == [0, 0, 1, 0])
        #expect(ImageTools.largestFrame(ico)?.width == 32)
        let png = try #require(ImageTools.iconPNG(from: ico))
        let decoded = try #require(ImageTools.decode(png))
        #expect(decoded.width == 256 && decoded.height == 256)
    }

    @Test func executableWithoutResourcesFallsBackToFileName() throws {
        let dir = NSTemporaryDirectory() + "faugus-art-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        let path = dir + "/Cool Game.exe"
        try Data("not a pe".utf8).write(to: URL(fileURLWithPath: path))
        let info = GameArtwork.inspect(executable: path)
        #expect(info.title == "Cool Game")
        #expect(info.iconPNG == nil)

        let withInfo = dir + "/x.exe"
        try FakePE.build(strings: [("ProductName", "Real Title")], icon: FakePE.pngIcon(size: 32))
            .write(to: URL(fileURLWithPath: withInfo))
        let real = GameArtwork.inspect(executable: withInfo)
        #expect(real.title == "Real Title")
        #expect(real.iconPNG != nil)
    }

    @Test func truncatedAndGarbageFilesNeverCrash() {
        let exe = FakePE.build(strings: [("ProductName", "T")], icon: FakePE.pngIcon(size: 32))
        for n in stride(from: 0, to: exe.count, by: 7) {
            let pe = PEResources(data: exe.prefix(n))
            _ = pe?.title()
            _ = pe?.iconFile()
        }
        var junk = exe
        for i in stride(from: 0x200, to: junk.count, by: 5) {
            junk[i] = junk[i] &+ 0x5B
        }
        let pe = PEResources(data: junk)
        _ = pe?.title()
        _ = pe?.iconFile()
        #expect(PEResources(data: Data(repeating: 0, count: 100)) == nil)
    }

    @Test func coverAndBannerAreResizedAndReplaced() throws {
        let home = NSTemporaryDirectory() + "faugus-art-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let paths = FaugusPaths(home: home)
        let src = home + "/src.png"
        try FakePE.pngIcon(size: 64).write(to: URL(fileURLWithPath: src))

        let cover = GameArtwork.saveCover(temp: src, gameID: "g", paths: paths)
        #expect(cover == "\(paths.coversDir)/g.png")
        let cData = try #require(FileManager.default.contents(atPath: cover))
        let c = try #require(ImageTools.decode(cData))
        #expect(c.width == 460 && c.height == 690)

        GameArtwork.saveBanner(temp: src, gameID: "g", paths: paths)
        let bData = try #require(FileManager.default.contents(atPath: "\(paths.bannersDir)/g.png"))
        let b = try #require(ImageTools.decode(bData))
        #expect(b.width == 1920 && b.height == 620)

        // No temp: the cover goes away, the banner stays.
        #expect(GameArtwork.saveCover(temp: nil, gameID: "g", paths: paths) == "")
        #expect(!FileManager.default.fileExists(atPath: cover))
        GameArtwork.saveBanner(temp: nil, gameID: "g", paths: paths)
        #expect(FileManager.default.fileExists(atPath: "\(paths.bannersDir)/g.png"))
    }

    @Test func iconIsInstalledAndRemoved() throws {
        let home = NSTemporaryDirectory() + "faugus-art-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let paths = FaugusPaths(home: home)
        let src = home + "/icon.png"
        try FakePE.pngIcon(size: 256).write(to: URL(fileURLWithPath: src))
        #expect(GameArtwork.saveIcon(temp: src, gameID: "g", paths: paths) == "\(paths.iconsDir)/g.png")
        // Keeping the same icon when the dialog did not touch it needs the temp copy again.
        #expect(GameArtwork.saveIcon(temp: nil, gameID: "g", paths: paths) == "")
        #expect(!FileManager.default.fileExists(atPath: "\(paths.iconsDir)/g.png"))
    }

    @Test func urlValidationMatchesUpstreamRules() {
        #expect(GameArtwork.validatedImageURL("https://example.com/a b.png")?
            .absoluteString == "https://example.com/a%20b.png")
        #expect(GameArtwork.validatedImageURL("ftp://example.com/a.png") == nil)
        #expect(GameArtwork.validatedImageURL("https://example.com/a.txt") == nil)
        #expect(GameArtwork.validatedImageURL("file:///etc/passwd.png") == nil)
        #expect(GameArtwork.validatedImageURL("not a url") == nil)
    }

    @Test func invalidImagesAreRejected() {
        #expect(!ImageTools.isValid(Data()))
        #expect(!ImageTools.isValid(Data("hello".utf8)))
        #expect(ImageTools.isValid(FakePE.pngIcon(size: 8)))
    }
}

/// Opt-in: runs the parser on the PE files that ship inside a Wine runner
/// (`FAUGUS_REAL_WINE_RUNNER=/tmp/gcenx/runner`).
@Suite("Real PE files", .enabled(if: ProcessInfo.processInfo.environment["FAUGUS_REAL_WINE_RUNNER"] != nil))
struct RealPETests {
    @Test func wineNotepadHasTitleAndIcon() {
        let root = ProcessInfo.processInfo.environment["FAUGUS_REAL_WINE_RUNNER"] ?? ""
        let dir = "\(root)/Wine Staging.app/Contents/Resources/wine/lib/wine"
        for arch in ["x86_64-windows", "i386-windows"] {
            let info = GameArtwork.inspect(executable: "\(dir)/\(arch)/notepad.exe")
            print("notepad \(arch): title=\(info.title) icon=\(info.iconPNG?.count ?? 0) bytes")
            #expect(!info.title.isEmpty)
            #expect(info.iconPNG != nil)
        }
    }
}
