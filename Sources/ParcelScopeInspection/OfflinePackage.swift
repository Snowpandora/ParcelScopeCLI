import Foundation

/// Represents metadata and components extracted from an uninstalled `.pkg` archive file.
public struct OfflinePackageMetadata: Sendable, Equatable, Identifiable {
    public var id: String { packageID ?? path }
    public let path: String
    public let packageID: String?
    public let version: String?
    public let title: String?
    public let entries: [String]
    public let signatureInfo: String?
    public let scripts: [OfflinePackageScript]

    public init(
        path: String,
        packageID: String? = nil,
        version: String? = nil,
        title: String? = nil,
        entries: [String] = [],
        signatureInfo: String? = nil,
        scripts: [OfflinePackageScript] = []
    ) {
        self.path = path
        self.packageID = packageID
        self.version = version
        self.title = title
        self.entries = entries
        self.signatureInfo = signatureInfo
        self.scripts = scripts
    }

    /// Indicates whether the package bundle contains installer scripts.
    public var hasScripts: Bool {
        !scripts.isEmpty
    }
}

/// A script contained inside a `.pkg` distribution (such as preinstall or postinstall).
public struct OfflinePackageScript: Sendable, Equatable, Identifiable {
    public var id: String { name }
    public let name: String
    public let content: String

    public init(name: String, content: String) {
        self.name = name
        self.content = content
    }
}
