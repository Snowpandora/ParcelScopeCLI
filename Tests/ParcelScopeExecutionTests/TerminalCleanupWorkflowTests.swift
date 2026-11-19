import Foundation
import Darwin
import Testing
@testable import ParcelScopeInspection
@testable import ParcelScopeExecution

struct TerminalCleanupWorkflowTests {
    private let volume = CleanupVolumeIdentity.capture("/")
    private let environment = CLTEnvironment(directory: .present,
        activeDeveloperPath: CLTInspector.directory, compilerAvailable: true)

    @Test(arguments: [false, true])
    func presentLegacySDKFileRequiresExactlyTheFourSDKReceipts(_ hasUnrelatedOwner: Bool) async throws {
        let leaf = "/private/tmp/." + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
        let descriptor = open(leaf, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        try #require(descriptor >= 0)
        close(descriptor)
        defer { try? FileManager.default.removeItem(atPath: leaf) }

        let selected = try ["110", "12", "13", "14"].map { try PackageID("com.apple.pkg.CLTools_SDK_macOS" + $0) }
        let repository = PackageRepositoryImpl(client: LegacySDKReceiptClient(
            selected: selected, leaf: leaf, hasUnrelatedOwner: hasUnrelatedOwner))
        let ownership = try #require(try await repository.fetchOwnershipEvidence(paths: []).evidence)
        let seed = CLTReviewInputs(id: UUID(), createdAt: Date(), volume: volume,
            receipts: ownership.records.map(\.receipt).filter { record in selected.contains { $0.rawValue == record.packageID } },
            ownershipEvidence: ownership, activeDeveloperPath: environment.activeDeveloperPath,
            replacementDeveloperPath: nil, dryRun: false)
        let workflow = TerminalCleanupWorkflow()
        if hasUnrelatedOwner {
            await #expect(throws: ValidatedCleanupScriptExporter.ExportError.retainedPayload) {
                _ = try await workflow.makeRequest(inputs: seed, repository: repository, environment: environment)
            }
            return
        }

        let request = try await workflow.makeRequest(inputs: seed, repository: repository, environment: environment)
        let marker = try #require(request.plan.entries.first { $0.path == leaf })
        #expect(marker.proposesRemoval)
        #expect(Set(marker.owners) == Set(selected.map(\.rawValue)))
        #expect(!request.plan.entries.contains { ["/private", "/private/tmp"].contains($0.path) && $0.proposesRemoval })
        let exporter = ValidatedCleanupScriptExporter()
        #expect(throws: ValidatedCleanupScriptExporter.ExportError.unavailable) {
            try exporter.generate(request, currentVolume: volume)
        }
        let script = try exporter.generate(request, currentVolume: volume,
            terminalVerification: .init(executablePath: "/var/fixture-verifier", requestPath: "/var/fixture-request"))
        #expect(script.contains(leaf))
        #expect(script.contains("0:0:1"))
        // The real launcher creates its private review and preflight directories after planning.
        let reviewDirectory = "/private/tmp/parcelscope-test-review." + UUID().uuidString
        try await Task.sleep(for: .seconds(1.1))
        try FileManager.default.createDirectory(atPath: reviewDirectory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(atPath: reviewDirectory) }
        try await workflow.revalidate(request, repository: repository, environment: environment, currentVolume: volume)
        let alias = leaf + "-link"
        try FileManager.default.linkItem(atPath: leaf, toPath: alias)
        defer { try? FileManager.default.removeItem(atPath: alias) }
        await #expect(throws: (any Error).self) {
            try await workflow.revalidate(request, repository: repository, environment: environment, currentVolume: volume)
        }
    }

    @Test func reviewPreservesIdentityAndRevalidatesWithFreshContext() async throws {
        let fixture = try TerminalWorkflowFixture()
        defer { fixture.remove() }
        let repository = fixture.repository()
        let seed = try await fixture.seed(repository: repository, dryRun: false, replacement: fixture.xcodePath)
        let request = try await TerminalCleanupWorkflow().makeRequest(inputs: seed,
            repository: repository, environment: environment)
        #expect(request.id == seed.id)
        #expect(request.recipe == .clt)
        #expect(request.forgetReceipts)
        #expect(request.resetDeveloperSelection)
        #expect(!request.dryRun)
        try await TerminalCleanupWorkflow().revalidate(request, repository: repository,
            environment: environment, currentVolume: volume)
        #expect(try Data(contentsOf: fixture.payload) == Data("preserve".utf8))
    }

    @Test func changedParentAliasRejectsReviewDespiteUnchangedInventoriesAndTarget() async throws {
        let fixture = try TerminalWorkflowFixture()
        defer { fixture.remove() }
        let repository = fixture.repository()
        let seed = try await fixture.seed(repository: repository, dryRun: false, replacement: fixture.xcodePath)
        let request = try await TerminalCleanupWorkflow().makeRequest(inputs: seed,
            repository: repository, environment: environment)
        let fingerprint = FileExistenceCache.fingerprint(fixture.payload.path)
        try FileManager.default.removeItem(at: fixture.alias)
        try FileManager.default.createSymbolicLink(at: fixture.alias, withDestinationURL: fixture.payload.deletingLastPathComponent())
        let updated = try await repository.fetchOwnershipEvidence(paths: [fixture.selectedPath])
        #expect(updated.evidence?.records == seed.ownershipEvidence.records)
        #expect(updated.evidence?.catalogSHA256 == seed.ownershipEvidence.catalogSHA256)
        #expect(FileExistenceCache.fingerprint(fixture.payload.path) == fingerprint)
        await #expect(throws: (any Error).self) {
            try await TerminalCleanupWorkflow().revalidate(request, repository: repository,
                environment: environment, currentVolume: volume)
        }
    }

    @Test(arguments: [-1.0, 1_801.0])
    func futureOrExpiredSeedCannotBecomeRequest(_ elapsed: Double) async throws {
        let fixture = try TerminalWorkflowFixture()
        defer { fixture.remove() }
        let repository = fixture.repository()
        let seed = try await fixture.seed(repository: repository)
        await #expect(throws: (any Error).self) {
            _ = try await TerminalCleanupWorkflow().makeRequest(inputs: seed, repository: repository,
                environment: environment, now: seed.createdAt.addingTimeInterval(elapsed))
        }
    }

    @Test func standaloneUninstallDoesNotRequireFullXcode() async throws {
        let fixture = try TerminalWorkflowFixture()
        defer { fixture.remove() }
        let repository = fixture.repository()
        let seed = try await fixture.seed(repository: repository, dryRun: false)
        let noCompiler = CLTEnvironment(directory: .present,
            activeDeveloperPath: CLTInspector.directory, compilerAvailable: nil)
        let workflow = TerminalCleanupWorkflow()
        let request = try await workflow.makeRequest(inputs: seed, repository: repository, environment: noCompiler)
        #expect(request.forgetReceipts)
        #expect(!request.resetDeveloperSelection)
        #expect(request.replacementDeveloperPath == nil)
        let script = try ValidatedCleanupScriptExporter().generate(request, currentVolume: volume)
        #expect(!script.contains("--switch"))
        #expect(!script.contains("/usr/bin/xcrun"))
        try await workflow.revalidate(request, repository: repository, environment: noCompiler, currentVolume: volume)
    }

    @Test func forgedOptionsAndChangedDeveloperSelectionAreRejected() async throws {
        let fixture = try TerminalWorkflowFixture()
        defer { fixture.remove() }
        let repository = fixture.repository()
        let seed = try await fixture.seed(repository: repository, dryRun: false, replacement: fixture.xcodePath)
        let request = try await TerminalCleanupWorkflow().makeRequest(inputs: seed,
            repository: repository, environment: environment)
        let forged = CleanupExecutionRequest(plan: request.plan, dryRun: true, forgetReceipts: false,
            resetDeveloperSelection: request.resetDeveloperSelection, cltDirectory: CLTInspector.directory,
            activeDeveloperPath: request.activeDeveloperPath, recipe: .clt)
        await #expect(throws: (any Error).self) {
            try await TerminalCleanupWorkflow().revalidate(forged, repository: repository,
                environment: environment, currentVolume: volume)
        }
        let changed = CLTEnvironment(directory: .present, activeDeveloperPath: nil, compilerAvailable: nil)
        await #expect(throws: (any Error).self) {
            try await TerminalCleanupWorkflow().revalidate(request, repository: repository,
                environment: changed, currentVolume: volume)
        }
    }
}

