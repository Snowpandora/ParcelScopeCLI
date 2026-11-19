import Foundation

/// Represents a storage volume where receipts can be queried.
public struct SystemVolume: Sendable, Hashable, Identifiable {
    public let id: String
    public let name: String
    public let mountPoint: String
    public let isReadOnly: Bool

    public init(name: String, mountPoint: String, isReadOnly: Bool) {
        self.id = mountPoint
        self.name = name
        self.mountPoint = mountPoint
        self.isReadOnly = isReadOnly
    }

    /// The default boot volume.
    public static var root: SystemVolume {
        SystemVolume(name: "Current Startup Volume", mountPoint: "/", isReadOnly: false)
    }
}
