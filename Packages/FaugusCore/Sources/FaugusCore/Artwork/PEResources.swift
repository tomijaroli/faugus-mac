import Foundation

/// A small read-only parser for the resources of a Windows executable: the title from the
/// version info (`extract_exe_title`, pefile) and the main icon (`extract_ico`, icoextract).
/// It never executes or modifies the file, and every offset is bounds-checked.
public struct PEResources {
    private let data: Data
    private var sections: [(virtualAddress: UInt32, virtualSize: UInt32, rawOffset: UInt32, rawSize: UInt32)] = []
    private var resourceRelativeVirtualAddress: UInt32 = 0
    private var resourceSize: UInt32 = 0

    /// Reads at most 256 MiB of the file's head; resources live in the first sections.
    public init?(path: String) {
        guard let fileHandle = FileHandle(forReadingAtPath: path) else { return nil }
        defer { try? fileHandle.close() }
        guard let fileData = try? fileHandle.read(upToCount: 256 * 1024 * 1024), fileData.count > 0x40 else {
            return nil
        }
        self.init(data: fileData)
    }

    public init?(data: Data) {
        self.data = data
        guard data.count > 0x40, readUInt16(at: 0) == 0x5A4D else { return nil }
        let peHeaderOffset = Int(readUInt32(at: 0x3C))
        guard peHeaderOffset > 0, peHeaderOffset + 24 < data.count, readUInt32(at: peHeaderOffset) == 0x0000_4550 else {
            return nil
        }
        let sectionCount = Int(readUInt16(at: peHeaderOffset + 6))
        let optionalHeaderSize = Int(readUInt16(at: peHeaderOffset + 20))
        let optionalHeaderOffset = peHeaderOffset + 24
        guard optionalHeaderOffset + optionalHeaderSize <= data.count, sectionCount <= 96 else { return nil }
        let magic = readUInt16(at: optionalHeaderOffset)
        let dataDirectoryBase: Int
        switch magic {
        case 0x10B: dataDirectoryBase = optionalHeaderOffset + 96
        case 0x20B: dataDirectoryBase = optionalHeaderOffset + 112
        default: return nil
        }
        // Data directory 2 is the resource table.
        let entry = dataDirectoryBase + 2 * 8
        guard entry + 8 <= data.count, entry + 8 <= optionalHeaderOffset + optionalHeaderSize else { return nil }
        resourceRelativeVirtualAddress = readUInt32(at: entry)
        resourceSize = readUInt32(at: entry + 4)
        var sectionOffset = optionalHeaderOffset + optionalHeaderSize
        for _ in 0 ..< sectionCount {
            guard sectionOffset + 40 <= data.count else { return nil }
            sections.append((
                readUInt32(at: sectionOffset + 12),
                readUInt32(at: sectionOffset + 8),
                readUInt32(at: sectionOffset + 20),
                readUInt32(at: sectionOffset + 16)
            ))
            sectionOffset += 40
        }
        guard resourceRelativeVirtualAddress != 0, resourceSize != 0 else { return nil }
    }

    // MARK: Bounds-checked reads

    private func readUInt16(at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        return UInt16(data[data.startIndex + offset]) | UInt16(data[data.startIndex + offset + 1]) << 8
    }

