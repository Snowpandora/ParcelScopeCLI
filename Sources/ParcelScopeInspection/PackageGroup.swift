import Foundation

/// Represents a named collection of PackageIDs.
public struct PackageGroup: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let packageIDs: [PackageID]

    public init(name: String, packageIDs: [PackageID]) {
        self.id = name
        self.name = name
        self.packageIDs = packageIDs
    }
}
