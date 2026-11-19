import Foundation
import Darwin

/// Separate from the legacy cleanup manifest so existing JSON stays readable.
public struct ReceiptSnapshot: Sendable, Codable, Equatable {
    public let packageID: String
    public let version: String
    public let installTime: Date
    public let installLocation: String

    public init(_ receipt: PackageReceipt) {
        packageID = receipt.id.rawValue
        version = receipt.version
        installTime = receipt.installTime
        installLocation = receipt.installLocation
    }
}

public struct CleanupVolumeIdentity: Sendable, Codable, Equatable {
    public let mountPoint: String
    public let uuid: String?
    public let device: String?

    public init(mountPoint: String, uuid: String?, device: String?) {
        self.mountPoint = mountPoint
        self.uuid = uuid
        self.device = device
    }

    public var isIdentified: Bool { uuid?.isEmpty == false && device?.isEmpty == false }

    public static func capture(_ mountPoint: String) -> Self {
        var metadata = stat()
        guard !mountPoint.utf8.contains(0), lstat(mountPoint, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFDIR else {
            return Self(mountPoint: mountPoint, uuid: nil, device: nil)
        }
        // Foundation maps startup-volume attributes to Data on some macOS versions.
        // Match diskutil/stat preflight against the actual mounted path instead.
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.volattr = UInt32(ATTR_VOL_INFO) | UInt32(ATTR_VOL_UUID)
        var buffer = [UInt8](repeating: 0, count: 20)
        let result = buffer.withUnsafeMutableBytes {
            getattrlist(mountPoint, &attributes, $0.baseAddress!, $0.count, UInt32(FSOPT_NOFOLLOW))
        }
        let bytes = Array(buffer[4..<20])
        let uuid = result == 0 && bytes.contains(where: { $0 != 0 }) ? NSUUID(uuidBytes: bytes).uuidString : nil
        return Self(mountPoint: mountPoint, uuid: uuid, device: String(metadata.st_dev))
    }

}

public struct CleanupPathEvidence: Sendable, Codable, Equatable, Identifiable {
    public enum ItemType: String, Sendable, Codable { case file, directory, symbolicLink, unknown }
    public enum RetentionReason: String, Sendable, Codable {
        case selectedReceiptOnly, sharedOwnership, unclaimed, lookupUnavailable
        case protectedPath, invalidPath, unknownType, unavailable, sharedDescendant, alreadyMissing
        case emptyContainer, symbolicLinkAncestor, outsideRecipeScope, installationContainer
    }
    public var id: String { path }
    public let path: String
    public let itemType: ItemType
    public let owners: [String]
    public let baseline: FileObservation
    public let reason: RetentionReason
    public let observedAt: Date
    public let source: String
    public let fingerprint: String?
    public let symbolicLinkTarget: String?
    public var proposesRemoval: Bool { reason == .selectedReceiptOnly || reason == .emptyContainer }

    public init(path: String, itemType: ItemType, owners: [String], baseline: FileObservation,
                reason: RetentionReason, observedAt: Date = Date(), fingerprint: String? = nil, symbolicLinkTarget: String? = nil) {
        self.path = path
        self.itemType = itemType
        self.owners = owners.sorted()
        self.baseline = baseline
        self.reason = reason
        self.observedAt = observedAt
        self.fingerprint = fingerprint
        self.symbolicLinkTarget = symbolicLinkTarget
        source = reason == .emptyContainer ? "Fixed standalone CLT container; local path observation; empty-only rmdir"
            : "pkgutil --file-info-plist; receipt file-type queries; local path observation"
    }
}

public struct CleanupEvidencePlan: Sendable, Codable, Equatable, Identifiable {
    public let schemaVersion: Int
    public let id: UUID
    public let generatedAt: Date
    public let volume: CleanupVolumeIdentity
    public let receipts: [ReceiptSnapshot]
    public let entries: [CleanupPathEvidence]
    public let isComplete: Bool
    public let ownershipEvidence: ReceiptOwnershipEvidence?

    public init(id: UUID = UUID(), generatedAt: Date = Date(), volume: CleanupVolumeIdentity,
                receipts: [ReceiptSnapshot], entries: [CleanupPathEvidence], isComplete: Bool, ownershipEvidence: ReceiptOwnershipEvidence? = nil) {
        schemaVersion = 2
        self.id = id
        self.generatedAt = generatedAt
        self.volume = volume
        self.receipts = receipts
        self.entries = entries
        self.isComplete = isComplete
        self.ownershipEvidence = ownershipEvidence
    }

    public var legacyPlan: CleanupPlan? {
        guard let raw = receipts.first?.packageID, let id = PackageID(rawValue: raw) else { return nil }
        return CleanupPlan(packageID: id, actions: entries.map {
            PlannedAction(path: $0.path, kind: !$0.proposesRemoval ? .skipProtected :
                ($0.itemType == .directory ? .deleteDirectory : .deleteFile))
        })
    }

    public func isCurrent(at date: Date = Date(), volume current: CleanupVolumeIdentity) -> Bool {
        isComplete && volume.isIdentified && volume == current
            && date.timeIntervalSince(generatedAt) >= 0 && date.timeIntervalSince(generatedAt) <= 1_800
    }
}

// lstat and readlink describe the leaf itself; neither follows its destination.
extension CleanupPathEvidence {
    public static func isSymbolicLink(_ path: String) -> Bool {
        var metadata = stat()
        return lstat(path, &metadata) == 0 && metadata.st_mode & S_IFMT == S_IFLNK
    }
    public static func hasSymbolicLinkAncestor(_ path: String) -> Bool {
        var parent = (path as NSString).deletingLastPathComponent
        while !parent.isEmpty && parent != "/" {
            if isSymbolicLink(parent) { return true }
            parent = (parent as NSString).deletingLastPathComponent
        }
        return false
    }
    public static func linkTarget(_ path: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: path)
    }
}
