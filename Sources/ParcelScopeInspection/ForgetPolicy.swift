import Foundation

/// Category of a package based on its origin and system criticality.
public enum ApplePackageCategory: String, Sendable, Codable, Equatable {
    /// Core system components that are immutable and protected by Apple (SIP/SSV).
    case coreSystemImmutable
    /// Developer runtime and SDK toolchains (e.g. Command Line Tools, Xcode System Resources) that are removable.
    case developerRuntime
    /// Standard third-party packages.
    case thirdParty
}

/// Policy rules deciding whether a package receipt can be safely forgotten.
public struct ForgetPolicy: Sendable {
    public init() {}

    /// Classifies a package identifier into its origin category.
    public static func classify(packageID: PackageID) -> ApplePackageCategory {
        let lower = packageID.rawValue.lowercased()
        if lower.hasPrefix("com.apple.pkg.cltools") ||
            lower == "com.apple.pkg.xcodesystemresources" ||
            lower.hasPrefix("com.apple.pkg.developer") {
            return .developerRuntime
        }
        if lower.hasPrefix("com.apple.") {
            return .coreSystemImmutable
        }
        return .thirdParty
    }

    /// Evaluates whether a package can be forgotten.
    /// - Parameters:
    ///   - packageID: The package identifier.
    ///   - volume: Target volume, or nil for default boot volume.
    ///   - isSIPProtected: Whether any file in the receipt is protected by SIP.
    /// - Returns: A `ForgetPolicyResult` indicating `.allowed` or `.blocked`.
    public func evaluate(
        packageID: PackageID,
        volume: SystemVolume?,
        isSIPProtected: Bool = false
    ) -> ForgetPolicyResult {
        // 1. Check if the target volume is read-only
        if let volume, volume.isReadOnly {
            return .blocked(reason: "Cannot forget packages on a read-only volume.")
        }

        let isRootVolume = volume == nil || volume?.mountPoint == "/"
        let category = Self.classify(packageID: packageID)

        // 2. Reject Apple immutable system packages on root volume
        if isRootVolume && category == .coreSystemImmutable {
            return .blocked(reason: "Apple system packages on the startup volume cannot be removed.")
        }

        // 3. Reject packages that contain SIP protected files
        if isSIPProtected {
            return .blocked(reason: "Packages containing SIP-protected system files cannot be forgotten.")
        }

        return .allowed
    }
}
