import Foundation

/// Protocol defining the interface for interacting with pkgutil.
public protocol PkgutilClient: Sendable {
    func readCatalog() async throws -> ReceiptCatalog
    func validatedSession() async throws -> any PkgutilClient
    func validateSession() async throws
    func listPackages() async throws -> [PackageID]
    func listGroups() async throws -> [String]
    func listPackages(inGroup groupID: String) async throws -> [PackageID]
    func listPackageGroups(for id: PackageID) async throws -> [String]
    func getPackageInfo(for id: PackageID) async throws -> PackageReceipt
    func getFiles(for id: PackageID) async throws -> [ReceiptFile]
    func getFiles(for id: PackageID, filter: ReceiptFileFilter) async throws -> [ReceiptFile]
    func getFileInventory(for id: PackageID) async throws -> ReceiptFileInventory
    func reverseLookup(path: String) async throws -> FileLookupResult
}

public extension PkgutilClient {
    func getFileInventory(for id: PackageID) async throws -> ReceiptFileInventory {
        let files = try await getFiles(for: id)
        return ReceiptFileInventory(files: files, sha256: ReceiptFileInventory.digest(Data(files.map { $0.relativePath + "\n" }.joined().utf8)))
    }
    func readCatalog() async throws -> ReceiptCatalog {
        ReceiptCatalog(packages: try await listPackages(), coverage: .complete, volume: .capture("/"))
    }
    func validatedSession() async throws -> any PkgutilClient {
        try await readCatalog().requireComplete()
        return self
    }
    func validateSession() async throws { try await readCatalog().requireComplete() }
    func listPackageGroups(for id: PackageID) async throws -> [String] {
        let receipt = try await getPackageInfo(for: id)
        return receipt.groups
    }

    func getFiles(for id: PackageID, filter: ReceiptFileFilter) async throws -> [ReceiptFile] {
        try await getFiles(for: id)
    }
}

/// Production implementation of PkgutilClient using the system pkgutil command.
public final class PkgutilClientImpl: PkgutilClient {
    private let runner: any ProcessExecuting
    private let volume: String
    private let storeReader: @Sendable () -> ReceiptStoreSnapshot
    private let sessionStore: ReceiptStoreSnapshot?
    private let sessionCatalog: ReceiptCatalog?
    private let pkgutilPath = "/usr/sbin/pkgutil"

    public init(runner: any ProcessExecuting = ProcessRunner(), volume: String = "/",
                storeReader: (@Sendable () -> ReceiptStoreSnapshot)? = nil) {
        self.runner = runner
        self.volume = volume
        self.storeReader = storeReader ?? ReceiptStoreSnapshot.makeReader(volume: volume)
        sessionStore = nil
        sessionCatalog = nil
    }

    private init(runner: any ProcessExecuting, volume: String,
                 storeReader: @escaping @Sendable () -> ReceiptStoreSnapshot,
                 snapshot: ReceiptStoreSnapshot, catalog: ReceiptCatalog) {
        self.runner = runner
        self.volume = volume
        self.storeReader = storeReader
        sessionStore = snapshot
        sessionCatalog = catalog
    }

