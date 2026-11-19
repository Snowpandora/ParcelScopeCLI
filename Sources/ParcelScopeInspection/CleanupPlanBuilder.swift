import Foundation

public struct CleanupPlanBuilder: Sendable {
    private let allowsPresentLegacySDKPlaceholder: Bool

    public init() { allowsPresentLegacySDKPlaceholder = false }

    public init(allowsPresentLegacySDKPlaceholder: Bool) {
        self.allowsPresentLegacySDKPlaceholder = allowsPresentLegacySDKPlaceholder
    }

    public func build(targets: [PackageID], repository: any PackageRepository,
                      volume: CleanupVolumeIdentity,
                      cache: FileExistenceCache = FileExistenceCache()) async throws -> CleanupEvidencePlan {
        try Task.checkCancellation()
        guard !targets.isEmpty else { throw PlanningError.noTargets }
        let repository = try await repository.validatedReadSession()
        let removalSet = Set(targets.map(\.rawValue))
        let cltRecipe = volume.mountPoint == "/" && targets.allSatisfy { CLTInspector.isCLTReceipt($0.rawValue) }
        var receipts: [ReceiptSnapshot] = []
        var types: [String: CleanupPathEvidence.ItemType] = [:]
        var blocked: Set<String> = []
        var placeholderReceipts: [String: Set<String>] = [:]
        var pathReceipts: [String: Set<String>] = [:]
        for id in Set(targets).sorted(by: { $0.rawValue < $1.rawValue }) {
            try Task.checkCancellation()
            let receipt = try await repository.fetchDetails(for: id)
            guard receipt.volume == volume.mountPoint else { throw PlanningError.volumeMismatch }
            receipts.append(ReceiptSnapshot(receipt))
            async let allQuery = repository.fetchFiles(for: id)
            async let fileQuery = repository.fetchFiles(for: id, filter: .onlyFiles)
            async let directoryQuery = repository.fetchFiles(for: id, filter: .onlyDirectories)
            let (all, files, directories) = try await (allQuery, fileQuery, directoryQuery)
            if cltRecipe, id.rawValue == CLTInspector.updateReceiptID {
                guard all.isEmpty, files.isEmpty, directories.isEmpty else {
                    throw PlanningError.updateReceiptHasPayload
                }
                continue
            }
            if cltRecipe, receipt.installLocation == "/",
               let leaf = CLTInspector.legacyPlaceholderLeaf(id: id.rawValue, all: all, files: files, directories: directories) {
                placeholderReceipts[leaf, default: []].insert(id.rawValue)
            }
            let fileSet = Set(files.map(\.relativePath)), directorySet = Set(directories.map(\.relativePath))
            for record in all {
                let path = CleanupPlanner.makeAbsolutePath(relativePath: record.relativePath, volume: volume.mountPoint,
                    installLocation: receipt.installLocation)
                pathReceipts[path, default: []].insert(id.rawValue)
                let type: CleanupPathEvidence.ItemType = fileSet.contains(record.relativePath) == directorySet.contains(record.relativePath)
                    ? .unknown : (directorySet.contains(record.relativePath) ? .directory : .file)
                if let previous = types[path], previous != type { types[path] = .unknown } else { types[path] = type }
                if ForgetPolicy.classify(packageID: id) == .coreSystemImmutable { blocked.insert(path) }
            }
        }
        var missingPlaceholders: Set<String> = []
        var presentPlaceholders: Set<String> = []
        for (path, receipts) in placeholderReceipts where pathReceipts[path] == receipts {
            switch await cache.observation(atPath: path) {
            case .missing:
                missingPlaceholders.insert(path)
            case .present where allowsPresentLegacySDKPlaceholder && receipts == CLTInspector.legacyPlaceholderReceiptIDs:
                presentPlaceholders.insert(path)
            default:
                break
            }
        }
        let metadataOnlyLeaves = missingPlaceholders
        let terminalPlaceholderLeaves = presentPlaceholders
        let placeholderContainers: Set<String> = metadataOnlyLeaves.isEmpty && terminalPlaceholderLeaves.isEmpty
            ? [] : ["/private", "/private/tmp"]
        let paths = types.keys.sorted()
        // Missing objects cannot be removed, and recipe-excluded containers are always retained.
        // Keep the full receipt/inventory snapshot and exact claims for missing candidates.
        var ownershipPaths: [String] = []
        for path in paths {
            guard await cache.observation(atPath: path) != .unavailable else { continue }
            if cltRecipe && (CLTInspector.isInstallationContainer(path, itemType: types[path] ?? .unknown)
                || (path != CLTInspector.directory && !path.hasPrefix(CLTInspector.directory + "/")
                    && !terminalPlaceholderLeaves.contains(path))) { continue }
            ownershipPaths.append(path)
        }
        let ownershipRead = try await repository.fetchOwnershipEvidence(paths: ownershipPaths)
        let ownership = ownershipRead.owners
        let itemTypes = types
        let blockedPaths = blocked
        let entries = try await withThrowingTaskGroup(of: CleanupPathEvidence.self) { group in
            var next = paths.makeIterator()
            func enqueue(_ path: String) {
                group.addTask {
                    try Task.checkCancellation()
                    let type: CleanupPathEvidence.ItemType = CleanupPathEvidence.isSymbolicLink(path) ? .symbolicLink : (itemTypes[path] ?? .unknown)
                    let baseline = await cache.observation(atPath: path)
                    let reason: CleanupPathEvidence.RetentionReason
                    if !CleanupPathSafety.isLexicallyValid(path: path, volume: volume.mountPoint) {
                        reason = .invalidPath
                    } else if CleanupPathEvidence.hasSymbolicLinkAncestor(path) {
                        reason = .symbolicLinkAncestor
                    } else if cltRecipe && (CLTInspector.isInstallationContainer(path, itemType: type)
                        || (placeholderContainers.contains(path) && type == .directory)) {
                        reason = baseline == .present ? .installationContainer : .unavailable
                    } else if metadataOnlyLeaves.contains(path) && type == .file && baseline == .missing {
                        reason = .alreadyMissing
                    } else if cltRecipe && path != CLTInspector.directory && !path.hasPrefix(CLTInspector.directory + "/")
                        && !terminalPlaceholderLeaves.contains(path) {
                        reason = .outsideRecipeScope
                    } else if blockedPaths.contains(path) || CleanupPlanner.isProtected(path: path, volume: volume.mountPoint) {
                        reason = .protectedPath
                    } else if type == .unknown && baseline != .missing {
                        reason = .unknownType
                    } else if baseline == .unavailable {
                        reason = .unavailable
                    } else {
                        do {
                            guard let lookup = ownership[path] else { throw PlanningError.lookupMismatch }
                            try Task.checkCancellation()
                            guard lookup.path == path else { throw PlanningError.lookupMismatch }
                            let owners = Set(lookup.owners.map { $0.packageID.rawValue })
                            let disposition: CleanupPathEvidence.RetentionReason
                            if terminalPlaceholderLeaves.contains(path) {
                                let object = try OwnershipObject.inspect(path)
                                let verified = owners == CLTInspector.legacyPlaceholderReceiptIDs && type == .file
                                    && object?.type == .file && object?.linkCount == 1
                                disposition = verified ? .selectedReceiptOnly : .outsideRecipeScope
                            } else {
                                disposition = !owners.subtracting(removalSet).isEmpty
                                    ? .sharedOwnership : (owners.isEmpty ? .unclaimed : (baseline == .missing ? .alreadyMissing : .selectedReceiptOnly))
                            }
                            return CleanupPathEvidence(path: path, itemType: type, owners: Array(owners), baseline: baseline, reason: disposition, fingerprint: FileExistenceCache.fingerprint(path), symbolicLinkTarget: type == .symbolicLink ? CleanupPathEvidence.linkTarget(path) : nil)
                        } catch is CancellationError { throw CancellationError() }
                        catch { reason = .lookupUnavailable }
                    }
                    return CleanupPathEvidence(path: path, itemType: type, owners: [], baseline: baseline, reason: reason, fingerprint: FileExistenceCache.fingerprint(path), symbolicLinkTarget: type == .symbolicLink ? CleanupPathEvidence.linkTarget(path) : nil)
                }
            }
            for _ in 0..<min(4, paths.count) { if let path = next.next() { enqueue(path) } }
            var values: [CleanupPathEvidence] = []
            while let entry = try await group.next() {
                values.append(entry)
                if let path = next.next() { enqueue(path) }
            }
            return values
        }
        try Task.checkCancellation()
        try await repository.validateReadSession()
        var recipeEntries = entries
        if cltRecipe {
            recipeEntries.removeAll { $0.path == CLTInspector.directory }
            let baseline = await cache.observation(atPath: CLTInspector.directory)
            let safe = !CleanupPathEvidence.isSymbolicLink(CLTInspector.directory)
                && !CleanupPathEvidence.hasSymbolicLinkAncestor(CLTInspector.directory)
            recipeEntries.append(CleanupPathEvidence(path: CLTInspector.directory, itemType: .directory, owners: [],
                baseline: baseline, reason: !safe ? .symbolicLinkAncestor : (baseline == .missing ? .alreadyMissing : (baseline == .unavailable ? .unavailable : .emptyContainer)),
                fingerprint: FileExistenceCache.fingerprint(CLTInspector.directory)))
        }
        // Every retained descendant also retains its ancestors, without quadratic scans.
        var retainedAncestors: Set<String> = []
        for entry in recipeEntries where !entry.proposesRemoval && entry.reason != .alreadyMissing {
            var parent = (entry.path as NSString).deletingLastPathComponent
            while !parent.isEmpty && parent != "/" {
                retainedAncestors.insert(parent)
                parent = (parent as NSString).deletingLastPathComponent
            }
        }
        let mapped = Dictionary(uniqueKeysWithValues: recipeEntries.map { entry in
            let value = entry.itemType == .directory && entry.reason != .emptyContainer && entry.proposesRemoval && retainedAncestors.contains(entry.path)
                ? CleanupPathEvidence(path: entry.path, itemType: entry.itemType, owners: entry.owners,
                    baseline: entry.baseline, reason: .sharedDescendant, observedAt: entry.observedAt, fingerprint: entry.fingerprint, symbolicLinkTarget: entry.symbolicLinkTarget) : entry
            return (entry.path, value)
        })
        let ordered = CleanupPlanner.sortLeafFirst(recipeEntries.map(\.path)).compactMap { mapped[$0] }
        let complete = !ordered.contains { [.lookupUnavailable, .unclaimed, .unknownType, .unavailable, .invalidPath, .symbolicLinkAncestor].contains($0.reason) }
        return CleanupEvidencePlan(volume: volume, receipts: receipts, entries: ordered, isComplete: complete, ownershipEvidence: ownershipRead.evidence)
    }

    public enum PlanningError: Error { case noTargets, volumeMismatch, lookupMismatch, updateReceiptHasPayload }
}
