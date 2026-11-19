import Foundation

public struct CleanupVerifier: Sendable {
    public init() {}
    public func verify(_ request: CleanupExecutionRequest, repository: any PackageRepository,
                       currentVolume: CleanupVolumeIdentity,
                       cache: FileExistenceCache = FileExistenceCache(),
                       developerPath: String? = nil) async -> CleanupVerificationReport {
        guard request.plan.schemaVersion == 2, request.plan.isComplete, !request.plan.receipts.isEmpty else {
            return CleanupVerificationReport(request: request, outcome: .unknown, notes: ["The frozen plan has incomplete evidence. Replan before claiming a result."])
        }
        guard request.plan.isCurrent(volume: currentVolume) else {
            return CleanupVerificationReport(request: request, outcome: .stale, notes: ["The frozen plan expired or the volume changed; replan."])
        }
        if request.dryRun { return CleanupVerificationReport(request: request, outcome: .simulation,
            notes: ["Simulation does not establish execution or cleanup success."]) }
        guard currentVolume.isIdentified, currentVolume == request.plan.volume else {
            return CleanupVerificationReport(request: request, outcome: .stale, notes: ["Volume identity changed or is unavailable; replan."])
        }
        var paths: [CleanupVerificationReport.PathResult] = []
        var receipts: [CleanupVerificationReport.ReceiptResult] = []
        var notes: [String] = []
        var unknown = false, stale = false, failed = 0, changed = 0
        for entry in request.plan.entries {
            if Task.isCancelled { unknown = true; notes.append("Verification cancelled; no success established."); break }
            guard !CleanupPathEvidence.hasSymbolicLinkAncestor(entry.path) else {
                paths.append(.init(path: entry.path, outcome: .unavailable))
                stale = true; notes.append("A path ancestor is now a symbolic link: \(entry.path)")
                continue
            }
            let observation = await cache.observation(atPath: entry.path)
            let result: CleanupVerificationReport.PathOutcome
            switch observation {
            case .unavailable: result = .unavailable; unknown = true
            case .missing:
                result = entry.baseline == .missing ? .alreadyAbsent : .newlyAbsent
                if entry.baseline == .present { changed += 1 }
                if !entry.proposesRemoval && entry.baseline == .present {
                    failed += 1; notes.append("A retained path is now absent: \(entry.path)")
                }
            case .present:
                let type = await cache.itemType(atPath: entry.path)
                if type == .unknown {
                    result = .unavailable; unknown = true
                    notes.append("Path type could not be verified: \(entry.path)")
                } else if type != entry.itemType {
                    result = .unavailable; stale = true
                    notes.append("Path type changed since planning: \(entry.path)")
                } else {
                    result = entry.proposesRemoval || entry.reason == .alreadyMissing ? .stillPresent : .retained
                    if entry.proposesRemoval || entry.reason == .alreadyMissing { failed += 1 }
                }
            }
            paths.append(.init(path: entry.path, outcome: result))
        }
        do {
            let repository = try await repository.validatedReadSession()
            let catalog = try await repository.fetchCatalog()
            try catalog.requireComplete()
            let registered = Set(catalog.packages.map(\.rawValue))
            for snapshot in request.plan.receipts {
                try Task.checkCancellation()
                let observation: String
                if registered.contains(snapshot.packageID) {
                    let current = ReceiptSnapshot(try await repository.fetchDetails(for: PackageID(snapshot.packageID)))
                    if current != snapshot {
                        observation = "changedSincePlan"; stale = true
                    } else if request.forgetReceipts {
                        observation = "stillRegistered"; failed += 1
                    } else { observation = "retained" }
                } else {
                    observation = "absent"
                    if request.forgetReceipts { changed += 1 } else { stale = true }
                }
                receipts.append(.init(packageID: snapshot.packageID, observation: observation))
            }
            try await repository.validateReadSession()
        } catch { unknown = true; notes.append("Receipt verification unavailable: \(error.localizedDescription)") }
        if let directory = request.cltDirectory ?? (request.recipe == .clt ? CLTInspector.directory : nil) {
            switch await cache.observation(atPath: directory) {
            case .present: failed += 1; notes.append("CLT directory is still present. Unrecorded or retained items may remain.")
            case .unavailable: unknown = true; notes.append("CLT directory presence could not be verified.")
            case .missing: break
            }
        }
        if request.recipe == .clt, request.plan.entries.contains(where: { !$0.proposesRemoval && $0.reason != .alreadyMissing && $0.reason != .installationContainer }) {
            failed += 1; notes.append("Retained CLT payload prevents a complete uninstall result.")
        }
        if request.resetDeveloperSelection {
            if developerPath == nil { unknown = true; notes.append("Developer selection could not be read.") }
            else if developerPath != request.replacementDeveloperPath || request.replacementDeveloperPath == nil { failed += 1; notes.append("Developer selection does not match the reviewed full Xcode replacement.") }
        }
        if !request.resetDeveloperSelection, let expected = request.activeDeveloperPath,
           !(request.recipe == .clt && expected == CLTInspector.directory), developerPath != expected {
            stale = true
            notes.append("Developer selection changed after planning.")
        }
        if failed > 0 { notes.append("Expected postconditions are not met; this is not proof of a command's execution status.") }
        let outcome: CleanupVerificationReport.Outcome = stale ? .stale : (unknown ? .unknown :
            (failed > 0 ? (changed > 0 ? .partial : .failed) : .verified))
        return CleanupVerificationReport(request: request, outcome: outcome, paths: paths, receipts: receipts, notes: notes)
    }
}
