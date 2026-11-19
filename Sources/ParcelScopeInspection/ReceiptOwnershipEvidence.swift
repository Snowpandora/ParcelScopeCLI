import CryptoKit
import Foundation

public struct ReceiptFileInventory: Sendable {
    public let files: [ReceiptFile]
    public let sha256: String

    public init(files: [ReceiptFile], sha256: String) {
        self.files = files
        self.sha256 = sha256
    }

    public static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Every receipt contributing to the ownership index, including receipts outside the removal set.
public struct ReceiptOwnershipEvidence: Sendable, Codable, Equatable {
    public struct Record: Sendable, Codable, Equatable {
        public let receipt: ReceiptSnapshot
        public let filesSHA256: String
        public init(receipt: ReceiptSnapshot, filesSHA256: String) {
            self.receipt = receipt
            self.filesSHA256 = filesSHA256
        }
    }
    public let volume: CleanupVolumeIdentity
    public let records: [Record]
    public let catalogSHA256: String
    public let readContext: ReceiptReadContext?

    public init(volume: CleanupVolumeIdentity, records: [Record], readContext: ReceiptReadContext? = nil) {
        self.volume = volume
        self.readContext = readContext
        self.records = records.sorted { $0.receipt.packageID < $1.receipt.packageID }
        let text = self.records.map { $0.receipt.packageID + "\n" }.joined()
        catalogSHA256 = ReceiptFileInventory.digest(Data(text.utf8))
    }
}

public struct ReceiptOwnershipRead: Sendable {
    public let owners: [String: FileLookupResult]
    public let evidence: ReceiptOwnershipEvidence?
    public init(owners: [String: FileLookupResult], evidence: ReceiptOwnershipEvidence? = nil) {
        self.owners = owners
        self.evidence = evidence
    }
}
