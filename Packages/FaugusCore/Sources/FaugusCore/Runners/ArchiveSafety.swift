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
        let fileManager = FileManager.default
        let rootURL = URL(fileURLWithPath: root).standardizedFileURL
        guard let walker = fileManager.enumerator(atPath: root) else { return }
        for case let relativePath as String in walker {
            let full = root + "/" + relativePath
            guard let linkTarget = try? fileManager.destinationOfSymbolicLink(atPath: full) else { continue }
            if linkTarget.hasPrefix("/") {
                throw RunnerError.unsafeArchive("\(relativePath) -> \(linkTarget)")
            }
            let parent = URL(fileURLWithPath: full).deletingLastPathComponent()
            let resolved = URL(fileURLWithPath: linkTarget, relativeTo: parent).standardizedFileURL
            if !isInside(resolved.path, root: rootURL.path) {
                throw RunnerError.unsafeArchive("\(relativePath) -> \(linkTarget)")
            }
        }
    }

    static func isInside(_ path: String, root: String) -> Bool {
        path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/")
    }
}
