import Foundation

/// Protocol for accessing and filtering package receipts.
public protocol PackageRepository: Sendable {
    func fetchCatalog() async throws -> ReceiptCatalog
    func validatedReadSession() async throws -> any PackageRepository
    func validateReadSession() async throws
    func fetchPackages() async throws -> [PackageID]
    func fetchGroups() async throws -> [String]
    func fetchPackages(inGroup groupID: String) async throws -> [PackageID]
    func fetchGroups(for id: PackageID) async throws -> [String]
    func fetchDetails(for id: PackageID) async throws -> PackageReceipt
    func fetchFiles(for id: PackageID) async throws -> [ReceiptFile]
    func fetchFiles(for id: PackageID, filter: ReceiptFileFilter) async throws -> [ReceiptFile]
    func lookupFileOwner(path: String) async throws -> FileLookupResult
    func lookupFileOwners(paths: [String]) async throws -> [String: FileLookupResult]
    func fetchOwnershipEvidence(paths: [String]) async throws -> ReceiptOwnershipRead
}

public extension PackageRepository {
    func fetchOwnershipEvidence(paths: [String]) async throws -> ReceiptOwnershipRead {
        ReceiptOwnershipRead(owners: try await lookupFileOwners(paths: paths))
    }
    func lookupFileOwners(paths: [String]) async throws -> [String: FileLookupResult] {
        try await withThrowingTaskGroup(of: (String, FileLookupResult?).self) { group in
            var next = Set(paths).makeIterator()
            func enqueue(_ path: String) {
                group.addTask {
                    do { return (path, try await lookupFileOwner(path: path)) }
                    catch is CancellationError { throw CancellationError() }
                    catch { return (path, nil) }
                }
            }
            for _ in 0..<min(4, paths.count) { if let path = next.next() { enqueue(path) } }
            var results: [String: FileLookupResult] = [:]
            while let (requested, result) = try await group.next() {
                if let result { results[requested] = result }
                if let path = next.next() { enqueue(path) }
            }
            return results
        }
    }

    // Alternate repositories explicitly own the completeness of the data they provide.
    // The system-backed implementation overrides all three methods.
    func fetchCatalog() async throws -> ReceiptCatalog {
        ReceiptCatalog(packages: try await fetchPackages(), coverage: .complete,
                       volume: CleanupVolumeIdentity.capture("/"))
    }

    func validatedReadSession() async throws -> any PackageRepository {
        try await fetchCatalog().requireComplete()
        return self
    }

    func validateReadSession() async throws {
        try await fetchCatalog().requireComplete()
    }

    func fetchGroups(for id: PackageID) async throws -> [String] {
        let receipt = try await fetchDetails(for: id)
        return receipt.groups
    }

    func fetchFiles(for id: PackageID, filter: ReceiptFileFilter) async throws -> [ReceiptFile] {
        try await fetchFiles(for: id)
    }
}