    private func readUInt32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return UInt32(readUInt16(at: offset)) | UInt32(readUInt16(at: offset + 2)) << 16
    }

    private func fileOffset(forRelativeVirtualAddress relativeVirtualAddress: UInt32) -> Int? {
        for section in sections
            where relativeVirtualAddress >= section.virtualAddress
            && relativeVirtualAddress < section.virtualAddress &+ max(section.virtualSize, section.rawSize)
        {
            let offset = Int(section.rawOffset) + Int(relativeVirtualAddress - section.virtualAddress)
            return offset < data.count ? offset : nil
        }
        return nil
    }

    // MARK: Resource tree

    private struct Node {
        var id: UInt32?
        var isDirectory: Bool
        var offset: Int // relative to the resource section start
    }

    private var resourceStart: Int? {
        fileOffset(forRelativeVirtualAddress: resourceRelativeVirtualAddress)
    }

    private func entries(at relative: Int) -> [Node] {
        guard let base = resourceStart, relative >= 0, base + relative + 16 <= data.count else { return [] }
        let namedEntryCount = Int(readUInt16(at: base + relative + 12))
        let idEntryCount = Int(readUInt16(at: base + relative + 14))
        let total = min(namedEntryCount + idEntryCount, 2048)
        var nodes: [Node] = []
        for entryIndex in 0 ..< total {
            let entryOffset = base + relative + 16 + entryIndex * 8
            guard entryOffset + 8 <= data.count else { break }
            let nameField = readUInt32(at: entryOffset)
            let offsetField = readUInt32(at: entryOffset + 4)
            let isNamed = nameField & 0x8000_0000 != 0
            nodes.append(Node(
                id: isNamed ? nil : nameField,
                isDirectory: offsetField & 0x8000_0000 != 0,
                offset: Int(offsetField & 0x7FFF_FFFF)
            ))
        }
        return nodes
    }

    /// The bytes of a leaf under `directory`, descending to the first entry at each level.
    private func firstLeaf(of node: Node) -> Data? {
        var current = node
        var depth = 0
        while current.isDirectory, depth < 4 {
            guard let first = entries(at: current.offset).first else { return nil }
            current = first
            depth += 1
        }
        guard !current.isDirectory, let base = resourceStart, base + current.offset + 16 <= data.count else {
            return nil
        }
        let relativeVirtualAddress = readUInt32(at: base + current.offset)
        let size = Int(readUInt32(at: base + current.offset + 4))
        guard size > 0, size < 64 * 1024 * 1024,
              let dataOffset = fileOffset(forRelativeVirtualAddress: relativeVirtualAddress),
              dataOffset + size <= data.count
        else { return nil }
        return data.subdata(in: (data.startIndex + dataOffset) ..< (data.startIndex + dataOffset + size))
    }

    private func resources(ofType type: UInt32) -> [Node] {
        guard let typeDirectory = entries(at: 0).first(where: { $0.id == type && $0.isDirectory }) else { return [] }
        return entries(at: typeDirectory.offset)
    }

    // MARK: Version info (`extract_exe_title`)

    /// `ProductName`, else `FileDescription`, from the first string table that has either.
    public func title() -> String? {
        for resource in resources(ofType: 16) {
            guard let blob = firstLeaf(of: resource) else { continue }
            for table in Self.versionStringTables(blob) {
                for key in ["ProductName", "FileDescription"] {
                    let trimmed = (table[key] ?? "")
                        .trimmingCharacters(in: CharacterSet(charactersIn: "\0").union(.whitespacesAndNewlines))
                    if !trimmed.isEmpty {
                        return trimmed
                    }
                }
            }
        }
        return nil
    }

    /// Walks `VS_VERSIONINFO` and returns the `StringFileInfo` tables.
    static func versionStringTables(_ blob: Data) -> [[String: String]] {
        func readUInt16(at offset: Int) -> Int {
            offset >= 0 && offset + 2 <= blob
                .count ? Int(blob[blob.startIndex + offset]) | Int(blob[blob.startIndex + offset + 1]) << 8 : 0
        }
        func key(at offset: Int) -> (String, Int) {
            var units: [UInt16] = []
            var position = offset
            while position + 2 <= blob.count {
                let unit = UInt16(readUInt16(at: position))
                position += 2
                if unit == 0 {
                    break
                }
                units.append(unit)
                if units.count > 256 {
                    break
                }
            }
            return (String(decoding: units, as: UTF16.self), position)
        }
        func align(_ x: Int) -> Int {
            (x + 3) & ~3
        }

        var tables: [[String: String]] = []
        // Root: VS_VERSIONINFO { length, valueLength, type, "VS_VERSION_INFO", pad, VS_FIXEDFILEINFO, pad, children }
        let rootLength = min(readUInt16(at: 0), blob.count)
        guard rootLength >= 6 else { return tables }
        let (_, afterKey) = key(at: 6)
        var childOffset = align(align(afterKey) + readUInt16(at: 2))
        while childOffset + 6 <= rootLength {
            let length = readUInt16(at: childOffset)
            guard length >= 6, childOffset + length <= blob.count else { break }
            let (name, afterName) = key(at: childOffset + 6)
            if name == "StringFileInfo" {
                var tableOffset = align(afterName)
                let infoEnd = childOffset + length
                while tableOffset + 6 <= infoEnd {
                    let tableLength = readUInt16(at: tableOffset)
                    guard tableLength >= 6, tableOffset + tableLength <= blob.count else { break }
                    let (_, afterTable) = key(at: tableOffset + 6)
                    var stringOffset = align(afterTable)
                    let tableEnd = min(tableOffset + tableLength, infoEnd)
                    var table: [String: String] = [:]
                    while stringOffset + 6 <= tableEnd {
                        let stringLength = readUInt16(at: stringOffset)
                        let valueLength = readUInt16(at: stringOffset + 2)
                        guard stringLength >= 6, stringOffset + stringLength <= blob.count else { break }
                        let (stringKey, afterStringKey) = key(at: stringOffset + 6)
                        let valueStart = align(afterStringKey)
                        let valueByteCount = max(0, min(valueLength * 2, stringOffset + stringLength - valueStart))
                        var units: [UInt16] = []
                        var valuePosition = valueStart
                        while valuePosition + 2 <= valueStart + valueByteCount {
                            units.append(UInt16(readUInt16(at: valuePosition)))
                            valuePosition += 2
                        }
                        table[stringKey] = String(decoding: units, as: UTF16.self)
                        stringOffset = align(stringOffset + stringLength)
                    }
                    tables.append(table)
                    tableOffset = align(tableOffset + tableLength)
                }
            }
            childOffset = align(childOffset + length)
        }
        return tables
    }

    // MARK: Icons (`extract_ico`)

    /// An `.ico` file built from the first icon group (what icoextract writes), or `nil` when
    /// the executable has no icons.
    public func iconFile() -> Data? {
        let icons = Dictionary(
            resources(ofType: 3).compactMap { node in node.id.map { ($0, node) } },
            uniquingKeysWith: { first, _ in first }
        )
        for group in resources(ofType: 14) {
            guard let groupDirectory = firstLeaf(of: group), groupDirectory.count >= 6 else { continue }
            func readGroupUInt16(at byteOffset: Int) -> Int {
                byteOffset + 2 <= groupDirectory
                    .count ? Int(groupDirectory[groupDirectory.startIndex + byteOffset])
                    | Int(groupDirectory[groupDirectory.startIndex + byteOffset + 1]) << 8 : 0
            }
            let count = min(readGroupUInt16(at: 4), 64)
            var frames: [(entry: [UInt8], payload: Data)] = []
            for entryIndex in 0 ..< count {
                let entryOffset = 6 + entryIndex * 14
                guard entryOffset + 14 <= groupDirectory.count else { break }
                let id = UInt32(readGroupUInt16(at: entryOffset + 12))
                guard let node = icons[id], let payload = firstLeaf(of: node) else { continue }
                frames.append((
                    Array(groupDirectory[
                        (groupDirectory.startIndex + entryOffset) ..< (groupDirectory.startIndex + entryOffset + 12)
                    ]),
                    payload
                ))
            }
            guard !frames.isEmpty else { continue }
            var iconData = Data([0, 0, 1, 0, UInt8(frames.count & 0xFF), UInt8(frames.count >> 8)])
            var payloadOffset = 6 + frames.count * 16
            for frame in frames {
                iconData.append(contentsOf: frame.entry) // width, height, colors, reserved, planes, bits, size
                // The group entry already holds the payload size at bytes 8..<12; trust the real size.
                let size = UInt32(frame.payload.count)
                iconData.replaceSubrange(
                    (iconData.count - 4) ..< iconData.count,
                    with: withUnsafeBytes(of: size.littleEndian) { Array($0) }
                )
                iconData.append(contentsOf: withUnsafeBytes(of: UInt32(payloadOffset).littleEndian) { Array($0) })
                payloadOffset += frame.payload.count
            }
            for frame in frames {
                iconData.append(frame.payload)
            }
            return iconData
        }
        return nil
    }
}
