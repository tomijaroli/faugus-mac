import CoreGraphics
@testable import FaugusCore
import Foundation
import Testing

/// Builds a minimal PE32+ whose only section is `.rsrc` with an icon group, an icon and a
/// version resource, so the parser is tested without shipping a binary.
private enum FakePE {
    static func le16(_ value: Int) -> [UInt8] {
        [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)]
    }

    static func le32(_ value: Int) -> [UInt8] {
        le16(value & 0xFFFF) + le16((value >> 16) & 0xFFFF)
    }

    static func utf16(_ text: String, terminated: Bool = true) -> [UInt8] {
        (Array(text.utf16) + (terminated ? [0] : [])).flatMap { le16(Int($0)) }
    }

    static func pad4(_ bytes: [UInt8]) -> [UInt8] {
        bytes + [UInt8](repeating: 0, count: (4 - bytes.count % 4) % 4)
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
        for child in children {
            body += pad4(child)
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
        let context = CGContext(
            data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: size, height: size))
        return ImageTools.png(context.makeImage()!)!
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
        var resourceSection = [UInt8](repeating: 0, count: dataStart)
        func put(_ offset: Int, _ bytes: [UInt8]) {
            resourceSection.replaceSubrange(offset ..< (offset + bytes.count), with: bytes)
        }
        put(12, le16(0) + le16(blobs.count))
        var cursor = dataStart
        for (index, blob) in blobs.enumerated() {
            let blockStart = blocksStart + index * 64
            put(16 + index * 8, le32(blob.type) + le32(0x8000_0000 | blockStart))
            put(blockStart + 12, le16(0) + le16(1))
            put(blockStart + 16, le32(1) + le32(0x8000_0000 | (blockStart + 24)))
            put(blockStart + 24 + 12, le16(0) + le16(1))
            put(blockStart + 24 + 16, le32(0x409) + le32(blockStart + 48))
            var entry: [UInt8] = le32(0x1000 + cursor)
            entry += le32(blob.bytes.count)
            entry += le32(0)
            entry += le32(0)
            put(blockStart + 48, entry)
            resourceSection += pad4(blob.bytes)
            cursor += pad4(blob.bytes).count
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
        var optionalHeader = [UInt8](repeating: 0, count: 240)
        optionalHeader.replaceSubrange(0 ..< 2, with: le16(0x20B))
        optionalHeader.replaceSubrange((112 + 16) ..< (112 + 24), with: le32(0x1000) + le32(resourceSection.count))
        file += optionalHeader
        var sectionHeader = [UInt8](repeating: 0, count: 40)
        sectionHeader.replaceSubrange(0 ..< 5, with: Array(".rsrc".utf8))
        sectionHeader.replaceSubrange(8 ..< 12, with: le32(resourceSection.count))
        sectionHeader.replaceSubrange(12 ..< 16, with: le32(0x1000))
        sectionHeader.replaceSubrange(16 ..< 20, with: le32(resourceSection.count))
        sectionHeader.replaceSubrange(20 ..< 24, with: le32(0x200))
        file += sectionHeader
        file += [UInt8](repeating: 0, count: 0x200 - file.count)
        file += resourceSection
        return Data(file)
    }
}

@Suite("Executable resources and artwork")
struct ArtworkTests {
    @Test func titlePrefersProductNameThenFileDescription() {
        let both = FakePE.build(strings: [("FileDescription", "Desc"), ("ProductName", "My Game")], icon: nil)
        #expect(PEResources(data: both)?.title() == "My Game")
        let onlyDescription = FakePE.build(
            strings: [("FileDescription", "Just Desc"), ("ProductName", "  ")],
            icon: nil
        )
        #expect(PEResources(data: onlyDescription)?.title() == "Just Desc")
        let none = FakePE.build(strings: [("CompanyName", "Acme")], icon: nil)
        #expect(PEResources(data: none)?.title() == nil)
    }

    @Test func iconIsExtractedAsAnIcoAndScaledTo256() throws {
        let icon = FakePE.pngIcon(size: 32)
        let executable = FakePE.build(strings: [], icon: icon)
        let resources = try #require(PEResources(data: executable))
        let iconFile = try #require(resources.iconFile())
        #expect(Array(iconFile.prefix(4)) == [0, 0, 1, 0])
        #expect(ImageTools.largestFrame(iconFile)?.width == 32)
        let png = try #require(ImageTools.iconPNG(from: iconFile))
        let decoded = try #require(ImageTools.decode(png))
        #expect(decoded.width == 256 && decoded.height == 256)
    }

