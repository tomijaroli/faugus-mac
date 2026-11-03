import Foundation

public enum JSONFileError: Error {
    /// The file exists but is unreadable or invalid. Callers that would overwrite the file
    /// must refuse (upstream `load_json_file_or_none`: "refusing to touch ...").
    case unreadable(path: String, underlying: String)
}

/// Port of `faugus.core.atomic_write`, `load_json_file`, `save_json_file`,
/// `load_json_file_or_none`.
public enum JSONFile {
    /// Creates parent directories, writes to a `.tmp-*` sibling, then renames over the target.
    public static func atomicWrite(_ data: Data, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let temporaryURL = directory.appendingPathComponent(".tmp-" + UUID().uuidString.lowercased())
        do {
            try data.write(to: temporaryURL, options: [])
            // rename(2) replaces atomically on the same volume.
            if rename(temporaryURL.path, url.path) != 0 {
                let code = errno
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
            }
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    public static func save(_ value: JSONValue, to path: String, indent: Int = 4) throws {
        try atomicWrite(JSONWriter.serialize(value, indent: indent), to: path)
    }

    /// `load_json_file(path, default)`: missing or invalid file yields `default`.
    public static func load(_ path: String, default fallback: JSONValue = .array([])) -> JSONValue {
        guard let data = FileManager.default.contents(atPath: path),
              let value = try? JSONParser.parse(data)
        else { return fallback }
        return value
    }

    /// `load_json_file_or_none`: missing file is `[]`, invalid file throws.
    public static func loadOrThrow(_ path: String) throws -> JSONValue {
        guard FileManager.default.fileExists(atPath: path) else { return .array([]) }
        do {
            guard let data = FileManager.default.contents(atPath: path) else {
                throw JSONFileError.unreadable(path: path, underlying: "cannot read file")
            }
            return try JSONParser.parse(data)
        } catch let fileError as JSONFileError {
            throw fileError
        } catch {
            throw JSONFileError.unreadable(path: path, underlying: "\(error)")
        }
    }
}
