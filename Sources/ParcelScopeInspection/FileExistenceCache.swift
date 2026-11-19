import Foundation
import Darwin

/// Evidence of path presence; unavailable is never evidence of absence.
public enum FileObservation: Sendable, Equatable, Codable {
    case present
    case missing
    case unavailable
}

/// A scan-scoped cache. Create a new instance to refresh evidence without racing older scans.
public actor FileExistenceCache {
    public static let shared = FileExistenceCache()

    private var cache: [String: FileObservation] = [:]
    private let observer: @Sendable (String) -> FileObservation
    private let typeObserver: @Sendable (String) -> CleanupPathEvidence.ItemType

    public init(observer: @escaping @Sendable (String) -> FileObservation = FileExistenceCache.inspect,
                typeObserver: @escaping @Sendable (String) -> CleanupPathEvidence.ItemType = FileExistenceCache.inspectType) {
        self.observer = observer
        self.typeObserver = typeObserver
    }

    public nonisolated static func inspect(_ path: String) -> FileObservation {
        var metadata = stat()
        if lstat(path, &metadata) == 0 { return .present }
        return errno == ENOENT ? .missing : .unavailable
    }

    public nonisolated static func inspectType(_ path: String) -> CleanupPathEvidence.ItemType {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else { return .unknown }
        switch metadata.st_mode & S_IFMT {
        case S_IFREG: return .file
        case S_IFDIR: return .directory
        case S_IFLNK: return .symbolicLink
        default: return .unknown
        }
    }

    public func itemType(atPath path: String) -> CleanupPathEvidence.ItemType { typeObserver(path) }

    public nonisolated static func fingerprint(_ path: String) -> String? {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else { return nil }
        return "\(metadata.st_mtimespec.tv_sec):\(metadata.st_size):\(metadata.st_ino):\(metadata.st_dev):\(String(metadata.st_mode, radix: 8))"
    }

    public func observation(atPath path: String) -> FileObservation {
        if let cached = cache[path] { return cached }
        let result = observer(path)
        cache[path] = result
        return result
    }

    /// Checks whether an item exists at the given path, caching the result.
    public func exists(atPath path: String) -> Bool {
        observation(atPath: path) == .present
    }

    /// Stores a known existence status for a given path.
    public func setExists(_ exists: Bool, atPath path: String) {
        cache[path] = exists ? .present : .missing
    }

    /// Clears the cache.
    public func clear() {
        cache.removeAll()
    }
}
