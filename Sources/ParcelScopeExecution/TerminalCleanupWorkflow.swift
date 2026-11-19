import Foundation
import ParcelScopeInspection

/// Locally captured CLI review inputs; validation reconstructs all filesystem evidence.
public struct CLTReviewInputs: Codable, Sendable, Equatable {
    public var id: UUID
    public var createdAt: Date
    public var volume: CleanupVolumeIdentity
    public var receipts: [ReceiptSnapshot]
    public var ownershipEvidence: ReceiptOwnershipEvidence
    public var activeDeveloperPath: String?
    public var replacementDeveloperPath: String?
    public var dryRun: Bool

    public init(id: UUID, createdAt: Date, volume: CleanupVolumeIdentity,
                receipts: [ReceiptSnapshot], ownershipEvidence: ReceiptOwnershipEvidence,
                activeDeveloperPath: String?, replacementDeveloperPath: String?, dryRun: Bool) {
        self.id = id
        self.createdAt = createdAt
        self.volume = volume
        self.receipts = receipts
        self.ownershipEvidence = ownershipEvidence
        self.activeDeveloperPath = activeDeveloperPath
        self.replacementDeveloperPath = replacementDeveloperPath
        self.dryRun = dryRun
    }
}

/// Read-only reconstruction and validation; neither operation performs cleanup.
public struct TerminalCleanupWorkflow: Sendable {
    public init() {}

    public func makeRequest(inputs: CLTReviewInputs, repository: any PackageRepository,
                            environment: CLTEnvironment, now: Date = Date()) async throws -> CleanupExecutionRequest {
        try Task.checkCancellation()
        guard inputs.volume.isIdentified, inputs.volume.mountPoint == "/",
              now.timeIntervalSince(inputs.createdAt) >= 0,
              now.timeIntervalSince(inputs.createdAt) <= 1_800,
              inputs.activeDeveloperPath == environment.activeDeveloperPath,
              environment.directory != .unavailable else { throw WorkflowError.changedState }
        let repository = try await repository.validatedReadSession()
        let catalog = try await repository.fetchCatalog()
        try catalog.requireComplete()
        guard catalog.volume == inputs.volume else { throw WorkflowError.changedState }
        let selectedIDs = inputs.receipts.map(\.packageID)
        let currentIDs = catalog.packages.map(\.rawValue)
        let components = currentIDs.filter(CLTInspector.isCLTReceipt)
        guard !selectedIDs.isEmpty, Set(selectedIDs).count == selectedIDs.count,
              Set(currentIDs).count == currentIDs.count,
              selectedIDs.allSatisfy(CLTInspector.isCLTReceipt),
              Set(selectedIDs) == Set(components) else { throw WorkflowError.changedState }
        try validateOwnership(inputs.ownershipEvidence, volume: inputs.volume, catalogIDs: currentIDs,
                              observedBy: inputs.createdAt, now: now)
        let targets = try selectedIDs.map { try PackageID($0) }
        let rebuilt = try await CleanupPlanBuilder(allowsPresentLegacySDKPlaceholder: true)
            .build(targets: targets, repository: repository, volume: inputs.volume)
        guard rebuilt.schemaVersion == 2, rebuilt.isComplete,
              sameReceipts(rebuilt.receipts, inputs.receipts),
              let ownership = rebuilt.ownershipEvidence,
              sameOwnership(ownership, inputs.ownershipEvidence) else { throw WorkflowError.changedState }
        try validateOwnership(ownership, volume: inputs.volume, catalogIDs: currentIDs,
                              observedBy: rebuilt.generatedAt, now: max(now, rebuilt.generatedAt))
        let selectedStandalone = environment.activeDeveloperPath == CLTInspector.directory
        let reset = selectedStandalone && inputs.replacementDeveloperPath != nil
        if reset, inputs.replacementDeveloperPath.map(CLTInspector.isValidatedFullXcodeDeveloperPath) != true {
            throw WorkflowError.developerUnavailable
        }
        let plan = CleanupEvidencePlan(id: inputs.id, generatedAt: rebuilt.generatedAt,
            volume: rebuilt.volume, receipts: rebuilt.receipts, entries: rebuilt.entries,
            isComplete: rebuilt.isComplete, ownershipEvidence: ownership)
        let request = CleanupExecutionRequest(plan: plan, dryRun: inputs.dryRun, forgetReceipts: true,
            resetDeveloperSelection: reset, cltDirectory: CLTInspector.directory,
            activeDeveloperPath: environment.activeDeveloperPath,
            replacementDeveloperPath: reset ? inputs.replacementDeveloperPath : nil, recipe: .clt)
        try ValidatedCleanupScriptExporter().validateTerminalReview(request, currentVolume: catalog.volume,
                                                                   now: max(now, plan.generatedAt))
        try await repository.validateReadSession()
        try Task.checkCancellation()
        return request
    }

