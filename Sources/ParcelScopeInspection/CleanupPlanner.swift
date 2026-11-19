import Foundation

/// Logic for generating a safe deletion plan.
public enum CleanupPlanner {
    /// Sorts paths so that children (leaf nodes) always come before their parent directories.
    public static func sortLeafFirst(_ paths: [String]) -> [String] {
        let uniquePaths = Set(paths)
        var childrenByParent: [String: [String]] = [:]
        var roots: [String] = []

        for path in uniquePaths {
            if let parent = nearestAncestor(of: path, in: uniquePaths) {
                childrenByParent[parent, default: []].append(path)
            } else {
                roots.append(path)
            }
        }

        for parent in childrenByParent.keys {
            childrenByParent[parent]?.sort(by: pathSort)
        }

        var sorted: [String] = []
        for root in roots.sorted(by: pathSort) {
            appendPostOrder(path: root, childrenByParent: childrenByParent, sorted: &sorted)
        }
        return sorted
    }

    /// Applies conservative path policy; this is not a runtime SIP/SSV entitlement check.
    public static func isProtected(path: String, volume: String = "/") -> Bool {
        guard CleanupPathSafety.isValid(path: path, volume: volume) else { return true }
        let normalizedPath = pathRelativeToVolume(path, volume: volume)

        if normalizedPath == "/usr/local" || normalizedPath.hasPrefix("/usr/local/") {
            return false
        }

        return protectedPrefixes.contains { prefix in
            normalizedPath == prefix || normalizedPath.hasPrefix(prefix + "/")
        }
    }

    /// Generates a complete cleanup plan for a list of receipt paths and a volume mount point.
    public static func generatePlan(
        for packageID: PackageID,
        files: [ReceiptFile],
        volume: String,
        installLocation: String = "/"
    ) -> CleanupPlan {
        let relativePaths = files.map(\.relativePath)
        let sortedPaths = sortLeafFirst(relativePaths)
        let directoryPaths = findDirectoryPaths(in: Set(relativePaths))

        let actions = sortedPaths.map { relativePath in
            let absolutePath = makeAbsolutePath(
                relativePath: relativePath,
                volume: volume,
                installLocation: installLocation
            )
            let kind: PlannedAction.Kind
            if isProtected(path: absolutePath, volume: volume) {
                kind = .skipProtected
            } else if directoryPaths.contains(relativePath) {
                kind = .deleteDirectory
            } else {
                kind = .deleteFile
            }

            return PlannedAction(path: absolutePath, kind: kind)
        }

        return CleanupPlan(packageID: packageID, actions: actions)
    }

    private static let protectedPrefixes = [
        "/System",
        "/usr/bin",
        "/usr/sbin",
        "/bin",
        "/sbin",
        "/var/db/receipts"
    ]

    private static func appendPostOrder(
        path: String,
        childrenByParent: [String: [String]],
        sorted: inout [String]
    ) {
        for child in childrenByParent[path] ?? [] {
            appendPostOrder(path: child, childrenByParent: childrenByParent, sorted: &sorted)
        }
        sorted.append(path)
    }

    private static func nearestAncestor(of path: String, in paths: Set<String>) -> String? {
        var candidate = parentPath(of: path)
        while let current = candidate {
            if paths.contains(current) {
                return current
            }
            candidate = parentPath(of: current)
        }
        return nil
    }

    private static func parentPath(of path: String) -> String? {
        // Fast substring-based parent extraction without split & array reallocation
        guard let lastSlashIndex = path.lastIndex(of: "/") else {
            return nil
        }
        if lastSlashIndex == path.startIndex {
            return path.count > 1 ? "/" : nil
        }
        return String(path[..<lastSlashIndex])
    }

    private static func pathSort(_ lhs: String, _ rhs: String) -> Bool {
        lhs < rhs
    }

    private static func findDirectoryPaths(in paths: Set<String>) -> Set<String> {
        var directories: Set<String> = []
        for path in paths {
            var candidate = parentPath(of: path)
            while let current = candidate {
                if paths.contains(current) {
                    directories.insert(current)
                }
                candidate = parentPath(of: current)
            }
        }
        return directories
    }

    public static func makeAbsolutePath(relativePath: String, volume: String, installLocation: String) -> String {
        if relativePath.hasPrefix("/") {
            return join(volume, relativePath)
        }

        return join(volume, installLocation, relativePath)
    }

    private static func pathRelativeToVolume(_ path: String, volume: String) -> String {
        let normalizedPath = normalizeAbsolutePath(path)
        let normalizedVolume = normalizeVolume(volume)

        guard normalizedVolume != "/" else {
            return normalizedPath
        }

        if normalizedPath == normalizedVolume {
            return "/"
        }

        let prefix = normalizedVolume + "/"
        if normalizedPath.hasPrefix(prefix) {
            return "/" + normalizedPath.dropFirst(prefix.count)
        }

        return normalizedPath
    }

    private static func join(_ components: String...) -> String {
        var joined = ""
        for component in components {
            let trimmed = trimSlashes(component)
            if !trimmed.isEmpty { joined += "/" + trimmed }
        }
        return joined.isEmpty ? "/" : joined
    }

    private static func normalizeAbsolutePath(_ path: String) -> String {
        "/" + trimSlashes(path)
    }

    private static func trimSlashes(_ path: String) -> Substring {
        var value = path[...]
        while value.first == "/" { value.removeFirst() }
        while value.last == "/" { value.removeLast() }
        return value
    }

    private static func normalizeVolume(_ volume: String) -> String {
        let normalized = normalizeAbsolutePath(volume)
        return normalized == "/" ? "/" : normalized
    }
}

// Keep receipt paths lexical: resolving symlinks here would authorize a different target.
public enum CleanupPathSafety {
    public static func isValidVolume(_ volume: String) -> Bool {
        let components = volume.split(separator: "/")
        return volume.hasPrefix("/") && !volume.utf8.contains(0)
            && !components.contains(".") && !components.contains("..")
    }

    private static func relativePathIfLexical(path: String, volume: String) -> String? {
        guard path.hasPrefix("/"), isValidVolume(volume), !path.utf8.contains(0) else { return nil }
        let components = path.split(separator: "/")
        guard !components.contains(".."), !components.contains(".") else { return nil }
        let normalized = "/" + components.joined(separator: "/")
        if volume == "/" { return normalized }
        let root = "/" + volume.split(separator: "/").joined(separator: "/")
        guard normalized == root || normalized.hasPrefix(root + "/") else { return nil }
        return String(normalized.dropFirst(root.count))
    }

    public static func isLexicallyValid(path: String, volume: String) -> Bool {
        relativePathIfLexical(path: path, volume: volume) != nil
    }

    public static func isValid(path: String, volume: String) -> Bool {
        guard let relative = relativePathIfLexical(path: path, volume: volume) else { return false }
        return !["", "/", "/usr", "/usr/local", "/Library", "/Applications", "/Users", "/private", "/var", "/Volumes"].contains(relative)
    }

}

public enum ShellLiteral {
    public static func quote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    public static func printLine(_ value: String) -> String {
        "printf '%s\\n' " + quote(value)
    }
}