    @Test func executableWithoutResourcesFallsBackToFileName() throws {
        let directory = NSTemporaryDirectory() + "faugus-art-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
        let path = directory + "/Cool Game.exe"
        try Data("not a pe".utf8).write(to: URL(fileURLWithPath: path))
        let info = GameArtwork.inspect(executable: path)
        #expect(info.title == "Cool Game")
        #expect(info.iconPNG == nil)

        let withInfo = directory + "/x.exe"
        try FakePE.build(strings: [("ProductName", "Real Title")], icon: FakePE.pngIcon(size: 32))
            .write(to: URL(fileURLWithPath: withInfo))
        let real = GameArtwork.inspect(executable: withInfo)
        #expect(real.title == "Real Title")
        #expect(real.iconPNG != nil)
    }

    @Test func truncatedAndGarbageFilesNeverCrash() {
        let executable = FakePE.build(strings: [("ProductName", "T")], icon: FakePE.pngIcon(size: 32))
        for prefixLength in stride(from: 0, to: executable.count, by: 7) {
            let resources = PEResources(data: executable.prefix(prefixLength))
            _ = resources?.title()
            _ = resources?.iconFile()
        }
        var junk = executable
        for byteIndex in stride(from: 0x200, to: junk.count, by: 5) {
            junk[byteIndex] = junk[byteIndex] &+ 0x5B
        }
        let resources = PEResources(data: junk)
        _ = resources?.title()
        _ = resources?.iconFile()
        #expect(PEResources(data: Data(repeating: 0, count: 100)) == nil)
    }

    @Test func coverAndBannerAreResizedAndReplaced() throws {
        let home = NSTemporaryDirectory() + "faugus-art-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let paths = FaugusPaths(home: home)
        let sourcePath = home + "/src.png"
        try FakePE.pngIcon(size: 64).write(to: URL(fileURLWithPath: sourcePath))

        let cover = GameArtwork.saveCover(temporaryPath: sourcePath, gameID: "g", paths: paths)
        #expect(cover == "\(paths.coversDirectory)/g.png")
        let coverData = try #require(FileManager.default.contents(atPath: cover))
        let coverImage = try #require(ImageTools.decode(coverData))
        #expect(coverImage.width == 460 && coverImage.height == 690)

        GameArtwork.saveBanner(temporaryPath: sourcePath, gameID: "g", paths: paths)
        let bannerData = try #require(FileManager.default.contents(atPath: "\(paths.bannersDirectory)/g.png"))
        let bannerImage = try #require(ImageTools.decode(bannerData))
        #expect(bannerImage.width == 1920 && bannerImage.height == 620)

        // No temp: the cover goes away, the banner stays.
        #expect(GameArtwork.saveCover(temporaryPath: nil, gameID: "g", paths: paths) == "")
        #expect(!FileManager.default.fileExists(atPath: cover))
        GameArtwork.saveBanner(temporaryPath: nil, gameID: "g", paths: paths)
        #expect(FileManager.default.fileExists(atPath: "\(paths.bannersDirectory)/g.png"))
    }

    @Test func iconIsInstalledAndRemoved() throws {
        let home = NSTemporaryDirectory() + "faugus-art-\(UUID().uuidString)"
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        let paths = FaugusPaths(home: home)
        let sourcePath = home + "/icon.png"
        try FakePE.pngIcon(size: 256).write(to: URL(fileURLWithPath: sourcePath))
        #expect(GameArtwork
            .saveIcon(temporaryPath: sourcePath, gameID: "g", paths: paths) == "\(paths.iconsDirectory)/g.png")
        // Keeping the same icon when the dialog did not touch it needs the temp copy again.
        #expect(GameArtwork.saveIcon(temporaryPath: nil, gameID: "g", paths: paths) == "")
        #expect(!FileManager.default.fileExists(atPath: "\(paths.iconsDirectory)/g.png"))
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
        let directory = "\(root)/Wine Staging.app/Contents/Resources/wine/lib/wine"
        for architecture in ["x86_64-windows", "i386-windows"] {
            let info = GameArtwork.inspect(executable: "\(directory)/\(architecture)/notepad.exe")
            print("notepad \(architecture): title=\(info.title) icon=\(info.iconPNG?.count ?? 0) bytes")
            #expect(!info.title.isEmpty)
            #expect(info.iconPNG != nil)
        }
    }
}
