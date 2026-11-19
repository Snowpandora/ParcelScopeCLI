import XCTest
import Foundation
@testable import ParcelScopeInspection
@testable import ParcelScopeExecution

final class CleanupVerifierTests: XCTestCase {
    let identity = CleanupVolumeIdentity(mountPoint: "/", uuid: "fixture", device: "1")
    func request(baseline: FileObservation = .present, removal: Bool = true, dryRun: Bool = false,
                 forget: Bool = false) throws -> CleanupExecutionRequest {
        let id = try PackageID("com.example.test")
        let receipt = PackageReceipt(id: id, version: "1", volume: "/", installLocation: "/", installTime: Date(timeIntervalSince1970: 1))
        let plan = CleanupEvidencePlan(volume: identity, receipts: [ReceiptSnapshot(receipt)], entries: [
            CleanupPathEvidence(path: "/usr/local/test", itemType: .file, owners: [id.rawValue], baseline: baseline,
                reason: removal ? .selectedReceiptOnly : .sharedOwnership)
        ], isComplete: true)
        return CleanupExecutionRequest(plan: plan, dryRun: dryRun, forgetReceipts: forget)
    }
    func testIncompleteCatalogCannotProveReceiptAbsence() async throws {
        let repo = PlanningRepository(ids: [], paths: [], owners: [])
        await repo.setCoverage(.partial)
        let report = await CleanupVerifier().verify(try request(forget: true), repository: repo, currentVolume: identity,
            cache: FileExistenceCache(observer: { _ in .missing }))
        XCTAssertEqual(report.outcome, .unknown)
        XCTAssertFalse(report.receipts.contains { $0.observation == "absent" })
    }
    func testFreshVerificationSeparatesNewAbsenceBaselineAbsenceAndRetained() async throws {
        let id = try PackageID("com.example.test")
        let repo = PlanningRepository(ids: [id], paths: [], owners: [id])
        let request = try request()
        let verifier = CleanupVerifier()
        let report = await verifier.verify(request, repository: repo, currentVolume: identity,
            cache: FileExistenceCache(observer: { _ in .missing }))
        XCTAssertEqual(report.outcome, .verified)
        XCTAssertEqual(report.paths.first?.outcome, .newlyAbsent)
        XCTAssertEqual(request.plan.entries.first?.baseline, .present)
        let absent = await verifier.verify(try self.request(baseline: .missing), repository: repo,
            currentVolume: identity, cache: FileExistenceCache(observer: { _ in .missing }))
        XCTAssertEqual(absent.paths.first?.outcome, .alreadyAbsent)
        let retained = await verifier.verify(try self.request(removal: false), repository: repo,
            currentVolume: identity, cache: FileExistenceCache(observer: { _ in .present }, typeObserver: { _ in .file }))
        XCTAssertEqual(retained.paths.first?.outcome, .retained)
        let decoded = try JSONDecoder().decode(CleanupVerificationReport.self, from: report.jsonData())
        XCTAssertEqual(decoded, report)
        XCTAssertTrue(report.summary.contains("newlyAbsent"))
    }
    func testUnknownStillPresentSimulationAndVolumeReplacementNeverSucceed() async throws {
        let id = try PackageID("com.example.test")
        let repo = PlanningRepository(ids: [id], paths: [], owners: [id])
        let request = try request()
        let verifier = CleanupVerifier()
        let unknown = await verifier.verify(request, repository: repo, currentVolume: identity,
            cache: FileExistenceCache(observer: { _ in .unavailable }))
        XCTAssertEqual(unknown.outcome, .unknown)
        let unchanged = await verifier.verify(request, repository: repo, currentVolume: identity,
            cache: FileExistenceCache(observer: { _ in .present }, typeObserver: { _ in .file }))
        XCTAssertEqual(unchanged.outcome, .failed)
        let replaced = await verifier.verify(request, repository: repo,
            currentVolume: CleanupVolumeIdentity(mountPoint: "/", uuid: "replacement", device: "1"))
        XCTAssertEqual(replaced.outcome, .stale)
        let simulation = await verifier.verify(try self.request(dryRun: true), repository: repo, currentVolume: identity)
        XCTAssertEqual(simulation.outcome, .simulation)
    }
    func testReceiptStillRegisteredCannotVerifyForget() async throws {
        let id = try PackageID("com.example.test")
        let repo = PlanningRepository(ids: [id], paths: [], owners: [id])
        let report = await CleanupVerifier().verify(try request(forget: true), repository: repo,
            currentVolume: identity, cache: FileExistenceCache(observer: { _ in .missing }))
        XCTAssertEqual(report.outcome, .partial)
        XCTAssertEqual(report.receipts.first?.observation, "stillRegistered")
    }
}

