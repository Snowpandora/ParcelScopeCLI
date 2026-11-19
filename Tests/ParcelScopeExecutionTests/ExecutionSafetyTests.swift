import Foundation
import Testing
import ParcelScopeInspection
@testable import ParcelScopeExecution

@Suite struct ExecutionSafetyTests {
    private func request(retained: Bool = false) throws -> CleanupExecutionRequest {
        let volume = CleanupVolumeIdentity(mountPoint: "/", uuid: "synthetic", device: "1")
        let receipt = PackageReceipt(id: try PackageID("com.apple.pkg.CLTools_Executables"), version: "1.0-synthetic", volume: "/", installLocation: "/", installTime: Date(timeIntervalSince1970: 1))
        let record = ReceiptOwnershipEvidence.Record(receipt: ReceiptSnapshot(receipt), filesSHA256: String(repeating: "0", count: 64))
        let entries = [CleanupPathEvidence(path: CLTInspector.directory, itemType: .directory, owners: [], baseline: .missing, reason: .alreadyMissing)] + (retained ? [CleanupPathEvidence(path: CLTInspector.directory + "/synthetic", itemType: .file, owners: [], baseline: .present, reason: .sharedOwnership)] : [])
        let plan = CleanupEvidencePlan(volume: volume, receipts: [ReceiptSnapshot(receipt)], entries: entries, isComplete: true, ownershipEvidence: .init(volume: volume, records: [record]))
        return CleanupExecutionRequest(plan: plan, dryRun: false, forgetReceipts: true, cltDirectory: CLTInspector.directory, recipe: .clt)
    }
    @Test func retainedPayloadBlocksReceiptRemoval() throws {
        let request = try request(retained: true)
        #expect(throws: (any Error).self) { try ValidatedCleanupScriptExporter().generate(request, currentVolume: request.plan.volume) }
    }
    @Test func standaloneScriptHasNoGUIHandoffAndForgetsOnlyCLT() throws {
        let request = try request()
        let script = try ValidatedCleanupScriptExporter().generate(request, currentVolume: request.plan.volume)
        #expect(!script.contains("parcelscope://"))
        #expect(!script.contains("/usr/bin/open"))
        #expect(!script.contains("rm -rf"))
        #expect(script.contains("--forget 'com.apple.pkg.CLTools_Executables'"))
        #expect(script.contains("Type REMOVE"))
    }
    @Test func changedVolumeBlocksExecution() throws {
        let request = try request()
        #expect(throws: (any Error).self) { try ValidatedCleanupScriptExporter().generate(request, currentVolume: .init(mountPoint: "/", uuid: "other", device: "1")) }
    }
}