private struct LegacySDKReceiptClient: PkgutilClient {
    let selected: [PackageID]
    let leaf: String
    let hasUnrelatedOwner: Bool
    private let unrelated = try! PackageID("com.example.unrelated")

    func listPackages() async throws -> [PackageID] { selected + [unrelated] }
    func listGroups() async throws -> [String] { [] }
    func listPackages(inGroup groupID: String) async throws -> [PackageID] { [] }
    func getPackageInfo(for id: PackageID) async throws -> PackageReceipt {
        PackageReceipt(id: id, version: "1", volume: "/", installLocation: "/", installTime: Date(timeIntervalSince1970: 1))
    }
    func getFiles(for id: PackageID) async throws -> [ReceiptFile] { try await getFiles(for: id, filter: .all) }
    func getFiles(for id: PackageID, filter: ReceiptFileFilter) async throws -> [ReceiptFile] {
        let marker = id == unrelated && hasUnrelatedOwner ? "tmp/" + (leaf as NSString).lastPathComponent : String(leaf.dropFirst())
        let directories = id == unrelated ? [] : ["private", "private/tmp"]
        let files = id == unrelated && !hasUnrelatedOwner ? [] : [marker]
        return (filter == .onlyFiles ? files : filter == .onlyDirectories ? directories : directories + files)
            .map(ReceiptFile.init)
    }
    func reverseLookup(path: String) async throws -> FileLookupResult {
        throw ReceiptReadError.invalidOutput("Use the complete ownership index.")
    }

}

