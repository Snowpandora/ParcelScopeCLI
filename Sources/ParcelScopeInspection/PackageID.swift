import Foundation

/// A typed wrapper for the raw string identifier of a package (e.g., "com.apple.pkg.BaseSystem").
public struct PackageID: Sendable, Hashable, RawRepresentable, Codable {
    public let rawValue: String

    public init?(rawValue: String) {
        if rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }
        self.rawValue = rawValue
    }

    public init(_ rawValue: String) throws {
        guard let id = PackageID(rawValue: rawValue) else {
            throw PackageIDError.invalidFormat
        }
        self = id
    }
}

extension PackageID: CustomStringConvertible {
    public var description: String { rawValue }
}

public enum PackageIDError: Error {
    case invalidFormat
}