extension CleanupVerifierTests {
    func testRetainedDirectoryReplacedWithFileCannotVerifyCleanup() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("shared")
        let child = directory.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data().write(to: child)
        let id = try PackageID("com.example.test")
        let base = try request()
        let plan = CleanupEvidencePlan(volume: identity, receipts: base.plan.receipts, entries: [
            CleanupPathEvidence(path: directory.path, itemType: .directory, owners: [id.rawValue, "com.example.other"], baseline: .present, reason: .sharedOwnership),
            CleanupPathEvidence(path: child.path, itemType: .file, owners: [id.rawValue], baseline: .present, reason: .selectedReceiptOnly)
        ], isComplete: true)
        try FileManager.default.removeItem(at: directory)
        try Data("replacement".utf8).write(to: directory)
        let repo = PlanningRepository(ids: [], paths: [], owners: [])
        let report = await CleanupVerifier().verify(CleanupExecutionRequest(plan: plan, dryRun: false, forgetReceipts: true), repository: repo, currentVolume: identity)
        XCTAssertNotEqual(report.outcome, .verified)
        XCTAssertFalse(report.paths.contains { $0.path == directory.path && $0.outcome == .retained })
        XCTAssertFalse(report.paths.contains { $0.path == child.path && $0.outcome == .newlyAbsent })
    }

    func testSymlinkAncestorCannotProveChildAbsence() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("container")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let id = try PackageID("com.example.test")
        let base = try request()
        let plan = CleanupEvidencePlan(volume: identity, receipts: base.plan.receipts, entries: [
            CleanupPathEvidence(path: directory.appendingPathComponent("child").path, itemType: .file, owners: [id.rawValue], baseline: .present, reason: .selectedReceiptOnly)
        ], isComplete: true)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: root.appendingPathComponent("missing"))
        let report = await CleanupVerifier().verify(CleanupExecutionRequest(plan: plan, dryRun: false, forgetReceipts: true), repository: PlanningRepository(ids: [], paths: [], owners: []), currentVolume: identity)
        XCTAssertNotEqual(report.outcome, .verified)
    }

    func testPartialUnknownStaleAndCancelledVerificationRemainDistinct() async throws {
        let id = try PackageID("com.example.test")
        let repo = PlanningRepository(ids: [id], paths: [], owners: [id])
        let base = try request()
        let second = CleanupPathEvidence(path: "/usr/local/second", itemType: .file, owners: [id.rawValue], baseline: .present, reason: .selectedReceiptOnly)
        let plan = CleanupEvidencePlan(volume: identity, receipts: base.plan.receipts, entries: base.plan.entries + [second], isComplete: true)
        let frozen = CleanupExecutionRequest(plan: plan, dryRun: false)
        let partial = await CleanupVerifier().verify(frozen, repository: repo, currentVolume: identity,
            cache: FileExistenceCache(observer: { $0.hasSuffix("second") ? .present : .missing }, typeObserver: { _ in .file }))
        XCTAssertEqual(partial.outcome, .partial)
        let unknown = await CleanupVerifier().verify(frozen, repository: repo, currentVolume: identity,
            cache: FileExistenceCache(observer: { $0.hasSuffix("second") ? .unavailable : .missing }))
        XCTAssertEqual(unknown.outcome, .unknown)
        let changedReceipt = PackageReceipt(id: id, version: "2", volume: "/", installLocation: "/", installTime: Date(timeIntervalSince1970: 1))
        let changed = CleanupEvidencePlan(volume: identity, receipts: [ReceiptSnapshot(changedReceipt)], entries: [], isComplete: true)
        let stale = await CleanupVerifier().verify(CleanupExecutionRequest(plan: changed, dryRun: false), repository: repo, currentVolume: identity)
        XCTAssertEqual(stale.outcome, .stale)
        let identity = identity
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await CleanupVerifier().verify(frozen, repository: repo, currentVolume: identity)
        }
        let cancelled = await task.value
        XCTAssertEqual(cancelled.outcome, .unknown)
    }
}

extension CleanupVerifierTests {
    func testInstallationContainersMustBePreservedButDoNotPreventVerification() async throws {
        let id = try PackageID("com.apple.pkg.CLTools_Executables")
        let repo = PlanningRepository(ids: [id], paths: ["Library", "Library/Developer"],
            directories: ["Library", "Library/Developer"], owners: [id])
        let plan = try await CleanupPlanBuilder().build(targets: [id], repository: repo, volume: identity,
            cache: FileExistenceCache(observer: { _ in .present }))
        let frozen = CleanupExecutionRequest(plan: plan, dryRun: false, cltDirectory: CLTInspector.directory,
            activeDeveloperPath: "/Applications/Xcode.app/Contents/Developer")
        let kept = await CleanupVerifier().verify(frozen, repository: repo, currentVolume: identity,
            cache: FileExistenceCache(observer: { $0 == CLTInspector.directory ? .missing : .present }),
            developerPath: frozen.activeDeveloperPath)
        XCTAssertEqual(kept.outcome, .verified)
        let missing = await CleanupVerifier().verify(frozen, repository: repo, currentVolume: identity,
            cache: FileExistenceCache(observer: { _ in .missing }), developerPath: frozen.activeDeveloperPath)
        XCTAssertNotEqual(missing.outcome, .verified)
    }
}
