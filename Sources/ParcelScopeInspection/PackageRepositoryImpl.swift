import Foundation
import Darwin

public final class PackageRepositoryImpl: PackageRepository {
    private let client: any PkgutilClient
    private let observeObject: @Sendable (String) throws -> OwnershipObject?

    public init(client: any PkgutilClient = PkgutilClientImpl()) {
        self.client = client
        observeObject = OwnershipObject.inspect
    }

    init(client: any PkgutilClient, observeObject: @escaping @Sendable (String) throws -> OwnershipObject?) {
        self.client = client
        self.observeObject = observeObject
    }

    public func fetchCatalog() async throws -> ReceiptCatalog { try await client.readCatalog() }

    public func validatedReadSession() async throws -> any PackageRepository {
        PackageRepositoryImpl(client: try await client.validatedSession(), observeObject: observeObject)
    }

    public func validateReadSession() async throws { try await client.validateSession() }

    public func fetchPackages() async throws -> [PackageID] {
        try await client.listPackages()
    }

    public func fetchGroups() async throws -> [String] {
        try await client.listGroups()
    }

    public func fetchPackages(inGroup groupID: String) async throws -> [PackageID] {
        try await client.listPackages(inGroup: groupID)
    }

    public func fetchGroups(for id: PackageID) async throws -> [String] {
        try await client.listPackageGroups(for: id)
    }

    public func fetchDetails(for id: PackageID) async throws -> PackageReceipt {
        try await client.getPackageInfo(for: id)
    }

    public func fetchFiles(for id: PackageID) async throws -> [ReceiptFile] {
        try await client.getFiles(for: id, filter: .all)
    }

    public func fetchFiles(for id: PackageID, filter: ReceiptFileFilter) async throws -> [ReceiptFile] {
        try await client.getFiles(for: id, filter: filter)
    }

    public func lookupFileOwner(path: String) async throws -> FileLookupResult {
        try await client.reverseLookup(path: path)
    }

    public func lookupFileOwners(paths: [String]) async throws -> [String: FileLookupResult] {
        try await fetchOwnershipEvidence(paths: paths).owners
    }

    public func fetchOwnershipEvidence(paths: [String]) async throws -> ReceiptOwnershipRead {
        let scoped = try await client.validatedSession()
        let catalog = try await scoped.readCatalog()
        try catalog.requireComplete()
        let targets = Set(paths)
        var resolvedParents: [String: String] = [:]
        var parentObjects: [String: OwnershipObject] = [:]
        var absentParents: Set<String> = []
        func parent(of path: String) throws -> (path: String, identity: String?, device: dev_t?) {
            guard path.hasPrefix("/"), !path.utf8.contains(0) else { throw ReceiptReadError.invalidOutput("Invalid ownership path.") }
            let raw = (path as NSString).deletingLastPathComponent
            let resolved = try Self.resolveParent(raw.isEmpty ? "/" : raw, cache: &resolvedParents)
            if let cached = parentObjects[resolved] { return (resolved, cached.identity, cached.device) }
            if absentParents.contains(resolved) { return (resolved, nil, nil) }
            guard let object = try observeObject(resolved) else {
                absentParents.insert(resolved)
                return (resolved, nil, nil)
            }
            guard object.type == .directory else { throw ReceiptReadError.invalidOutput("Ownership parent changed: \(resolved)") }
            parentObjects[resolved] = object
            return (resolved, object.identity, object.device)
        }
        var targetsByPath: [String: Set<String>] = [:]
        var targetsByObject: [String: Set<String>] = [:]
        var targetParents: Set<String> = []
        var hasMultipleLinks = false
        var asciiLeafNames: Set<String> = []
        var canFilterASCIILeaves = true
        var apfsParents: [String: Bool] = [:]
        for path in targets {
            let location = try parent(of: path)
            let key = (location.path as NSString).appendingPathComponent((path as NSString).lastPathComponent)
            targetsByPath[key, default: []].insert(path)
            if let object = try observeObject(path) {
                targetsByObject[object.identity, default: []].insert(path)
                if let identity = location.identity { targetParents.insert(identity) }
                // Directory link counts include child directories; they are not file hard-link counts.
                if object.type != .directory, object.linkCount > 1 { hasMultipleLinks = true }
                if canFilterASCIILeaves {
                    let apfs = apfsParents[location.path] ?? Self.isAPFS(location.path)
                    apfsParents[location.path] = apfs
                    if apfs, object.device == location.device, object.type != .unknown, let name = Self.asciiLeafName(path) {
                        asciiLeafNames.insert(name)
                    } else { canFilterASCIILeaves = false }
                }
            }
        }
        var owners: [String: Set<FileOwner>] = [:]
        var records: [ReceiptOwnershipEvidence.Record] = []
        for id in catalog.packages {
            try Task.checkCancellation()
            let receipt = try await scoped.getPackageInfo(for: id)
            guard receipt.volume == catalog.volume.mountPoint else { throw ReceiptReadError.changedDuringRead }
            let owner = FileOwner(packageID: id, version: receipt.version, installTime: receipt.installTime)
            let inventory = try await scoped.getFileInventory(for: id)
            records.append(.init(receipt: ReceiptSnapshot(receipt), filesSHA256: inventory.sha256))
            for file in targets.isEmpty ? [] : inventory.files {
                let path = CleanupPlanner.makeAbsolutePath(relativePath: file.relativePath,
                    volume: receipt.volume, installLocation: receipt.installLocation)
                if targets.contains(path) { owners[path, default: []].insert(owner) }
                // Absent targets have no filesystem object that an alias could share. Preserve
                // exact receipt claims and every inventory digest without probing unrelated parents.
                guard !targetsByObject.isEmpty else { continue }
                // On APFS, distinct ASCII leaf names cannot alias single-link targets.
                // Unicode names and cross-parent hard links still require the full proof.
                if canFilterASCIILeaves, !hasMultipleLinks,
                   let name = Self.asciiLeafName(path), !asciiLeafNames.contains(name) { continue }
                let location = try parent(of: path)
                let key = (location.path as NSString).appendingPathComponent((path as NSString).lastPathComponent)
                for target in targetsByPath[key] ?? [] { owners[target, default: []].insert(owner) }
                // Case/Unicode and parent aliases share a parent identity. Only multiply-linked
                // file/link targets need cross-parent object probes. Unrelated protected leaves
                // must not become a new permission prerequisite for ordinary target cleanup.
                guard hasMultipleLinks || Self.hasDotComponents(path)
                    || location.identity.map(targetParents.contains) == true else { continue }
                if let object = try observeObject(path) {
                    for target in targetsByObject[object.identity] ?? [] { owners[target, default: []].insert(owner) }
                }
            }
        }
        try await scoped.validateSession()
        let result = Dictionary(uniqueKeysWithValues: targets.map { path in
            (path, FileLookupResult(path: path, owners: Array(owners[path] ?? []).sorted { $0.packageID.rawValue < $1.packageID.rawValue }))
        })
        return ReceiptOwnershipRead(owners: result, evidence: ReceiptOwnershipEvidence(volume: catalog.volume, records: records, readContext: catalog.context))
    }