private struct TerminalWorkflowFixture {
    let root: URL
    let payload: URL
    let alias: URL
    let selectedPath: String
    var xcodePath: String { root.appendingPathComponent("Xcode.app/Contents/Developer").path }
    let selected = try! PackageID("com.apple.pkg.CLTools_Executables")
    let retained = try! PackageID("com.example.retained")

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        let selectedFolder = root.appendingPathComponent("selected")
        let otherFolder = root.appendingPathComponent("other")
        let leaf = UUID().uuidString
        payload = selectedFolder.appendingPathComponent(leaf)
        alias = root.appendingPathComponent("alias")
        selectedPath = CLTInspector.directory + "/" + leaf
        try FileManager.default.createDirectory(at: selectedFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: otherFolder, withIntermediateDirectories: true)
        try Data("preserve".utf8).write(to: payload)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: otherFolder)
        let developer = root.appendingPathComponent("Xcode.app/Contents/Developer")
        for executable in ["usr/bin/xcodebuild", "Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"] {
            let url = developer.appendingPathComponent(executable)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        try FileManager.default.createDirectory(at: developer.appendingPathComponent("Platforms"), withIntermediateDirectories: true)
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.apple.dt.Xcode"], format: .xml, options: 0)
        try plist.write(to: developer.deletingLastPathComponent().appendingPathComponent("Info.plist"))
    }
    func remove() { try? FileManager.default.removeItem(at: root) }
    func repository() -> PackageRepositoryImpl {
        let selectedPath = selectedPath, payloadPath = payload.path
        return PackageRepositoryImpl(client: AliasReceiptClient(selected: selected, retained: retained,
            selectedPath: selectedPath, retainedPath: alias.appendingPathComponent(payload.lastPathComponent).path),
            observeObject: { path in
                if path == selectedPath { return try OwnershipObject.inspect(payloadPath) }
                if path == CLTInspector.directory {
                    return try OwnershipObject.inspect((payloadPath as NSString).deletingLastPathComponent)
                }
                return try OwnershipObject.inspect(path)
            })
    }
    func seed(repository: any PackageRepository, dryRun: Bool = true, replacement: String? = nil) async throws -> CLTReviewInputs {
        let evidence = try #require(try await repository.fetchOwnershipEvidence(paths: [selectedPath]).evidence)
        return CLTReviewInputs(id: UUID(), createdAt: Date(), volume: .capture("/"),
            receipts: [ReceiptSnapshot(try await repository.fetchDetails(for: selected))],
            ownershipEvidence: evidence, activeDeveloperPath: CLTInspector.directory,
            replacementDeveloperPath: replacement, dryRun: dryRun)
    }
}
