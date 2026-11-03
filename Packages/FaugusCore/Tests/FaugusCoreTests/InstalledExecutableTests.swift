@testable import FaugusCore
import Foundation
import Testing

@Suite("Installed executable detection")
struct InstalledExecutableTests {
    private func le32(_ v: Int) -> [UInt8] {
        (0 ..< 4).map { UInt8((v >> ($0 * 8)) & 0xFF) }
    }

    /// A minimal shell link: header, no ID list, a LinkInfo with a local base path.
    private func link(target: String, unicode: Bool, idList: Bool = false) -> Data {
        var header = [UInt8](repeating: 0, count: 76)
        header[0] = 0x4C
        let flags = 0x02 | (idList ? 0x01 : 0)
        header.replaceSubrange(20 ..< 24, with: le32(flags))
        var out = header
        if idList {
            out += [3, 0, 1, 2, 3]
        } // size 3 + 3 bytes of "item ids"

        let headerSize = unicode ? 0x24 : 0x1C
        let pathBytes: [UInt8] = unicode
            ? Array(target.utf16.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }) + [0, 0]
            : Array(target.utf8) + [0]
        var info: [UInt8] = []
        let size = headerSize + pathBytes.count
        info += le32(size)
        info += le32(headerSize)
        info += le32(1) // VolumeIDAndLocalBasePath
        info += le32(0) // VolumeIDOffset
        info += le32(unicode ? 0 : headerSize) // LocalBasePathOffset
        info += le32(0) + le32(0) // network, suffix
        if unicode {
            info += le32(headerSize) + le32(0)
        } // local base unicode, suffix unicode
        info += pathBytes
        return Data(out + info)
    }

    @Test func parsesAnsiAndUnicodeTargets() {
        #expect(InstalledExecutable.targetPath(inLink: link(target: "C:\\Games\\Foo\\foo.exe", unicode: false))
            == "C:\\Games\\Foo\\foo.exe")
        #expect(InstalledExecutable.targetPath(inLink: link(target: "C:\\Games\\Fóo\\foo.exe", unicode: true))
            == "C:\\Games\\Fóo\\foo.exe")
        #expect(InstalledExecutable.targetPath(inLink: link(target: "C:\\a.exe", unicode: false, idList: true))
            == "C:\\a.exe")
    }

    @Test func rejectsGarbageWithoutCrashing() {
        #expect(InstalledExecutable.targetPath(inLink: Data()) == nil)
        #expect(InstalledExecutable.targetPath(inLink: Data(repeating: 0, count: 200)) == nil)
        let good = link(target: "C:\\Games\\Foo\\foo.exe", unicode: true)
        for cut in stride(from: 0, to: good.count, by: 3) {
            _ = InstalledExecutable.targetPath(inLink: good.prefix(cut))
        }
        var corrupt = good
        for i in 76 ..< corrupt.count where i.isMultiple(of: 5) {
            corrupt[i] = 0xFF
        }
        _ = InstalledExecutable.targetPath(inLink: corrupt)
    }

    @Test func mapsWindowsPaths() throws {
        #expect(InstalledExecutable
            .prefixPath(forWindowsPath: "C:\\Games\\a.exe", prefix: "/p") == "/p/drive_c/Games/a.exe")
        #expect(InstalledExecutable
            .prefixPath(forWindowsPath: "\"c:\\\\x\\y.exe\"", prefix: "/p") == "/p/drive_c/x/y.exe")
        #expect(InstalledExecutable.prefixPath(forWindowsPath: "relative\\a.exe", prefix: "/p") == nil)
        #expect(InstalledExecutable.prefixPath(forWindowsPath: "Q:\\a.exe", prefix: "/nonexistent") == nil)

        let paths = try TestSupport.makeTempHome()
        defer { TestSupport.cleanup(paths) }
        let prefix = paths.home + "/pfx"
        let drive = paths.home + "/Disk"
        try FileManager.default.createDirectory(atPath: prefix + "/dosdevices", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: drive, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: prefix + "/dosdevices/d:", withDestinationPath: drive)
        let mapped = InstalledExecutable.prefixPath(forWindowsPath: "D:\\Games\\a.exe", prefix: prefix)
        #expect(mapped?.hasSuffix("/Disk/Games/a.exe") == true)
    }

    @Test func utilityNamesAreSkipped() {
        #expect(InstalledExecutable.isUtilityShortcut("Uninstall Foo.lnk", "Uninstall Foo"))
        #expect(InstalledExecutable.isUtilityShortcut("Foo Setup"))
        #expect(InstalledExecutable.isUtilityShortcut("README"))
        #expect(!InstalledExecutable.isUtilityShortcut("Foo.lnk", "Foo"))
    }

    @Test func detectsTheNewGameShortcut() throws {
        let paths = try TestSupport.makeTempHome()
        defer { TestSupport.cleanup(paths) }
        let fm = FileManager.default
        let prefix = paths.home + "/pfx"
        let desktop = prefix + "/drive_c/users/crossover/Desktop"
        let menu = prefix + "/drive_c/ProgramData/Microsoft/Windows/Start Menu/Programs/Foo"
        let gameDirectory = prefix + "/drive_c/Program Files/Foo"
        for d in [desktop, menu, gameDirectory] {
            try fm.createDirectory(atPath: d, withIntermediateDirectories: true)
        }
        try Data("MZ".utf8).write(to: URL(fileURLWithPath: gameDirectory + "/Foo.EXE"))
        try Data("MZ".utf8).write(to: URL(fileURLWithPath: gameDirectory + "/unins000.exe"))

        // A shortcut that was already there before the installer ran.
        let old = desktop + "/Old.lnk"
        try link(target: "C:\\Program Files\\Foo\\Foo.exe", unicode: true).write(to: URL(fileURLWithPath: old))
        let before = InstalledExecutable.shortcuts(inPrefix: prefix)
        #expect(before == [old])

        try link(target: "c:\\program files\\foo\\foo.exe", unicode: false)
            .write(to: URL(fileURLWithPath: desktop + "/Foo.lnk"))
        try link(target: "C:\\Program Files\\Foo\\Foo.exe", unicode: true)
            .write(to: URL(fileURLWithPath: menu + "/Foo.lnk"))
        try link(target: "C:\\Program Files\\Foo\\unins000.exe", unicode: true)
            .write(to: URL(fileURLWithPath: menu + "/Uninstall Foo.lnk"))
        try link(target: "C:\\Program Files\\Foo\\missing.exe", unicode: true)
            .write(to: URL(fileURLWithPath: menu + "/Missing.lnk"))
        try Data("not a link".utf8).write(to: URL(fileURLWithPath: menu + "/Broken.lnk"))

        let resolved = InstalledExecutable.resolveNew(
            InstalledExecutable.shortcuts(inPrefix: prefix).subtracting(before), prefix: prefix
        )
        #expect(resolved.count == 1)
        let foo = try #require(resolved.first)
        #expect(foo.name == "Foo")
        #expect(foo.onDesktop && foo.onStartMenu)
        #expect(foo.target.hasSuffix("/Program Files/Foo/Foo.EXE"))
        #expect(InstalledExecutable.detect(prefix: prefix, existing: before)?.hasSuffix("Foo.EXE") == true)
        #expect(InstalledExecutable
            .detect(prefix: prefix, existing: InstalledExecutable.shortcuts(inPrefix: prefix)) == nil)
    }
}
