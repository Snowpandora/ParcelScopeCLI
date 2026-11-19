import Foundation
import Testing
@testable import ParcelScopeInspection
@testable import ParcelScopeExecution

struct CLTReviewPresentationTests {
    private func request() throws -> CleanupExecutionRequest {
        let receipts = try ["com.apple.pkg.CLTools_Executables", "com.apple.dt.commandlinetools"].map {
            ReceiptSnapshot(PackageReceipt(id: try PackageID($0), version: "synthetic", volume: "/", installLocation: "/", installTime: Date(timeIntervalSince1970: 1)))
        }
        return CleanupExecutionRequest(plan: CleanupEvidencePlan(volume: .init(mountPoint: "/", uuid: "synthetic", device: "1"), receipts: receipts, entries: [], isComplete: true), dryRun: false, forgetReceipts: true, recipe: .clt)
    }
    @Test func exactSortedReceiptsAreShownEvenWhenNoPathsHaveOwners() throws {
        let request = try request()
        #expect(request.plan.entries.isEmpty)
        #expect(CLTReviewPresentation.targetReceipts(request.plan.receipts) == "Target receipt IDs (2):\n  com.apple.dt.commandlinetools\n  com.apple.pkg.CLTools_Executables\n")
    }
    @Test func retryNamesRemainingReceiptWithoutCallingAbsentReceiptRemaining() throws {
        let request = try request()
        let report = CleanupVerificationReport(request: request, outcome: .partial, receipts: [
            .init(packageID: "com.apple.pkg.CLTools_Executables", observation: "absent"),
            .init(packageID: "com.apple.dt.commandlinetools", observation: "stillRegistered")
        ])
        let summary = CLTReviewPresentation.retrySummary(report)
        #expect(summary.contains("com.apple.dt.commandlinetools: stillRegistered"))
        #expect(!summary.contains("com.apple.pkg.CLTools_Executables"))
    }
    @Test func missingVerificationDoesNotImplyReceiptAbsence() throws {
        let report = CleanupVerificationReport(request: try request(), outcome: .unknown)
        let summary = CLTReviewPresentation.retrySummary(report)
        #expect(summary.contains("com.apple.dt.commandlinetools: unverified"))
        #expect(summary.contains("com.apple.pkg.CLTools_Executables: unverified"))
        #expect(!summary.contains("All target receipts were observed absent"))
    }
}
