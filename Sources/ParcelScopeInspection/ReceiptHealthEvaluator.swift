import Foundation

/// Evaluates the physical presence and health status of files tracked by a package receipt.
public final class ReceiptHealthEvaluator: Sendable {
    public init() {}

    /// Maximum number of files to sample for large packages to prevent blocking the actor / thread pool.
    public static let defaultSampleThreshold = 300
    public static let maxSampleSize = 150

    /// Evaluates the health report of a receipt given its recorded files and an existence cache.
    public func evaluate(
        receipt: PackageReceipt,
        files: [ReceiptFile],
        cache: FileExistenceCache = FileExistenceCache(),
        sampleThreshold: Int = defaultSampleThreshold,
        maxSampleSize: Int = maxSampleSize
    ) async -> ReceiptHealthReport {
        guard !files.isEmpty else {
            return ReceiptHealthReport(
                packageID: receipt.id,
                totalFiles: 0,
                existingFiles: 0,
                missingFiles: 0,
                status: .empty,
                isSampled: false,
                volumePath: receipt.volume
            )
        }

        let total = files.count
        let shouldSample = total > sampleThreshold && maxSampleSize > 0

        let evalFiles: [ReceiptFile]
        if shouldSample {
            // Select evenly spaced samples across the file list without claiming statistical confidence
            let count = min(total, maxSampleSize)
            evalFiles = (0..<count).map { files[$0 * total / count] }
        } else {
            evalFiles = files
        }

        var existingCount = 0
        var missingCount = 0
        var unknownCount = 0

        for file in evalFiles {
            let fullPath = receipt.absoluteURL(for: file).path
            if Task.isCancelled { break }
            switch await cache.observation(atPath: fullPath) {
            case .present: existingCount += 1
            case .missing: missingCount += 1
            case .unavailable: unknownCount += 1
            }
        }
        let inspected = existingCount + missingCount + unknownCount

        let evalTotal = evalFiles.count
        let ratio = evalTotal > 0 ? (Double(existingCount) / Double(evalTotal)) : 0.0

        let status: ReceiptHealthStatus
        if unknownCount > 0 || inspected < evalTotal {
            status = .unknown
        } else if ratio >= 0.8 {
            status = .healthy
        } else if ratio >= 0.2 {
            status = .degraded
        } else {
            status = .ghost
        }

        return ReceiptHealthReport(
            packageID: receipt.id, totalFiles: total,
            existingFiles: existingCount, missingFiles: missingCount,
            status: status, isSampled: shouldSample,
            unknownFiles: unknownCount, inspectedFiles: inspected,
            volumePath: receipt.volume
        )
    }
}
