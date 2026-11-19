import Foundation
import XCTest
@testable import ParcelScopeInspection
@testable import ParcelScopeExecution

final class CLTInspectorTests: XCTestCase {
    func testRecognizesExactStandaloneSDKAndBackDeploymentReceipts() {
        for id in ["com.apple.pkg.CLTools_SDK_macOS_NMOS", "com.apple.pkg.CLTools_SDK_macOS_LMOS", "com.apple.pkg.CLTools_SwiftBackDeploy"] {
            XCTAssertTrue(CLTInspector.isCLTReceipt(id), id)
        }
        for id in ["com.apple.pkg.CLTools_SDK_macOS_NMOS_extra", "com.apple.pkg.CLTools_SwiftBackDeployFake"] {
            XCTAssertFalse(CLTInspector.isCLTReceipt(id), id)
        }
    }
    func testDynamicDiscoveryIncludesNewSDKButExcludesFullXcode() async throws {
        let ids = try ["com.apple.dt.commandlinetools", "com.apple.dt.commandlinetools.other",
            "com.apple.pkg.CLTools_SDK_macOS99", "com.apple.pkg.CLTools_Executables",
            "com.apple.pkg.XcodeSystemResources", "com.apple.pkg.CLToolsOther", "com.example.Xcode"].map { try PackageID($0) }
        let repo = PlanningRepository(ids: ids, paths: [], owners: [])
        let environment = CLTEnvironment(directory: .present, activeDeveloperPath: "/Applications/Xcode.app/Contents/Developer", compilerAvailable: true)
        let result = try await CLTInspector().inspect(repository: repo, volume: "/", environment: environment)
        XCTAssertEqual(result.receiptIDs.map(\.rawValue), ["com.apple.dt.commandlinetools", "com.apple.pkg.CLTools_Executables", "com.apple.pkg.CLTools_SDK_macOS99"])
        XCTAssertFalse(result.hasInconsistency)
        XCTAssertEqual(result.environment.activeDeveloperPath, environment.activeDeveloperPath)
    }
    func testReceiptAndDirectoryPresenceAreNotDamageDiagnosis() async throws {
        let id = try PackageID("com.apple.pkg.CLTools_Executables")
        for presence in [FileObservation.present, .missing, .unavailable] {
            let repo = PlanningRepository(ids: [id], paths: [], owners: [])
            let result = try await CLTInspector().inspect(repository: repo, volume: "/Volumes/External",
                environment: CLTEnvironment(directory: presence, activeDeveloperPath: nil, compilerAvailable: nil))
            XCTAssertNotNil(result.warning)
            XCTAssertEqual(result.hasInconsistency, presence == .missing)
        }
    }
    func testNoReceiptsDirectoryOnlyAndMissingEnvironmentStayNondiagnostic() async throws {
        let repo = PlanningRepository(ids: [], paths: [], owners: [])
        for directory in [FileObservation.present, .missing, .unavailable] {
            let result = try await CLTInspector().inspect(repository: repo, volume: "/",
                environment: CLTEnvironment(directory: directory, activeDeveloperPath: nil, compilerAvailable: nil))
            XCTAssertTrue(result.receiptIDs.isEmpty)
            XCTAssertFalse(result.hasInconsistency)
        }
        XCTAssertFalse(CLTInspector.isCLTReceipt("com.apple.pkg.CLTools_SDK_macOSinvalid"))
    }

}

private struct ReadOnlyDeveloperLookup: ProcessExecuting {
    let developerPath: String
    func run(path: String, arguments: [String], timeout: TimeInterval) async throws -> ProcessRunner.ProcessResult {
        if path == "/usr/bin/xcode-select" {
            return .init(terminationStatus: 0, stdout: Data((developerPath + "\n").utf8), stderr: Data())
        }
        XCTFail("Unexpected executable during inspection: \(path)")
        throw ProcessRunner.ProcessError.nonZeroExitCode(72, "Unexpected executable")
    }
}

extension CLTInspectorTests {
    func testInspectionOnlyUsesAnExistingExecutableCandidate() async {
        let candidate = CLTInspector.directory + "/usr/bin/clang"
        let result = await CLTInspector.environment(runner: ReadOnlyDeveloperLookup(developerPath: CLTInspector.directory),
            observe: { _ in .present }, isExecutable: { $0 == candidate })
        XCTAssertEqual(result.compilerAvailable, true)
        for observation in [FileObservation.missing, .unavailable] {
            let missing = await CLTInspector.environment(runner: ReadOnlyDeveloperLookup(developerPath: CLTInspector.directory),
                observe: { _ in observation }, isExecutable: { _ in true })
            XCTAssertNotEqual(missing.compilerAvailable, true)
        }
        let invalid = await CLTInspector.environment(runner: ReadOnlyDeveloperLookup(developerPath: "/private/tmp/unvalidated.app/Contents/Developer"),
            observe: { _ in .present }, isExecutable: { _ in true })
        XCTAssertNotEqual(invalid.compilerAvailable, true)
    }
}

extension CLTInspectorTests {
    func testInspectionCanReadAValidatedFullXcodeCandidate() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("parcelscope-compiler-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let developer = root.appendingPathComponent("Synthetic Xcode.app/Contents/Developer")
        for child in ["usr/bin", "Toolchains/XcodeDefault.xctoolchain/usr/bin", "Platforms"] {
            try FileManager.default.createDirectory(at: developer.appendingPathComponent(child), withIntermediateDirectories: true)
        }
        for child in ["usr/bin/xcodebuild", "Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"] {
            let file = developer.appendingPathComponent(child)
            try Data("#!/bin/bash\nexit 0\n".utf8).write(to: file)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: file.path)
        }
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.apple.dt.Xcode"], format: .xml, options: 0)
            .write(to: developer.deletingLastPathComponent().appendingPathComponent("Info.plist"))
        XCTAssertTrue(CLTInspector.isValidatedFullXcodeDeveloperPath(developer.path))
        let resolved = await CLTInspector.environment(runner: ReadOnlyDeveloperLookup(developerPath: developer.path))
        XCTAssertEqual(resolved.compilerAvailable, true)
        let unavailable = await CLTInspector.environment(runner: ReadOnlyDeveloperLookup(developerPath: developer.path),
            observe: { _ in .unavailable })
        XCTAssertNotEqual(unavailable.compilerAvailable, true)
        let notExecutable = await CLTInspector.environment(runner: ReadOnlyDeveloperLookup(developerPath: CLTInspector.directory),
            observe: { _ in .present }, isExecutable: { _ in false })
        XCTAssertNotEqual(notExecutable.compilerAvailable, true)
    }
}
