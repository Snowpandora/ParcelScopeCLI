import Foundation
import Darwin
import ParcelScopeInspection

public extension ResidualQuarantinePlanner {
    func review(repository: any PackageRepository) async throws -> ResidualQuarantineAction? {
        var candidate = stat()
        if lstat(Self.path, &candidate) == -1 {
            guard errno == ENOENT else { throw ResidualQuarantineError.unsafeOrChanged }
            return nil
        }
        let repository = try await repository.validatedReadSession()
        let catalog = try await repository.fetchCatalog()
        try catalog.requireComplete()
        guard catalog.volume.mountPoint == "/", catalog.volume.isIdentified,
              Set(catalog.packages).count == catalog.packages.count else { throw ResidualQuarantineError.ownershipUnavailable }
        let read = try await repository.fetchOwnershipEvidence(paths: [Self.path])
        guard let evidence = read.evidence, let context = evidence.readContext,
              context.coverage == .complete, context.volume == catalog.volume,
              evidence.volume == catalog.volume,
              Set(evidence.records.map(\.receipt.packageID)) == Set(catalog.packages.map(\.rawValue)),
              Set(evidence.records.map(\.receipt.packageID)).count == evidence.records.count,
              let lookup = read.owners[Self.path], lookup.path == Self.path else {
            throw ResidualQuarantineError.ownershipUnavailable
        }
        let version = evidence.records.first { $0.receipt.packageID == "com.apple.pkg.CLTools_Executables" }?.receipt.version
        guard version == Self.version else { throw ResidualQuarantineError.unsupportedVersion }
        let action = try Self.review(path: Self.path, version: Self.version, digest: Self.sha256, size: 18_034,
            catalogDigest: try Self.ownershipDigest(evidence), ownerIDs: lookup.owners.map(\.packageID.rawValue), uid: 0)
        try await repository.validateReadSession()
        return action
    }

    static func ownershipDigest(_ evidence: ReceiptOwnershipEvidence) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return ReceiptFileInventory.digest(try encoder.encode(evidence.records))
    }
}

public extension ResidualQuarantineExecutor {
    func quarantine(action: ResidualQuarantineAction, repository: any PackageRepository) async throws -> ResidualRecoveryRecord {
        guard geteuid() == 0, action.path == ResidualQuarantinePlanner.path, action.anchor == "/",
              action.executablesVersion == ResidualQuarantinePlanner.version,
              action.sha256 == ResidualQuarantinePlanner.sha256, action.identity.size == 18_034,
              let fresh = try await ResidualQuarantinePlanner().review(repository: repository) else {
            throw ResidualQuarantineError.unsafeOrChanged
        }
        return try Self.quarantine(action, fresh: fresh, base: "/private/var/db", uid: 0)
    }
}
