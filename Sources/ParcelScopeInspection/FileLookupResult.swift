import Foundation

/// Represents a package that owns a filesystem path according to pkgutil.
public struct FileOwner: Sendable, Hashable, Identifiable {
    public let id: PackageID
    public let packageID: PackageID
    public let version: String?
    public let installTime: Date?

    public init(packageID: PackageID, version: String? = nil, installTime: Date? = nil) {
        self.id = packageID
        self.packageID = packageID
        self.version = version
        self.installTime = installTime
    }
}

/// Result of `pkgutil --file-info-plist` for a single path.
public struct FileLookupResult: Sendable, Hashable, Identifiable {
    public let id: String
    public let path: String
    public let owners: [FileOwner]

    public init(path: String, owners: [FileOwner]) {
        self.id = path
        self.path = path
        self.owners = owners
    }

    public var isRegistered: Bool {
        !owners.isEmpty
    }
}
