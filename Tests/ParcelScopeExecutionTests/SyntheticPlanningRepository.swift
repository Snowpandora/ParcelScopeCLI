import Foundation
import ParcelScopeInspection

actor PlanningRepository: PackageRepository {
    let ids: [PackageID]
    var paths: [String]
    var directoryPaths: Set<String>
    var owners: [PackageID]
    var ownersByPath: [String: [PackageID]] = [:]
    var lookupFails = false
    var calls = 0
    var maximumInFlight = 0
    var inFlight = 0
    var volume = "/"
    var coverage = ReceiptCoverage.complete
    func setCoverage(_ value: ReceiptCoverage) { coverage = value }
    func fetchCatalog() async throws -> ReceiptCatalog {
        ReceiptCatalog(packages: ids, coverage: coverage, volume: CleanupVolumeIdentity.capture(volume))
    }
    var gateFirstLookup = false
    var lookupEntered = false
    var lookupWaiter: CheckedContinuation<Void, Never>?
    var lookupStartedWaiter: CheckedContinuation<Void, Never>?
    func suspendFirstLookup() { gateFirstLookup = true }
    func waitForLookup() async {
        if lookupEntered { return }
        await withCheckedContinuation { lookupStartedWaiter = $0 }
    }
    func resumeLookup() { lookupWaiter?.resume(); lookupWaiter = nil }

    init(ids: [PackageID], paths: [String], directories: Set<String> = [], owners: [PackageID]) {
        self.ids = ids; self.paths = paths; directoryPaths = directories; self.owners = owners
    }
    func setOwners(_ owners: [PackageID], at path: String) { ownersByPath[path] = owners }
    func setFailure() { lookupFails = true }
    func setVolume(_ value: String) { volume = value }
    func fetchPackages() async throws -> [PackageID] { ids }
    func fetchGroups() async throws -> [String] { [] }
    func fetchPackages(inGroup: String) async throws -> [PackageID] { [] }
    func fetchDetails(for id: PackageID) async throws -> PackageReceipt {
        PackageReceipt(id: id, version: "1", volume: volume, installLocation: "/", installTime: Date(timeIntervalSince1970: 1))
    }
    func fetchFiles(for id: PackageID) async throws -> [ReceiptFile] { paths.map(ReceiptFile.init) }
    func fetchFiles(for id: PackageID, filter: ReceiptFileFilter) async throws -> [ReceiptFile] {
        paths.filter { filter == .all || (filter == .onlyDirectories ? directoryPaths.contains($0) : !directoryPaths.contains($0)) }.map(ReceiptFile.init)
    }
    func lookupFileOwner(path: String) async throws -> FileLookupResult {
        calls += 1; inFlight += 1; maximumInFlight = max(maximumInFlight, inFlight)
        if gateFirstLookup {
            gateFirstLookup = false
            lookupEntered = true
            lookupStartedWaiter?.resume(); lookupStartedWaiter = nil
            await withCheckedContinuation { lookupWaiter = $0 }
        } else { await Task.yield() }
        inFlight -= 1
        if lookupFails { throw ProcessRunner.ProcessError.timedOut(15) }
        return FileLookupResult(path: path, owners: (ownersByPath[path] ?? owners).map { FileOwner(packageID: $0) })
    }
}
