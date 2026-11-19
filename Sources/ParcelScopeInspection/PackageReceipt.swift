import Foundation

/// Represents the decoded metadata of a package receipt.
public struct PackageReceipt: Sendable, Hashable, Identifiable {
    public let id: PackageID
    public let version: String
    public let volume: String
    public let installLocation: String
    public let installTime: Date
    public let groups: [String]
    public let isSystemProtected: Bool

    public init(
        id: PackageID,
        version: String,
        volume: String,
        installLocation: String,
        installTime: Date,
        groups: [String] = [],
        isSystemProtected: Bool = false
    ) {
        self.id = id
        self.version = version
        self.volume = volume
        self.installLocation = installLocation
        self.installTime = installTime
        self.groups = groups
        self.isSystemProtected = isSystemProtected
    }

    /// Computes the standardized absolute file URL on disk for an installed receipt file.
    public func absoluteURL(for file: ReceiptFile) -> URL {
        let baseVolume = volume.isEmpty ? "/" : volume
        let baseLocation = installLocation.isEmpty ? "/" : installLocation
        let pathComponents = [baseVolume, baseLocation, file.relativePath]
            .flatMap { $0.split(separator: "/").map(String.init) }
        let fullPath = "/" + pathComponents.joined(separator: "/")
        return URL(fileURLWithPath: fullPath).standardizedFileURL
    }
}