    private func catalogObservation() async throws -> (ReceiptCatalog, ReceiptStoreSnapshot) {
        let identity = CleanupVolumeIdentity.capture(volume)
        let before = storeReader()
        var diagnostics = before.diagnostics
        var ids: [PackageID] = []
        do {
            let result = try await runner.run(path: pkgutilPath, arguments: ["--pkgs"])
            ids = try PkgutilParser.parsePackageIDsStrict(result.stdout)
            if !result.stderr.isEmpty {
                diagnostics.append(.init(kind: .invalidData, resource: "pkgutil --pkgs",
                                         message: String(decoding: result.stderr, as: UTF8.self)))
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            diagnostics.append(.init(kind: .invalidData, resource: "pkgutil --pkgs", message: error.localizedDescription))
        }
        let after = storeReader()
        if before != after || CleanupVolumeIdentity.capture(volume) != identity {
            diagnostics.append(.init(kind: .changedDuringRead, resource: volume, message: "Receipt stores changed during enumeration."))
        }
        let listedIDs = Set(ids.map(\.rawValue))
        if listedIDs.count != ids.count {
            var seen: Set<PackageID> = []
            if let duplicate = ids.first(where: { !seen.insert($0).inserted }) {
                diagnostics.append(.init(kind: .duplicateIdentifier, resource: duplicate.rawValue,
                    message: "macOS lists more than one registration for \(duplicate.rawValue). Cleanup requires an unambiguous receipt catalog."))
            }
        }
        if listedIDs != before.packageIDs {
            diagnostics.append(.init(kind: .inconsistentResults, resource: volume,
                                     message: "The package query and readable receipt stores do not describe the same identifier set."))
        }
        let coverage: ReceiptCoverage = diagnostics.isEmpty ? .complete : (ids.isEmpty ? .unavailable : .partial)
        return (ReceiptCatalog(packages: ids, coverage: coverage, volume: identity, diagnostics: diagnostics), before)
    }

    public func readCatalog() async throws -> ReceiptCatalog {
        if let sessionCatalog {
            try await validateSession()
            return sessionCatalog
        }
        return try await catalogObservation().0
    }

    public func validatedSession() async throws -> any PkgutilClient {
        try await makeValidatedClient()
    }

    private func makeValidatedClient() async throws -> PkgutilClientImpl {
        let (catalog, snapshot) = try await catalogObservation()
        try catalog.requireComplete()
        return PkgutilClientImpl(runner: runner, volume: volume, storeReader: storeReader, snapshot: snapshot, catalog: catalog)
    }

    public func validateSession() async throws {
        guard let sessionStore else {
            try await readCatalog().requireComplete()
            return
        }
        guard storeReader() == sessionStore, sessionStore.isComplete,
              sessionCatalog?.volume == CleanupVolumeIdentity.capture(volume) else { throw ReceiptReadError.changedDuringRead }
    }

    private func query(_ arguments: [String]) async throws -> ProcessRunner.ProcessResult {
        guard let sessionStore else {
            let session = try await makeValidatedClient()
            return try await session.query(arguments)
        }
        if let fileFlag = arguments.firstIndex(of: "--files"), arguments.indices.contains(fileFlag + 1),
           !sessionStore.fileInventoryPackageIDs.contains(arguments[fileFlag + 1]) {
            throw ReceiptReadError.incomplete([.init(kind: .unreadableStore, resource: arguments[fileFlag + 1], message: "The receipt has no validated readable file inventory.")])
        }
        try sessionStore.validateUnchanged()
        let result = try await runner.run(path: pkgutilPath, arguments: arguments)
        try await validateSession()
        guard result.stderr.isEmpty else { throw ReceiptReadError.invalidOutput(arguments.joined(separator: " ")) }
        if arguments.first == "--files", arguments.count == 2,
           let expected = sessionStore.inventoryPaths[arguments[1]] {
            let files = PkgutilParser.parseFiles(result.stdout).map(\.relativePath)
            guard Set(files) == expected, Set(files).count == files.count else {
                throw ReceiptReadError.invalidOutput("The file query does not match the validated BOM inventory.")
            }
        }
        return result
    }

    public func listPackages() async throws -> [PackageID] {
        let catalog = try await readCatalog()
        try catalog.requireComplete()
        return catalog.packages
    }

    public func listGroups() async throws -> [String] {
        let result = try await query(["--groups-plist"])
        return try PkgutilParser.parseGroups(result.stdout)
    }

    public func listPackages(inGroup groupID: String) async throws -> [PackageID] {
        let result = try await query(["--group-pkgs", groupID])
        return try PkgutilParser.parsePackageIDsStrict(result.stdout)
    }

    public func listPackageGroups(for id: PackageID) async throws -> [String] {
        let result = try await query(["--pkg-groups", id.rawValue])
        guard String(data: result.stdout, encoding: .utf8) != nil else { throw ReceiptReadError.invalidOutput("--pkg-groups") }
        return PkgutilParser.parsePackageGroups(result.stdout)
    }

    public func getPackageInfo(for id: PackageID) async throws -> PackageReceipt {
        let result = try await query(["--pkg-info-plist", id.rawValue])
        return try PkgutilParser.parsePackageInfo(result.stdout, packageID: id)
    }

    public func getFiles(for id: PackageID) async throws -> [ReceiptFile] {
        try await getFiles(for: id, filter: .all)
    }

    public func getFiles(for id: PackageID, filter: ReceiptFileFilter) async throws -> [ReceiptFile] {
        let arguments = filter.pkgutilFlags + ["--files", id.rawValue]
        let result = try await query(arguments)
        guard String(data: result.stdout, encoding: .utf8) != nil else { throw ReceiptReadError.invalidOutput("--files") }
        return PkgutilParser.parseFiles(result.stdout)
    }

    public func getFileInventory(for id: PackageID) async throws -> ReceiptFileInventory {
        let result = try await query(["--files", id.rawValue])
        guard String(data: result.stdout, encoding: .utf8) != nil else { throw ReceiptReadError.invalidOutput("--files") }
        return ReceiptFileInventory(files: PkgutilParser.parseFiles(result.stdout), sha256: ReceiptFileInventory.digest(result.stdout))
    }

    public func reverseLookup(path: String) async throws -> FileLookupResult {
        let result = try await query(["--file-info-plist", path])
        return try PkgutilParser.parseFileInfo(result.stdout, queriedPath: path)
    }

}