    public func revalidate(_ frozen: CleanupExecutionRequest, repository: any PackageRepository,
                           environment: CLTEnvironment, currentVolume: CleanupVolumeIdentity,
                           now: Date = Date()) async throws {
        try Task.checkCancellation()
        guard !frozen.dryRun, frozen.recipe == .clt, frozen.forgetReceipts,
              frozen.cltDirectory == CLTInspector.directory,
              currentVolume.isIdentified, currentVolume.mountPoint == "/",
              frozen.plan.schemaVersion == 2,
              frozen.plan.isCurrent(at: now, volume: currentVolume),
              let ownership = frozen.plan.ownershipEvidence else { throw WorkflowError.unsupportedRequest }
        let inputs = CLTReviewInputs(id: frozen.id, createdAt: frozen.plan.generatedAt,
            volume: frozen.plan.volume, receipts: frozen.plan.receipts,
            ownershipEvidence: ownership, activeDeveloperPath: frozen.activeDeveloperPath,
            replacementDeveloperPath: frozen.replacementDeveloperPath, dryRun: false)
        let fresh = try await makeRequest(inputs: inputs, repository: repository, environment: environment, now: now)
        guard fresh.recipe == frozen.recipe, fresh.dryRun == frozen.dryRun,
              fresh.forgetReceipts == frozen.forgetReceipts,
              fresh.resetDeveloperSelection == frozen.resetDeveloperSelection,
              fresh.cltDirectory == frozen.cltDirectory,
              fresh.activeDeveloperPath == frozen.activeDeveloperPath,
              fresh.replacementDeveloperPath == frozen.replacementDeveloperPath,
              fresh.plan.volume == frozen.plan.volume,
              fresh.plan.isComplete == frozen.plan.isComplete,
              sameReceipts(fresh.plan.receipts, frozen.plan.receipts),
              fresh.plan.entries.count == frozen.plan.entries.count,
              zip(fresh.plan.entries, frozen.plan.entries).allSatisfy({ sameEntry($0.0, $0.1) }),
              let freshOwnership = fresh.plan.ownershipEvidence,
              sameOwnership(freshOwnership, ownership) else { throw WorkflowError.changedState }
    }

    private func sameReceipts(_ lhs: [ReceiptSnapshot], _ rhs: [ReceiptSnapshot]) -> Bool {
        lhs.sorted { $0.packageID < $1.packageID } == rhs.sorted { $0.packageID < $1.packageID }
    }

    private func sameOwnership(_ lhs: ReceiptOwnershipEvidence, _ rhs: ReceiptOwnershipEvidence) -> Bool {
        lhs.volume == rhs.volume && lhs.catalogSHA256 == rhs.catalogSHA256 && lhs.records == rhs.records
    }

    private func sameEntry(_ lhs: CleanupPathEvidence, _ rhs: CleanupPathEvidence) -> Bool {
        lhs.path == rhs.path && lhs.itemType == rhs.itemType && lhs.owners == rhs.owners
            && lhs.baseline == rhs.baseline && lhs.reason == rhs.reason && lhs.source == rhs.source
            && sameFingerprint(lhs, rhs) && lhs.symbolicLinkTarget == rhs.symbolicLinkTarget
    }

    private func sameFingerprint(_ lhs: CleanupPathEvidence, _ rhs: CleanupPathEvidence) -> Bool {
        // The review and verifier create private work directories here after the snapshot.
        // For this preserved parent, match the inode, device and mode, not its changing contents.
        guard lhs.path == "/private/tmp", lhs.reason == .installationContainer else {
            return lhs.fingerprint == rhs.fingerprint
        }
        guard let reviewed = lhs.fingerprint?.split(separator: ":"),
              let current = rhs.fingerprint?.split(separator: ":"),
              reviewed.count == 5, current.count == 5 else { return false }
        return reviewed.suffix(3).elementsEqual(current.suffix(3))
    }

    private func validateOwnership(_ evidence: ReceiptOwnershipEvidence, volume: CleanupVolumeIdentity,
                                   catalogIDs: [String], observedBy: Date, now: Date) throws {
        let ids = evidence.records.map { $0.receipt.packageID }
        guard evidence.volume == volume, !ids.isEmpty,
              Set(ids).count == ids.count, Set(ids) == Set(catalogIDs),
              evidence.catalogSHA256 == ReceiptOwnershipEvidence(volume: volume, records: evidence.records).catalogSHA256,
              evidence.records.allSatisfy({ record in
                  record.filesSHA256.count == 64 && record.filesSHA256.utf8.allSatisfy {
                      (48...57).contains($0) || (97...102).contains($0)
                  }
              }) else { throw WorkflowError.incompleteEvidence }
        if let context = evidence.readContext {
            guard context.coverage == .complete, context.volume == volume,
                  context.observedAt <= observedBy,
                  now.timeIntervalSince(context.observedAt) <= 1_800 else { throw WorkflowError.incompleteEvidence }
        }
    }

    private enum WorkflowError: LocalizedError {
        case changedState, unsupportedRequest, incompleteEvidence, developerUnavailable
        var errorDescription: String? {
            switch self {
            case .changedState:
                "The installed components, ownership, paths, or developer selection changed. Inspect and review a new Terminal plan."
            case .unsupportedRequest:
                "The Terminal execution request is incomplete, expired, or outside the supported CLT workflow. Inspect a new plan."
            case .incompleteEvidence:
                "Complete current ownership evidence for every installed receipt is required. Inspect a new plan."
            case .developerUnavailable:
                "The optional Xcode replacement is invalid. Choose a valid replacement or continue without switching."
            }
        }
    }
}
