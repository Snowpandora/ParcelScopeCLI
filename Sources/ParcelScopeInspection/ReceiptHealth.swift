import Foundation

/// Health classification based on the presence of installed files on disk.
public enum ReceiptHealthStatus: String, Sendable, Codable, CaseIterable {
    case unknown    // Inspection is incomplete or access could not be established.
    case healthy    // At least 80% of inspected paths were present.
    case degraded   // Some files are missing (20% ..< 80%)
    case ghost      // Fewer than 20% of inspected paths were present; not proof of an orphan.
    case corrupt    // Receipt exists but file list or metadata cannot be processed
    case empty      // Receipt records 0 files
}

/// Comprehensive health report of a package receipt.
public struct ReceiptHealthReport: Sendable, Equatable, Identifiable {
    public var id: PackageID { packageID }
    public let packageID: PackageID
    public let totalFiles: Int
    public let existingFiles: Int
    public let missingFiles: Int
    public let status: ReceiptHealthStatus
    public let isSampled: Bool
    public let unknownFiles: Int
    public let inspectedFiles: Int
    public let scannedAt: Date
    public let volumePath: String

    public init(
        packageID: PackageID,
        totalFiles: Int,
        existingFiles: Int,
        missingFiles: Int,
        status: ReceiptHealthStatus,
        isSampled: Bool = false,
        unknownFiles: Int = 0,
        inspectedFiles: Int? = nil,
        scannedAt: Date = Date(),
        volumePath: String = "/"
    ) {
        self.packageID = packageID
        self.totalFiles = totalFiles
        self.existingFiles = existingFiles
        self.missingFiles = missingFiles
        self.status = status
        self.isSampled = isSampled
        self.unknownFiles = unknownFiles
        self.inspectedFiles = inspectedFiles ?? (existingFiles + missingFiles + unknownFiles)
        self.scannedAt = scannedAt
        self.volumePath = volumePath
    }

    /// Ratio of observed-present paths to inspected paths; not a software integrity verdict.
    public var integrityRatio: Double {
        guard totalFiles > 0 else { return 1.0 }
        return Double(existingFiles) / Double(max(1, inspectedFiles))
    }
}

public extension ReceiptHealthReport {
    var observationSummary: String {
        "\(existingFiles) present, \(missingFiles) missing, \(unknownFiles) unknown · \(inspectedFiles)/\(totalFiles) checked"
            + (isSampled ? " · sampled; not a full verification" : "")
    }
}