    private static func hasDotComponents(_ path: String) -> Bool {
        path.split(separator: "/").contains { $0 == "." || $0 == ".." }
    }

    private static func asciiLeafName(_ path: String) -> String? {
        guard !hasDotComponents(path) else { return nil }
        let bytes = Array((path as NSString).lastPathComponent.utf8)
        guard !bytes.isEmpty, bytes.allSatisfy({ $0 > 0 && $0 < 128 }) else { return nil }
        return String(decoding: bytes.map { (65...90).contains($0) ? $0 + 32 : $0 }, as: UTF8.self)
    }

    private static func isAPFS(_ path: String) -> Bool {
        var filesystem = statfs()
        guard statfs(path, &filesystem) == 0 else { return false }
        return withUnsafeBytes(of: filesystem.f_fstypename) {
            String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) == "apfs"
        }
    }

    private static func resolveParent(_ path: String, cache: inout [String: String]) throws -> String {
        if let resolved = cache[path] { return resolved }
        let resolved: String
        if let pointer = realpath(path, nil) {
            defer { free(pointer) }
            resolved = String(cString: pointer)
        } else {
            // Absent payload parents are normal for old receipts; denied or dangling aliases are not.
            guard errno == ENOENT, path != "/" else { throw ReceiptReadError.invalidOutput("Ownership parent could not be resolved: \(path)") }
            var metadata = stat()
            guard lstat(path, &metadata) != 0, errno == ENOENT else { throw ReceiptReadError.invalidOutput("Ownership parent is an unresolved alias: \(path)") }
            let parent = (path as NSString).deletingLastPathComponent
            resolved = (try resolveParent(parent, cache: &cache) as NSString).appendingPathComponent((path as NSString).lastPathComponent)
        }
        cache[path] = resolved
        return resolved
    }
}

struct OwnershipObject: Sendable {
    let identity: String
    let type: CleanupPathEvidence.ItemType
    let linkCount: UInt64
    let device: dev_t

    static func inspect(_ path: String) throws -> Self? {
        var metadata = stat()
        guard lstat(path, &metadata) == 0 else {
            if errno == ENOENT { return nil }
            throw ReceiptReadError.invalidOutput("Ownership object could not be inspected: \(path)")
        }
        let type: CleanupPathEvidence.ItemType
        switch metadata.st_mode & S_IFMT {
        case S_IFREG: type = .file
        case S_IFDIR: type = .directory
        case S_IFLNK: type = .symbolicLink
        default: type = .unknown
        }
        return Self(identity: "\(metadata.st_dev):\(metadata.st_ino)", type: type, linkCount: UInt64(metadata.st_nlink), device: metadata.st_dev)
    }
}
