import Foundation

/// A small read-only parser for the resources of a Windows executable: the title from the
/// version info (`extract_exe_title`, pefile) and the main icon (`extract_ico`, icoextract).
/// It never executes or modifies the file, and every offset is bounds-checked.
public struct PEResources {
    private let data: Data
    private var sections: [(va: UInt32, vsize: UInt32, raw: UInt32, rawSize: UInt32)] = []
    private var rsrcRVA: UInt32 = 0
    private var rsrcSize: UInt32 = 0

    /// Reads at most 256 MiB of the file's head; resources live in the first sections.
    public init?(path: String) {
        guard let h = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: 256 * 1024 * 1024), d.count > 0x40 else { return nil }
        self.init(data: d)
    }

    public init?(data: Data) {
        self.data = data
        guard data.count > 0x40, u16(0) == 0x5A4D else { return nil }
        let pe = Int(u32(0x3C))
        guard pe > 0, pe + 24 < data.count, u32(pe) == 0x0000_4550 else { return nil }
        let sectionCount = Int(u16(pe + 6))
        let optSize = Int(u16(pe + 20))
        let opt = pe + 24
        guard opt + optSize <= data.count, sectionCount <= 96 else { return nil }
        let magic = u16(opt)
        let dirBase: Int
        switch magic {
        case 0x10B: dirBase = opt + 96
        case 0x20B: dirBase = opt + 112
        default: return nil
        }
        // Data directory 2 is the resource table.
        let entry = dirBase + 2 * 8
        guard entry + 8 <= data.count, entry + 8 <= opt + optSize else { return nil }
        rsrcRVA = u32(entry)
        rsrcSize = u32(entry + 4)
        var s = opt + optSize
        for _ in 0..<sectionCount {
            guard s + 40 <= data.count else { return nil }
            sections.append((u32(s + 12), u32(s + 8), u32(s + 20), u32(s + 16)))
            s += 40
        }
        guard rsrcRVA != 0, rsrcSize != 0 else { return nil }
    }

    // MARK: Bounds-checked reads

    private func u16(_ o: Int) -> UInt16 {
        guard o >= 0, o + 2 <= data.count else { return 0 }
        return UInt16(data[data.startIndex + o]) | UInt16(data[data.startIndex + o + 1]) << 8
    }

    private func u32(_ o: Int) -> UInt32 {
        guard o >= 0, o + 4 <= data.count else { return 0 }
        return UInt32(u16(o)) | UInt32(u16(o + 2)) << 16
    }

    private func offset(forRVA rva: UInt32) -> Int? {
        for s in sections where rva >= s.va && rva < s.va &+ max(s.vsize, s.rawSize) {
            let o = Int(s.raw) + Int(rva - s.va)
            return o < data.count ? o : nil
        }
        return nil
    }

    // MARK: Resource tree

    private struct Node {
        var id: UInt32?
        var isDirectory: Bool
        var offset: Int  // relative to the resource section start
    }

    private var rsrcStart: Int? { offset(forRVA: rsrcRVA) }

    private func entries(at relative: Int) -> [Node] {
        guard let base = rsrcStart, relative >= 0, base + relative + 16 <= data.count else { return [] }
        let named = Int(u16(base + relative + 12))
        let ids = Int(u16(base + relative + 14))
        let total = min(named + ids, 2048)
        var out: [Node] = []
        for i in 0..<total {
            let e = base + relative + 16 + i * 8
            guard e + 8 <= data.count else { break }
            let name = u32(e)
            let off = u32(e + 4)
            let isNamed = name & 0x8000_0000 != 0
            out.append(Node(
                id: isNamed ? nil : name, isDirectory: off & 0x8000_0000 != 0, offset: Int(off & 0x7FFF_FFFF)))
        }
        return out
    }

    /// The bytes of a leaf under `directory`, descending to the first entry at each level.
    private func firstLeaf(of node: Node) -> Data? {
        var n = node
        var depth = 0
        while n.isDirectory, depth < 4 {
            guard let first = entries(at: n.offset).first else { return nil }
            n = first
            depth += 1
        }
        guard !n.isDirectory, let base = rsrcStart, base + n.offset + 16 <= data.count else { return nil }
        let rva = u32(base + n.offset)
        let size = Int(u32(base + n.offset + 4))
        guard size > 0, size < 64 * 1024 * 1024, let o = offset(forRVA: rva), o + size <= data.count else { return nil }
        return data.subdata(in: (data.startIndex + o)..<(data.startIndex + o + size))
    }

    private func resources(ofType type: UInt32) -> [Node] {
        guard let t = entries(at: 0).first(where: { $0.id == type && $0.isDirectory }) else { return [] }
        return entries(at: t.offset)
    }

    // MARK: Version info (`extract_exe_title`)

    /// `ProductName`, else `FileDescription`, from the first string table that has either.
    public func title() -> String? {
        for res in resources(ofType: 16) {
            guard let blob = firstLeaf(of: res) else { continue }
            for table in Self.versionStringTables(blob) {
                for key in ["ProductName", "FileDescription"] {
                    let trimmed = (table[key] ?? "")
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines))
                    if !trimmed.isEmpty { return trimmed }
                }
            }
        }
        return nil
    }

    /// Walks `VS_VERSIONINFO` and returns the `StringFileInfo` tables.
    static func versionStringTables(_ blob: Data) -> [[String: String]] {
        func rd16(_ o: Int) -> Int { o >= 0 && o + 2 <= blob.count ? Int(blob[blob.startIndex + o]) | Int(blob[blob.startIndex + o + 1]) << 8 : 0 }
        func key(at o: Int) -> (String, Int) {
            var units: [UInt16] = []
            var p = o
            while p + 2 <= blob.count {
                let c = UInt16(rd16(p))
                p += 2
                if c == 0 { break }
                units.append(c)
                if units.count > 256 { break }
            }
            return (String(decoding: units, as: UTF16.self), p)
        }
        func align(_ x: Int) -> Int { (x + 3) & ~3 }

        var tables: [[String: String]] = []
        // Root: VS_VERSIONINFO { len, valLen, type, "VS_VERSION_INFO", pad, VS_FIXEDFILEINFO, pad, children }
        let rootLen = min(rd16(0), blob.count)
        guard rootLen >= 6 else { return tables }
        let (_, afterKey) = key(at: 6)
        var p = align(align(afterKey) + rd16(2))
        while p + 6 <= rootLen {
            let len = rd16(p)
            guard len >= 6, p + len <= blob.count else { break }
            let (name, afterName) = key(at: p + 6)
            if name == "StringFileInfo" {
                var t = align(afterName)
                let infoEnd = p + len
                while t + 6 <= infoEnd {
                    let tLen = rd16(t)
                    guard tLen >= 6, t + tLen <= blob.count else { break }
                    let (_, afterTable) = key(at: t + 6)
                    var s = align(afterTable)
                    let tEnd = min(t + tLen, infoEnd)
                    var table: [String: String] = [:]
                    while s + 6 <= tEnd {
                        let sLen = rd16(s)
                        let valLen = rd16(s + 2)
                        guard sLen >= 6, s + sLen <= blob.count else { break }
                        let (k, afterK) = key(at: s + 6)
                        let vStart = align(afterK)
                        let vBytes = max(0, min(valLen * 2, s + sLen - vStart))
                        var units: [UInt16] = []
                        var q = vStart
                        while q + 2 <= vStart + vBytes { units.append(UInt16(rd16(q))); q += 2 }
                        table[k] = String(decoding: units, as: UTF16.self)
                        s = align(s + sLen)
                    }
                    tables.append(table)
                    t = align(t + tLen)
                }
            }
            p = align(p + len)
        }
        return tables
    }

    // MARK: Icons (`extract_ico`)

    /// An `.ico` file built from the first icon group (what icoextract writes), or `nil` when
    /// the executable has no icons.
    public func iconFile() -> Data? {
        let icons = Dictionary(
            resources(ofType: 3).compactMap { n in n.id.map { ($0, n) } }, uniquingKeysWith: { a, _ in a })
        for group in resources(ofType: 14) {
            guard let dir = firstLeaf(of: group), dir.count >= 6 else { continue }
            func g16(_ o: Int) -> Int { o + 2 <= dir.count ? Int(dir[dir.startIndex + o]) | Int(dir[dir.startIndex + o + 1]) << 8 : 0 }
            let count = min(g16(4), 64)
            var frames: [(entry: [UInt8], payload: Data)] = []
            for i in 0..<count {
                let e = 6 + i * 14
                guard e + 14 <= dir.count else { break }
                let id = UInt32(g16(e + 12))
                guard let node = icons[id], let payload = firstLeaf(of: node) else { continue }
                frames.append((Array(dir[(dir.startIndex + e)..<(dir.startIndex + e + 12)]), payload))
            }
            guard !frames.isEmpty else { continue }
            var ico = Data([0, 0, 1, 0, UInt8(frames.count & 0xFF), UInt8(frames.count >> 8)])
            var offset = 6 + frames.count * 16
            for f in frames {
                ico.append(contentsOf: f.entry)  // width, height, colors, reserved, planes, bits, size
                // The group entry already holds the payload size at bytes 8..<12; trust the real size.
                let size = UInt32(f.payload.count)
                ico.replaceSubrange((ico.count - 4)..<ico.count, with: withUnsafeBytes(of: size.littleEndian) { Array($0) })
                ico.append(contentsOf: withUnsafeBytes(of: UInt32(offset).littleEndian) { Array($0) })
                offset += f.payload.count
            }
            for f in frames { ico.append(f.payload) }
            return ico
        }
        return nil
    }
}
