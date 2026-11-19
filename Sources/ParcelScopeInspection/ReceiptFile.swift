import Foundation

/// Represents a single file path associated with a package receipt.
public struct ReceiptFile: Sendable, Hashable, Identifiable {
    public let id: String
    public let relativePath: String

    public init(relativePath: String) {
        self.relativePath = relativePath
        self.id = relativePath
    }
}

/// Filter scope for querying package receipt files via `pkgutil --files`.
public enum ReceiptFileFilter: String, Sendable, CaseIterable, Hashable {
    case all
    case onlyFiles
    case onlyDirectories

    /// Extra CLI flags passed to `pkgutil` alongside `--files`.
    public var pkgutilFlags: [String] {
        switch self {
        case .all:
            return []
        case .onlyFiles:
            return ["--only-files"]
        case .onlyDirectories:
            return ["--only-dirs"]
        }
    }
}
