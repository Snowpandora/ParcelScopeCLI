import Foundation

/// Represents a single file operation within a cleanup plan.
public struct PlannedAction: Sendable, Hashable, Identifiable, Codable {
    public enum Kind: String, Sendable, Codable {
        case deleteFile
        case deleteDirectory
        case skipProtected
    }

    public let id: String
    public let path: String
    public let kind: Kind
    public let size: Int64

    public init(path: String, kind: Kind, size: Int64 = 0) {
        self.id = path
        self.path = path
        self.kind = kind
        self.size = size
    }
}

/// Represents the result of a dry-run analysis for a package removal.
public struct CleanupPlan: Sendable, Hashable, Identifiable, Codable {
    public let id: PackageID
    public let packageID: PackageID
    public let actions: [PlannedAction]
    public let totalSize: Int64
    public let isSIPProtected: Bool

    public init(packageID: PackageID, actions: [PlannedAction]) {
        self.id = packageID
        self.packageID = packageID
        self.actions = actions
        self.totalSize = actions.reduce(0) { $0 + $1.size }
        self.isSIPProtected = actions.contains { $0.kind == .skipProtected }
    }
}
