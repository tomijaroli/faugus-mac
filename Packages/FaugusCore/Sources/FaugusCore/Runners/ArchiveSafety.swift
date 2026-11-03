import Foundation

/// Archive hardening for downloaded runners and components: reject absolute paths, `..`
/// components and symlinks that point outside the extraction root.
public enum ArchiveSafety {
    /// Validates the member names printed by `tar -tf`.
    public static func validate(memberNames: [String]) throws {
        for raw in memberNames {
            let name = raw.trimmingCharacters(in: .newlines)
            if name.isEmpty {
                continue
            }
            if name.hasPrefix("/") || name.hasPrefix("~") {
                throw RunnerError.unsafeArchive(name)
            }
            if name.split(separator: "/", omittingEmptySubsequences: true).contains("..") {
                throw RunnerError.unsafeArchive(name)
            }
            if name.contains("\0") {
                throw RunnerError.unsafeArchive(name)
            }
        }
    }

    /// Walks an extracted tree and rejects symlinks whose target resolves outside `root`
    /// (absolute targets are rejected too).
    public static func validateTree(root: String) throws {
        let fm = FileManager.default
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL
        guard let walker = fm.enumerator(atPath: root) else { return }
        for case let rel as String in walker {
            let full = root + "/" + rel
            guard let dest = try? fm.destinationOfSymbolicLink(atPath: full) else { continue }
            if dest.hasPrefix("/") {
                throw RunnerError.unsafeArchive("\(rel) -> \(dest)")
            }
            let parent = URL(fileURLWithPath: full).deletingLastPathComponent()
            let resolved = URL(fileURLWithPath: dest, relativeTo: parent).standardizedFileURL
            if !isInside(resolved.path, root: rootURL.path) {
                throw RunnerError.unsafeArchive("\(rel) -> \(dest)")
            }
        }
    }

    static func isInside(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
