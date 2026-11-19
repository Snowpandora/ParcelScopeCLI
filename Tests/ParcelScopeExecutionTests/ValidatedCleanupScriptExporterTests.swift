import XCTest
import Foundation
@testable import ParcelScopeInspection
@testable import ParcelScopeExecution

final class ValidatedCleanupScriptExporterTests: XCTestCase {
    private var syntheticXcodeRoots: [URL] = []
    override func tearDownWithError() throws {
        for root in syntheticXcodeRoots { try FileManager.default.removeItem(at: root) }
        syntheticXcodeRoots = []
        try super.tearDownWithError()
    }
    func fullXcodeDeveloperPath() throws -> String {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("parcelscope-xcode-" + UUID().uuidString)
        syntheticXcodeRoots.append(root)
        let developer = root.appendingPathComponent("Preserved Xcode.app/Contents/Developer")
        for child in ["usr/bin", "Toolchains/XcodeDefault.xctoolchain/usr/bin", "Platforms"] {
            try FileManager.default.createDirectory(at: developer.appendingPathComponent(child), withIntermediateDirectories: true)
        }
        for child in ["usr/bin/xcodebuild", "Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"] {
            let executable = developer.appendingPathComponent(child)
            try Data("#!/bin/bash\nexit 0\n".utf8).write(to: executable)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        }
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.apple.dt.Xcode"], format: .xml, options: 0)
            .write(to: developer.deletingLastPathComponent().appendingPathComponent("Info.plist"))
        return developer.path
    }
    let identity = CleanupVolumeIdentity(mountPoint: "/", uuid: "fixture-volume", device: "1")
    func request(dryRun: Bool = false, date: Date = Date(), clt: Bool = false) throws -> CleanupExecutionRequest {
        let id = try PackageID(clt ? "com.apple.pkg.CLTools_Executables" : "com.example.test")
        let receipt = PackageReceipt(id: id, version: "1", volume: "/", installLocation: "/", installTime: Date(timeIntervalSince1970: 1))
        let path = clt ? CLTInspector.directory + "/tool" : "/usr/local/test'$(printf marker)"
        let plan = CleanupEvidencePlan(generatedAt: date, volume: identity, receipts: [ReceiptSnapshot(receipt)], entries: [
            CleanupPathEvidence(path: path, itemType: .file, owners: [id.rawValue], baseline: .present, reason: .selectedReceiptOnly, fingerprint: "1:1:1:1:100644")
        ], isComplete: true)
        var developerPath: String?
        if clt { developerPath = try fullXcodeDeveloperPath() }
        return CleanupExecutionRequest(plan: plan, dryRun: dryRun, forgetReceipts: true,
            cltDirectory: clt ? CLTInspector.directory : nil, activeDeveloperPath: developerPath)
    }
    func testLegacyPlanRemainsReadableButCannotExecute() throws {
        let base = try request()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(base)) as? [String: Any])
        var plan = try XCTUnwrap(object["plan"] as? [String: Any])
        plan["schemaVersion"] = 1
        object["plan"] = plan
        let decoded = try JSONDecoder().decode(CleanupExecutionRequest.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertThrowsError(try ValidatedCleanupScriptExporter().generate(decoded, currentVolume: identity))
    }
    func testSimulationContainsNoMutationOrPrivilegeCommands() throws {
        let script = try ValidatedCleanupScriptExporter().generate(request(dryRun: true), currentVolume: identity)
        for command in ["rm -f", "rmdir ", "--forget", "sudo ", "xcode-select --reset", "pkill"] { XCTAssertFalse(script.contains(command), command) }
        XCTAssertTrue(script.contains("DRY-RUN"))
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/bash"); process.arguments = ["-c", script]
        try process.run(); process.waitUntilExit(); XCTAssertEqual(process.terminationStatus, 0)
    }
    func testExecutionIncludesFreshnessVolumeReceiptAndOwnershipPreflight() throws {
        let script = try ValidatedCleanupScriptExporter().generate(request(clt: true), currentVolume: identity)
        XCTAssertTrue(script.contains("VolumeUUID"))
        XCTAssertTrue(script.contains("--pkg-info-plist"))
        XCTAssertTrue(script.contains("--file-info-plist"))
        XCTAssertTrue(script.contains("plan_expiry"))
        XCTAssertFalse(script.contains("rm -rf"))
        XCTAssertFalse(script.contains("pkill"))
        XCTAssertTrue(script.contains("trap"))
        XCTAssertFalse(script.contains("parcelscope://nuke-complete"))
    }
    func testStaleChangedVolumeAndExternalExecutionAreRejected() throws {
        XCTAssertThrowsError(try ValidatedCleanupScriptExporter().generate(request(date: Date(timeIntervalSinceNow: -1_801)), currentVolume: identity))
        XCTAssertThrowsError(try ValidatedCleanupScriptExporter().generate(request(), currentVolume:
            CleanupVolumeIdentity(mountPoint: "/", uuid: "replacement", device: "1")))
    }
}

private struct ScriptFixture {
    let directory: URL
    let file: URL
    let tools: CleanupScriptTools
    let request: CleanupExecutionRequest
    init() throws {
        directory = URL(fileURLWithPath: "/private/tmp").appendingPathComponent("parcelscope-fixture-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        file = directory.appendingPathComponent("literal'$(printf unsafe)`printf unsafe`\nfile")
        try Data("keep until confirmed".utf8).write(to: file)
        let id = try PackageID("com.example.fixture")
        let receipt = PackageReceipt(id: id, version: "1", volume: "/", installLocation: "/", installTime: Date(timeIntervalSince1970: 1))
        let plan = CleanupEvidencePlan(volume: CleanupVolumeIdentity(mountPoint: "/", uuid: "fixture-volume", device: "1"), receipts: [ReceiptSnapshot(receipt)], entries: [
            CleanupPathEvidence(path: file.path, itemType: .file, owners: [id.rawValue], baseline: .present,
                reason: .selectedReceiptOnly, fingerprint: FileExistenceCache.fingerprint(file.path))
        ], isComplete: true)
        request = CleanupExecutionRequest(plan: plan, dryRun: false, forgetReceipts: true)
        let plist: [String: Any] = ["pkg-version": "1", "install-time": 1, "install-location": "/"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: directory.appendingPathComponent("receipt.plist"))
        try PropertyListSerialization.data(fromPropertyList: ["VolumeUUID": "fixture-volume"], format: .xml, options: 0).write(to: directory.appendingPathComponent("volume.plist"))
        try PropertyListSerialization.data(fromPropertyList: ["path": file.path, "path-info": [["pkgid": id.rawValue]]], format: .xml, options: 0).write(to: directory.appendingPathComponent("owners.plist"))
        let root = directory
        let prefix = ShellLiteral.quote(root.path)
        func tool(_ name: String, _ content: String) throws -> String {
            let url = root.appendingPathComponent(name)
            try ("#!/bin/bash\nset -euo pipefail\nbase=" + prefix + "\n" + content + "\n").write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
            return url.path
        }
        var commands = CleanupScriptTools()
        commands.id = try tool("id", "printf '%s\\n' 0")
        commands.diskutil = try tool("diskutil", "/bin/cat \"$base/volume.plist\"")
        commands.stat = try tool("stat", "if [[ ${*: -1} == / ]]; then printf '%s\\n' 1; else /usr/bin/stat \"$@\"; fi")
        commands.pkgutil = try tool("pkgutil", """
        case "$1" in
          --pkg-info-plist) /bin/cat "$base/receipt.plist" ;;
          --pkgs)
            if [[ -f "$base/forgotten-ids" ]]; then
              /usr/bin/grep -Fvx -f "$base/forgotten-ids" "$base/catalog" || [[ $? == 1 ]]
            else /bin/cat "$base/catalog"; fi
            ;;
          --files) [[ ! -f "$base/fail-files" ]] || exit 7; if [[ $2 == com.example.other ]]; then /bin/cat "$base/inventory-other"; else /bin/cat "$base/inventory"; fi ;;
          --file-info-plist) [[ ! -f "$base/bulk-only" ]] || exit 9; /bin/cat "$base/owners.plist" ;;
          --forget)
            if [[ -f "$base/fail-forget" ]]; then exit 7; fi
            /usr/bin/touch "$base/forgotten"
            if [[ ! -f "$base/forget-noop" ]]; then printf '%s\\n' "$2" >> "$base/forgotten-ids"; fi
            ;;
          *) exit 9 ;;
        esac
        """)
        commands.xcrun = try tool("xcrun", """
        if [[ -f "$base/fail-xcrun" ]]; then printf '%s\\n' 'Xcode license has not been accepted.' >&2; exit 69; fi
        if [[ -f "$base/wrong-xcrun" ]]; then printf '%s\\n' '/Applications/Other.app/Contents/Developer/clang'; exit 0; fi
        [[ $1 == --find && $2 == clang && -n ${DEVELOPER_DIR:-} ]] || exit 9
        printf '%s\\n' "$DEVELOPER_DIR/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
        """)
        tools = commands
    }
    func run(_ script: String, confirmation: String = "REMOVE\n") throws -> (Int32, String) {
        let process = Process(), output = Pipe(), input = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/bash"); process.arguments = ["-c", script]
        process.standardOutput = output; process.standardError = output; process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data(confirmation.utf8)); try input.fileHandleForWriting.close()
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

extension ValidatedCleanupScriptExporterTests {
    func testMissingPayloadAccessRevocationBlocksReceiptRemoval() throws {
        let fixture = try ScriptFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let parent = fixture.directory.appendingPathComponent("revoked")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let path = parent.appendingPathComponent("missing").path
        let plan = CleanupEvidencePlan(volume: fixture.request.plan.volume, receipts: fixture.request.plan.receipts,
            entries: [CleanupPathEvidence(path: path, itemType: .file, owners: ["com.example.fixture"], baseline: .missing, reason: .alreadyMissing)], isComplete: true)
        let script = try ValidatedCleanupScriptExporter(tools: fixture.tools).generate(
            .init(plan: plan, dryRun: false, forgetReceipts: true), currentVolume: plan.volume)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: parent.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: parent.path) }
        XCTAssertEqual(FileExistenceCache.inspect(path), .unavailable)
        let (status, output) = try fixture.run(script)
        XCTAssertNotEqual(status, 0, output)
        XCTAssertEqual(FileExistenceCache.inspect(fixture.directory.appendingPathComponent("forgotten").path), .missing)
    }

    func testRecreatedPreviouslyMissingCLTRootIsPreservedBeforeReceiptRemoval() throws {
        let fixture = try ScriptFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let container = fixture.directory.appendingPathComponent("recreated-clt")
        let id = try PackageID("com.apple.pkg.CLTools_Executables")
        let receipt = PackageReceipt(id: id, version: "1", volume: "/", installLocation: "/", installTime: Date(timeIntervalSince1970: 1))
        let plan = CleanupEvidencePlan(volume: fixture.request.plan.volume, receipts: [ReceiptSnapshot(receipt)], entries: [
            CleanupPathEvidence(path: CLTInspector.directory, itemType: .directory, owners: [], baseline: .missing, reason: .alreadyMissing)
        ], isComplete: true)
        let developer = try fullXcodeDeveloperPath()
        let selector = fixture.directory.appendingPathComponent("selector")
        try ("#!/bin/bash\nprintf '%s' " + ShellLiteral.quote(developer) + "\n").write(to: selector, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: selector.path)
        var tools = fixture.tools
        tools.cltContainer = container.path
        tools.xcodeSelect = selector.path
        tools.open = "/usr/bin/true"
        let script = try ValidatedCleanupScriptExporter(tools: tools).generate(
            .init(plan: plan, dryRun: false, forgetReceipts: true, cltDirectory: CLTInspector.directory, activeDeveloperPath: developer), currentVolume: plan.volume)
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let (status, output) = try fixture.run(script)
        XCTAssertNotEqual(status, 0, output)
        XCTAssertEqual(FileExistenceCache.inspect(container.path), .present)
        XCTAssertEqual(FileExistenceCache.inspect(fixture.directory.appendingPathComponent("forgotten").path), .missing)
    }

    func testGeneratedScriptPreservesSharedPayloadThroughParentAlias() async throws {
        let fixture = try ScriptFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let selected = try PackageID("com.example.fixture"), retained = try PackageID("com.example.other")
        let alias = fixture.file.path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/")
        let repository = PackageRepositoryImpl(client: AliasReceiptClient(selected: selected, retained: retained,
            selectedPath: fixture.file.path, retainedPath: alias))
        let volume = CleanupVolumeIdentity.capture("/")
        let plan = try await CleanupPlanBuilder().build(targets: [selected], repository: repository, volume: volume)
        XCTAssertEqual(plan.entries.first?.reason, .sharedOwnership)
        try PropertyListSerialization.data(fromPropertyList: ["VolumeUUID": volume.uuid!], format: .xml, options: 0)
            .write(to: fixture.directory.appendingPathComponent("volume.plist"))
        try Data("com.example.fixture\ncom.example.other\n".utf8).write(to: fixture.directory.appendingPathComponent("catalog"))
        try Data((String(fixture.file.path.dropFirst()) + "\n").utf8).write(to: fixture.directory.appendingPathComponent("inventory"))
        try Data((String(alias.dropFirst()) + "\n").utf8).write(to: fixture.directory.appendingPathComponent("inventory-other"))
        var tools = fixture.tools
        tools.stat = "/usr/bin/stat"
        let script = try ValidatedCleanupScriptExporter(tools: tools).generate(CleanupExecutionRequest(plan: plan, dryRun: false), currentVolume: volume)
        let (status, output) = try fixture.run(script)
        XCTAssertEqual(status, 0, output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: alias))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("forgotten").path))
    }

    func testScriptExecutesOnlyTemporaryLiteralTargetAfterConfirmation() throws {
        let fixture = try ScriptFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let script = try ValidatedCleanupScriptExporter(tools: fixture.tools).generate(fixture.request, currentVolume: fixture.request.plan.volume)
        let (status, output) = try fixture.run(script)
        XCTAssertEqual(status, 0, output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.file.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("forgotten").path))
    }
    func testChangedPathAndOwnersBlockAllMutation() throws {
        for changeOwner in [false, true] {
            let fixture = try ScriptFixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let script = try ValidatedCleanupScriptExporter(tools: fixture.tools).generate(fixture.request, currentVolume: fixture.request.plan.volume)
            if changeOwner {
                let owners: [String: Any] = ["path-info": [["pkgid": "com.example.other"]]]
                try PropertyListSerialization.data(fromPropertyList: owners, format: .xml, options: 0).write(to: fixture.directory.appendingPathComponent("owners.plist"))
            } else { try Data("replacement content".utf8).write(to: fixture.file) }
            let (status, output) = try fixture.run(script)
            XCTAssertNotEqual(status, 0, output)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("forgotten").path))
        }
    }
    func testCancellationAndReceiptFailureDoNotClaimSuccess() throws {
        for cancel in [true, false] {
            let fixture = try ScriptFixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            if !cancel { try Data().write(to: fixture.directory.appendingPathComponent("fail-forget")) }
            let script = try ValidatedCleanupScriptExporter(tools: fixture.tools).generate(fixture.request, currentVolume: fixture.request.plan.volume)
            let (status, output) = try fixture.run(script, confirmation: cancel ? "CANCEL\n" : "REMOVE\n")
            XCTAssertNotEqual(status, 0, output)
            XCTAssertFalse(output.contains("Commands finished."))
            XCTAssertEqual(FileManager.default.fileExists(atPath: fixture.file.path), cancel)
        }
    }
}

extension ValidatedCleanupScriptExporterTests {
    func testCLTRootUsesIndependentEmptyContainerRemoval() throws {
        let base = try request(clt: true)
        let script = try ValidatedCleanupScriptExporter().generate(base, currentVolume: identity)
        XCTAssertTrue(script.contains("/bin/rmdir '" + CLTInspector.directory + "'"))
        XCTAssertFalse(script.contains("--reset"))
    }
    func testRuntimeVolumeReceiptAndSymlinkChangesRefuseMutation() throws {
        for scenario in ["volume", "receipt", "symlink"] {
            let fixture = try ScriptFixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let script = try ValidatedCleanupScriptExporter(tools: fixture.tools).generate(fixture.request, currentVolume: fixture.request.plan.volume)
            switch scenario {
            case "volume":
                try PropertyListSerialization.data(fromPropertyList: ["VolumeUUID": "replacement"], format: .xml, options: 0)
                    .write(to: fixture.directory.appendingPathComponent("volume.plist"))
            case "receipt":
                try PropertyListSerialization.data(fromPropertyList: ["pkg-version": "2", "install-time": 1, "install-location": "/"], format: .xml, options: 0)
                    .write(to: fixture.directory.appendingPathComponent("receipt.plist"))
            default:
                let target = fixture.directory.appendingPathComponent("other")
                try Data("keep".utf8).write(to: target)
                try FileManager.default.removeItem(at: fixture.file)
                try FileManager.default.createSymbolicLink(at: fixture.file, withDestinationURL: target)
            }
            let (status, output) = try fixture.run(script)
            XCTAssertNotEqual(status, 0, output)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("forgotten").path))
        }
    }
    func testPreflightRepeatsAfterUserConfirmation() throws {
        let fixture = try ScriptFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let fakeDate = fixture.directory.appendingPathComponent("date")
        let base = ShellLiteral.quote(fixture.directory.path)
        let code = """
        #!/bin/bash
        set -euo pipefail
        base=\(base)
        n=0
        [[ ! -f "$base/date-count" ]] || n=$(/bin/cat "$base/date-count")
        n=$((n + 1)); printf '%s' "$n" > "$base/date-count"
        if [[ $n -eq 3 ]]; then
          printf '%s' '<?xml version="1.0"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd"><plist version="1.0"><dict><key>VolumeUUID</key><string>replacement</string></dict></plist>' > "$base/volume.plist"
        fi
        /bin/date "$@"
        """
        try code.write(to: fakeDate, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: fakeDate.path)
        var tools = fixture.tools; tools.date = fakeDate.path
        let script = try ValidatedCleanupScriptExporter(tools: tools).generate(fixture.request, currentVolume: fixture.request.plan.volume)
        let (status, output) = try fixture.run(script)
        XCTAssertNotEqual(status, 0, output)
        XCTAssertTrue(output.contains("Volume identity changed"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
    }
}

extension ValidatedCleanupScriptExporterTests {
    func testExplicitSwitchPrecedesContainerRemovalAndCallbackIsOnlyAReceipt() throws {
        for fails in [true, false] {
            let fixture = try ScriptFixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let xcode = fixture.directory.appendingPathComponent("Preserved Xcode.app/Contents/Developer")
            for child in ["usr/bin", "Toolchains/XcodeDefault.xctoolchain/usr/bin", "Platforms"] {
                try FileManager.default.createDirectory(at: xcode.appendingPathComponent(child), withIntermediateDirectories: true)
            }
            for child in ["usr/bin/xcodebuild", "Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"] {
                let executable = xcode.appendingPathComponent(child)
                try Data("#!/bin/bash\nexit 0\n".utf8).write(to: executable)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
            }
            try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.apple.dt.Xcode"], format: .xml, options: 0)
                .write(to: xcode.deletingLastPathComponent().appendingPathComponent("Info.plist"))
            XCTAssertTrue(CLTInspector.isValidatedFullXcodeDeveloperPath(xcode.path))
            let container = fixture.directory.appendingPathComponent("clt-container")
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
            var tools = fixture.tools
            tools.cltContainer = container.path
            let selection = fixture.directory.appendingPathComponent("selection")
            try CLTInspector.directory.write(to: selection, atomically: true, encoding: .utf8)
            let reset = fixture.directory.appendingPathComponent("xcode-select")
            let callback = fixture.directory.appendingPathComponent("open")
            let selectionLiteral = ShellLiteral.quote(selection.path)
            let switchCode = """
            #!/bin/bash
            if [[ $1 == -p ]]; then /bin/cat \(selectionLiteral)
            elif [[ $1 == --switch ]]; then
              [[ -d \(ShellLiteral.quote(container.path)) ]] || exit 9
              \(fails ? "exit 7" : "printf '%s' \"$2\" > " + selectionLiteral)
            else exit 8; fi
            """
            try switchCode.write(to: reset, atomically: true, encoding: .utf8)
            try ("#!/bin/bash\nprintf '%s' \"$1\" > " + ShellLiteral.quote(fixture.directory.appendingPathComponent("callback").path) + "\n").write(to: callback, atomically: true, encoding: .utf8)
            for tool in [reset, callback] { try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path) }
            tools.xcodeSelect = reset.path; tools.open = callback.path
            let id = try PackageID("com.apple.pkg.CLTools_Executables")
            try Data((id.rawValue + "\n").utf8).write(to: fixture.directory.appendingPathComponent("catalog"))
            let receipt = PackageReceipt(id: id, version: "1", volume: "/", installLocation: "/", installTime: Date(timeIntervalSince1970: 1))
            let plan = CleanupEvidencePlan(volume: fixture.request.plan.volume, receipts: [ReceiptSnapshot(receipt)], entries: [], isComplete: true)
            let request = CleanupExecutionRequest(plan: plan, dryRun: false, forgetReceipts: true,
                resetDeveloperSelection: true, cltDirectory: CLTInspector.directory,
                activeDeveloperPath: CLTInspector.directory, replacementDeveloperPath: xcode.path, recipe: .clt)
            let script = try ValidatedCleanupScriptExporter(tools: tools).generate(request, currentVolume: plan.volume)
            let (status, output) = try fixture.run(script)
            XCTAssertEqual(status, fails ? 7 : 0, output)
            XCTAssertEqual(FileExistenceCache.inspect(container.path), fails ? .present : .missing)
            XCTAssertEqual(FileExistenceCache.inspect(xcode.path), .present)
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("callback").path))
        }
    }

}

extension ValidatedCleanupScriptExporterTests {
    func testSymlinkLeafIsUnlinkedWithoutFollowingTarget() async throws {
        let fixture = try ScriptFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let target = fixture.directory.appendingPathComponent("preserved-target")
        try Data("preserve".utf8).write(to: target)
        try FileManager.default.removeItem(at: fixture.file)
        try FileManager.default.createSymbolicLink(at: fixture.file, withDestinationURL: target)
        let id = try PackageID("com.example.fixture")
        let repository = PlanningRepository(ids: [id], paths: [String(fixture.file.path.dropFirst())], owners: [id])
        let plan = try await CleanupPlanBuilder().build(targets: [id], repository: repository, volume: fixture.request.plan.volume)
        XCTAssertEqual(plan.entries.first?.itemType.rawValue, "symbolicLink")
        let request = CleanupExecutionRequest(plan: plan, dryRun: false, forgetReceipts: true)
        let script = try ValidatedCleanupScriptExporter(tools: fixture.tools).generate(request, currentVolume: plan.volume)
        let (status, output) = try fixture.run(script)
        XCTAssertEqual(status, 0, output)
        XCTAssertEqual(FileExistenceCache.inspect(fixture.file.path), .missing)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "preserve")
    }
}

extension ValidatedCleanupScriptExporterTests {
    func testOwnerPlistWithoutEchoedPathUsesBoundInvocation() throws {
        let fixture = try ScriptFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        try PropertyListSerialization.data(fromPropertyList: ["path-info": [["pkgid": "com.example.fixture"]]], format: .xml, options: 0)
            .write(to: fixture.directory.appendingPathComponent("owners.plist"))
        let script = try ValidatedCleanupScriptExporter(tools: fixture.tools).generate(fixture.request, currentVolume: fixture.request.plan.volume)
        let (status, output) = try fixture.run(script)
        XCTAssertEqual(status, 0, output)
        XCTAssertEqual(FileExistenceCache.inspect(fixture.file.path), .missing)
    }

    func testUnrecordedContainerItemPreventsRemovalAndForget() throws {
        let fixture = try ScriptFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let container = fixture.directory.appendingPathComponent("clt-container")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        let unknown = container.appendingPathComponent("unknown")
        try Data("preserve".utf8).write(to: unknown)
        var tools = fixture.tools
        tools.cltContainer = container.path
        let selection = fixture.directory.appendingPathComponent("xcode-select")
        let developerPath = try fullXcodeDeveloperPath()
        try ("#!/bin/bash\nprintf '%s' " + ShellLiteral.quote(developerPath) + "\n").write(to: selection, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: selection.path)
        tools.xcodeSelect = selection.path
        tools.open = "/usr/bin/true"
        let id = try PackageID("com.apple.pkg.CLTools_Executables")
        let receipt = PackageReceipt(id: id, version: "1", volume: "/", installLocation: "/", installTime: Date(timeIntervalSince1970: 1))
        let plan = CleanupEvidencePlan(volume: fixture.request.plan.volume, receipts: [ReceiptSnapshot(receipt)], entries: [], isComplete: true)
        let request = CleanupExecutionRequest(plan: plan, dryRun: false, forgetReceipts: true,
            cltDirectory: CLTInspector.directory, activeDeveloperPath: developerPath)
        let script = try ValidatedCleanupScriptExporter(tools: tools).generate(request, currentVolume: plan.volume)
        let (status, output) = try fixture.run(script)
        XCTAssertNotEqual(status, 0, output)
        XCTAssertEqual(try String(contentsOf: unknown, encoding: .utf8), "preserve")
        XCTAssertEqual(FileExistenceCache.inspect(fixture.directory.appendingPathComponent("forgotten").path), .missing)
    }
}

extension ValidatedCleanupScriptExporterTests {
    private func bulkRequest(_ fixture: ScriptFixture) throws -> CleanupExecutionRequest {
        let inventory = Data("synthetic inventory\n".utf8)
        try inventory.write(to: fixture.directory.appendingPathComponent("inventory"))
        try inventory.write(to: fixture.directory.appendingPathComponent("inventory-other"))
        try Data("com.example.fixture\ncom.example.other\n".utf8).write(to: fixture.directory.appendingPathComponent("catalog"))
        let other = PackageReceipt(id: try PackageID("com.example.other"), version: "1", volume: "/", installLocation: "/", installTime: Date(timeIntervalSince1970: 1))
        let records = (fixture.request.plan.receipts + [ReceiptSnapshot(other)]).map {
            ReceiptOwnershipEvidence.Record(receipt: $0, filesSHA256: ReceiptFileInventory.digest(inventory))
        }
        let plan = CleanupEvidencePlan(volume: fixture.request.plan.volume, receipts: fixture.request.plan.receipts,
            entries: fixture.request.plan.entries, isComplete: true,
            ownershipEvidence: ReceiptOwnershipEvidence(volume: fixture.request.plan.volume, records: records))
        return CleanupExecutionRequest(plan: plan, dryRun: false, forgetReceipts: true)
    }
    func testBatchEvidenceAvoidsPerPathOwnerProcessesAndKeepsLiteralPathsSafe() throws {
        let fixture = try ScriptFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let request = try bulkRequest(fixture)
        try Data().write(to: fixture.directory.appendingPathComponent("bulk-only"))
        let script = try ValidatedCleanupScriptExporter(tools: fixture.tools).generate(request, currentVolume: request.plan.volume)
        let (status, output) = try fixture.run(script)
        XCTAssertEqual(status, 0, output)
        XCTAssertEqual(FileExistenceCache.inspect(fixture.file.path), .missing)
    }
    func testChangedUnrelatedReceiptInventoryOrCatalogBlocksAllMutation() throws {
        for changedCatalog in [true, false] {
            let fixture = try ScriptFixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let request = try bulkRequest(fixture)
            try Data("changed\n".utf8).write(to: fixture.directory.appendingPathComponent(changedCatalog ? "catalog" : "inventory-other"))
            let script = try ValidatedCleanupScriptExporter(tools: fixture.tools).generate(request, currentVolume: request.plan.volume)
            let (status, output) = try fixture.run(script)
            XCTAssertNotEqual(status, 0, output)
            XCTAssertEqual(FileExistenceCache.inspect(fixture.file.path), .present)
            XCTAssertEqual(FileExistenceCache.inspect(fixture.directory.appendingPathComponent("forgotten").path), .missing)
        }
    }
}

extension ValidatedCleanupScriptExporterTests {
    func testBatchFingerprintBoundaryChecksEveryPathBeforeMutation() throws {
        for changesLastPath in [false, true] {
            let fixture = try ScriptFixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let base = try bulkRequest(fixture)
            var entries = base.plan.entries
            for index in 0..<129 {
                let path = fixture.directory.appendingPathComponent(String(format: "batch-%03d", index))
                try Data("original".utf8).write(to: path)
                entries.append(CleanupPathEvidence(path: path.path, itemType: .file, owners: ["com.example.fixture"],
                    baseline: .present, reason: .selectedReceiptOnly, fingerprint: FileExistenceCache.fingerprint(path.path)))
            }
            if changesLastPath {
                try Data("changed after planning".utf8).write(to: URL(fileURLWithPath: try XCTUnwrap(entries.last).path))
            }
            let plan = CleanupEvidencePlan(volume: base.plan.volume, receipts: base.plan.receipts, entries: entries,
                isComplete: true, ownershipEvidence: base.plan.ownershipEvidence)
            let request = CleanupExecutionRequest(plan: plan, dryRun: false, forgetReceipts: true)
            let script = try ValidatedCleanupScriptExporter(tools: fixture.tools).generate(request, currentVolume: plan.volume)
            let (status, output) = try fixture.run(script)
            XCTAssertEqual(status == 0, !changesLastPath, output)
            XCTAssertTrue(entries.allSatisfy { FileExistenceCache.inspect($0.path) == (changesLastPath ? .present : .missing) })
        }
    }
}

extension ValidatedCleanupScriptExporterTests {
    func testBatchSymlinkRemovalPreservesItsDestination() throws {
        let fixture = try ScriptFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let base = try bulkRequest(fixture)
        let target = fixture.directory.appendingPathComponent("preserved-destination")
        try Data("preserve".utf8).write(to: target)
        try FileManager.default.removeItem(at: fixture.file)
        try FileManager.default.createSymbolicLink(at: fixture.file, withDestinationURL: target)
        let entry = CleanupPathEvidence(path: fixture.file.path, itemType: .symbolicLink, owners: ["com.example.fixture"],
            baseline: .present, reason: .selectedReceiptOnly, fingerprint: FileExistenceCache.fingerprint(fixture.file.path), symbolicLinkTarget: target.path)
        let plan = CleanupEvidencePlan(volume: base.plan.volume, receipts: base.plan.receipts, entries: [entry],
            isComplete: true, ownershipEvidence: base.plan.ownershipEvidence)
        let script = try ValidatedCleanupScriptExporter(tools: fixture.tools).generate(.init(plan: plan, dryRun: false), currentVolume: plan.volume)
        let (status, output) = try fixture.run(script)
        XCTAssertEqual(status, 0, output)
        XCTAssertEqual(FileExistenceCache.inspect(fixture.file.path), .missing)
        XCTAssertEqual(try String(contentsOf: target, encoding: .utf8), "preserve")
    }
    func testFailedEmptyInventoryQueryCannotPassItsDigestCheck() throws {
        let fixture = try ScriptFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let base = try bulkRequest(fixture)
        let evidence = ReceiptOwnershipEvidence(volume: base.plan.volume,
            records: try XCTUnwrap(base.plan.ownershipEvidence).records.map {
                .init(receipt: $0.receipt, filesSHA256: ReceiptFileInventory.digest(Data()))
            })
        let plan = CleanupEvidencePlan(volume: base.plan.volume, receipts: base.plan.receipts, entries: base.plan.entries,
            isComplete: true, ownershipEvidence: evidence)
        try Data().write(to: fixture.directory.appendingPathComponent("fail-files"))
        let script = try ValidatedCleanupScriptExporter(tools: fixture.tools).generate(.init(plan: plan, dryRun: false), currentVolume: plan.volume)
        let (status, output) = try fixture.run(script)
        XCTAssertNotEqual(status, 0, output)
        XCTAssertEqual(FileExistenceCache.inspect(fixture.file.path), .present)
    }
}

extension ValidatedCleanupScriptExporterTests {
    func testLegacyPlaceholderRetirementNeverDeletesTemporaryPayloadOrParents() async throws {
        for present in [false, true] {
            let fixture = try ScriptFixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let hash = ReceiptFileInventory.digest(Data(UUID().uuidString.utf8)).uppercased()
            let leaf = "/private/tmp/." + hash
            if present { try Data("preserve".utf8).write(to: URL(fileURLWithPath: leaf)) }
            defer { if present { try? FileManager.default.removeItem(atPath: leaf) } }
            let id = try PackageID("com.apple.pkg.CLTools_SDK_macOS13")
            try Data((id.rawValue + "\n").utf8).write(to: fixture.directory.appendingPathComponent("catalog"))
            let repository = PlanningRepository(ids: [id], paths: ["private", "private/tmp", "private/tmp/." + hash],
                directories: ["private", "private/tmp"], owners: [id])
            let plan = try await CleanupPlanBuilder().build(targets: [id], repository: repository, volume: fixture.request.plan.volume,
                cache: FileExistenceCache(observer: { $0 == CLTInspector.directory ? .present : FileExistenceCache.inspect($0) }))
            let container = fixture.directory.appendingPathComponent("clt-container")
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
            var tools = fixture.tools
            tools.cltContainer = container.path
            tools.open = "/usr/bin/true"
            let selection = fixture.directory.appendingPathComponent("xcode-select")
            let developerPath = try fullXcodeDeveloperPath()
            try ("#!/bin/bash\nprintf '%s' " + ShellLiteral.quote(developerPath) + "\n").write(to: selection, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: selection.path)
            tools.xcodeSelect = selection.path
            let request = CleanupExecutionRequest(plan: plan, dryRun: false, forgetReceipts: true,
                cltDirectory: CLTInspector.directory, activeDeveloperPath: developerPath)
            if present {
                XCTAssertThrowsError(try ValidatedCleanupScriptExporter(tools: tools).generate(request, currentVolume: plan.volume))
                XCTAssertEqual(FileExistenceCache.inspect(container.path), .present)
            } else {
                let script = try ValidatedCleanupScriptExporter(tools: tools).generate(request, currentVolume: plan.volume)
                let (status, output) = try fixture.run(script)
                XCTAssertEqual(status, 0, output)
            }
            XCTAssertEqual(FileExistenceCache.inspect(leaf), present ? .present : .missing)
            XCTAssertEqual(FileExistenceCache.inspect("/private"), .present)
            XCTAssertEqual(FileExistenceCache.inspect("/private/tmp"), .present)
            XCTAssertEqual(FileExistenceCache.inspect(fixture.directory.appendingPathComponent("forgotten").path), present ? .missing : .present)
        }
    }
}

extension ValidatedCleanupScriptExporterTests {
    func testKnownRetainedPayloadRejectsForgetBeforeAnyExecution() throws {
        for reason in [CleanupPathEvidence.RetentionReason.sharedOwnership, .outsideRecipeScope] {
            let fixture = try ScriptFixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let retained = fixture.directory.appendingPathComponent("retained-payload")
            try Data("preserve shared payload".utf8).write(to: retained)
            let selection = fixture.directory.appendingPathComponent("selection")
            let developerPath = try fullXcodeDeveloperPath()
            try developerPath.write(to: selection, atomically: true, encoding: .utf8)
            let selector = fixture.directory.appendingPathComponent("xcode-select")
            let selectionCode = "#!/bin/bash\n[[ $1 == -p ]] || exit 9\n/bin/cat " + ShellLiteral.quote(selection.path) + "\n"
            try selectionCode.write(to: selector, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: selector.path)
            var tools = fixture.tools
            tools.xcodeSelect = selector.path
            let id = try PackageID("com.apple.pkg.CLTools_Executables")
            let receipt = PackageReceipt(id: id, version: "1", volume: "/", installLocation: "/", installTime: Date(timeIntervalSince1970: 1))
            let exclusive = CleanupPathEvidence(path: CLTInspector.directory + "/exclusive-synthetic", itemType: .file,
                owners: [id.rawValue], baseline: .present, reason: .selectedReceiptOnly,
                fingerprint: FileExistenceCache.fingerprint(fixture.file.path))
            let retainedPath = reason == .sharedOwnership ? CLTInspector.directory + "/shared-synthetic" : "/Applications/Preserved Xcode.app/Contents/Developer/synthetic"
            let kept = CleanupPathEvidence(path: retainedPath, itemType: .file,
                owners: [id.rawValue, "com.example.other"], baseline: .present,
                reason: reason, fingerprint: FileExistenceCache.fingerprint(retained.path))
            let plan = CleanupEvidencePlan(volume: fixture.request.plan.volume, receipts: [ReceiptSnapshot(receipt)],
                entries: [exclusive, kept], isComplete: true)
            let request = CleanupExecutionRequest(plan: plan, dryRun: false, forgetReceipts: true,
                cltDirectory: CLTInspector.directory, activeDeveloperPath: developerPath)
            XCTAssertThrowsError(try ValidatedCleanupScriptExporter(tools: tools).generate(request, currentVolume: plan.volume))
            XCTAssertEqual(FileExistenceCache.inspect(fixture.file.path), .present)
            XCTAssertEqual(try String(contentsOf: retained, encoding: .utf8), "preserve shared payload")
            XCTAssertEqual(try String(contentsOf: selection, encoding: .utf8), developerPath)
            XCTAssertEqual(FileExistenceCache.inspect(fixture.directory.appendingPathComponent("forgotten").path), .missing)
            let simulation = CleanupExecutionRequest(plan: plan, dryRun: true, forgetReceipts: true,
                cltDirectory: CLTInspector.directory, activeDeveloperPath: developerPath)
            XCTAssertTrue(try ValidatedCleanupScriptExporter(tools: tools).generate(simulation, currentVolume: plan.volume).contains("DRY-RUN"))
            if reason == .sharedOwnership {
                let ordinaryPlan = CleanupEvidencePlan(volume: fixture.request.plan.volume, receipts: fixture.request.plan.receipts,
                    entries: fixture.request.plan.entries + [CleanupPathEvidence(path: retained.path, itemType: .file,
                        owners: ["com.example.fixture", "com.example.other"], baseline: .present, reason: .sharedOwnership)], isComplete: true)
                XCTAssertNoThrow(try ValidatedCleanupScriptExporter(tools: tools).generate(
                    .init(plan: ordinaryPlan, dryRun: false, forgetReceipts: true), currentVolume: ordinaryPlan.volume))
            }
        }
    }
}

extension ValidatedCleanupScriptExporterTests {
    func testReceiptOnlyCleanupChecksTheActualCatalogAfterForget() throws {
        for forgetIsNoOp in [false, true] {
            let fixture = try ScriptFixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let id = try PackageID("com.apple.dt.commandlinetools")
            let receipt = PackageReceipt(id: id, version: "1", volume: "/", installLocation: "/", installTime: Date(timeIntervalSince1970: 1))
            let plan = CleanupEvidencePlan(volume: fixture.request.plan.volume, receipts: [ReceiptSnapshot(receipt)],
                entries: [], isComplete: true)
            let catalog = "\(id.rawValue)\n\(id.rawValue).unrelated\n"
            try Data(catalog.utf8).write(to: fixture.directory.appendingPathComponent("catalog"))
            try Data().write(to: fixture.directory.appendingPathComponent("inventory"))
            if forgetIsNoOp { try Data().write(to: fixture.directory.appendingPathComponent("forget-noop")) }
            let callback = fixture.directory.appendingPathComponent("callback")
            let open = fixture.directory.appendingPathComponent("open")
            try ("#!/bin/bash\nprintf '%s' \"$1\" > " + ShellLiteral.quote(callback.path) + "\n")
                .write(to: open, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: open.path)
            var tools = fixture.tools
            tools.cltContainer = fixture.directory.appendingPathComponent("absent-clt").path
            tools.open = open.path
            let request = CleanupExecutionRequest(plan: plan, dryRun: false, forgetReceipts: true, recipe: .clt)
            let script = try ValidatedCleanupScriptExporter(tools: tools).generate(request, currentVolume: plan.volume)
            let (status, output) = try fixture.run(script)
            XCTAssertEqual(status, forgetIsNoOp ? 1 : 0, output)
            XCTAssertEqual(output.contains("Receipt is still registered after pkgutil --forget: " + id.rawValue), forgetIsNoOp)
            XCTAssertEqual(FileExistenceCache.inspect(fixture.directory.appendingPathComponent("forgotten").path), .present)
            XCTAssertFalse(FileManager.default.fileExists(atPath: callback.path))
        }
    }

    func testStandaloneCleanupDoesNotRequireAValidatedActiveDeveloperPath() throws {
        let base = try request(clt: true)
        let invalid = "/private/tmp/not-full-xcode-" + UUID().uuidString
        let execution = CleanupExecutionRequest(plan: base.plan, dryRun: false, forgetReceipts: true,
            cltDirectory: CLTInspector.directory, activeDeveloperPath: invalid)
        let script = try ValidatedCleanupScriptExporter().generate(execution, currentVolume: base.plan.volume)
        XCTAssertFalse(script.contains("--switch"))
        XCTAssertFalse(script.contains("/usr/bin/xcrun"))
    }
}

extension ValidatedCleanupScriptExporterTests {
    func testExplicitReplacementIsRevalidatedBeforeCleanup() throws {
        let fixture = try ScriptFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let developerPath = try fullXcodeDeveloperPath()
        let container = fixture.directory.appendingPathComponent("clt-container")
        try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
        var tools = fixture.tools
        tools.cltContainer = container.path
        tools.open = "/usr/bin/true"
        let selector = fixture.directory.appendingPathComponent("xcode-select")
        try ("#!/bin/bash\n[[ $1 == -p ]] || exit 9\nprintf '%s' " + ShellLiteral.quote(CLTInspector.directory) + "\n")
            .write(to: selector, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: selector.path)
        tools.xcodeSelect = selector.path
        let id = try PackageID("com.apple.pkg.CLTools_Executables")
        let receipt = PackageReceipt(id: id, version: "1", volume: "/", installLocation: "/", installTime: Date(timeIntervalSince1970: 1))
        let plan = CleanupEvidencePlan(volume: fixture.request.plan.volume, receipts: [ReceiptSnapshot(receipt)], entries: [], isComplete: true)
        let request = CleanupExecutionRequest(plan: plan, dryRun: false, forgetReceipts: true,
            resetDeveloperSelection: true, cltDirectory: CLTInspector.directory,
            activeDeveloperPath: CLTInspector.directory, replacementDeveloperPath: developerPath)
        let script = try ValidatedCleanupScriptExporter(tools: tools).generate(request, currentVolume: plan.volume)
        let info = URL(fileURLWithPath: developerPath).deletingLastPathComponent().appendingPathComponent("Info.plist")
        try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.changed"], format: .xml, options: 0).write(to: info)
        let (status, output) = try fixture.run(script)
        XCTAssertNotEqual(status, 0, output)
        XCTAssertEqual(FileExistenceCache.inspect(container.path), .present)
        XCTAssertEqual(FileExistenceCache.inspect(developerPath), .present)
        XCTAssertEqual(FileExistenceCache.inspect(fixture.directory.appendingPathComponent("forgotten").path), .missing)
    }
}

extension ValidatedCleanupScriptExporterTests {
    func testUnusablePreservedXcodeStopsBeforeSelectionPayloadAndReceiptChanges() throws {
        for failure in ["fail-xcrun", "wrong-xcrun"] {
            let fixture = try ScriptFixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let developerPath = try fullXcodeDeveloperPath()
            let container = fixture.directory.appendingPathComponent("clt-container")
            try FileManager.default.createDirectory(at: container, withIntermediateDirectories: true)
            let selection = fixture.directory.appendingPathComponent("selection")
            try CLTInspector.directory.write(to: selection, atomically: true, encoding: .utf8)
            let selector = fixture.directory.appendingPathComponent("xcode-select")
            let selected = ShellLiteral.quote(selection.path)
            let code = "#!/bin/bash\nif [[ $1 == -p ]]; then /bin/cat " + selected + "; elif [[ $1 == --switch ]]; then printf '%s' \"$2\" > " + selected + "; else exit 9; fi\n"
            try code.write(to: selector, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: selector.path)
            var tools = fixture.tools
            tools.xcodeSelect = selector.path
            tools.cltContainer = container.path
            tools.open = "/usr/bin/true"
            try Data().write(to: fixture.directory.appendingPathComponent(failure))
            let id = try PackageID("com.apple.pkg.CLTools_Executables")
            let receipt = PackageReceipt(id: id, version: "1", volume: "/", installLocation: "/", installTime: Date(timeIntervalSince1970: 1))
            let plan = CleanupEvidencePlan(volume: fixture.request.plan.volume, receipts: [ReceiptSnapshot(receipt)], entries: [], isComplete: true)
            let request = CleanupExecutionRequest(plan: plan, dryRun: false, forgetReceipts: true,
                resetDeveloperSelection: true, cltDirectory: CLTInspector.directory,
                activeDeveloperPath: CLTInspector.directory, replacementDeveloperPath: developerPath)
            let script = try ValidatedCleanupScriptExporter(tools: tools).generate(request, currentVolume: plan.volume)
            let (status, output) = try fixture.run(script)
            XCTAssertNotEqual(status, 0, output)
            XCTAssertEqual(try String(contentsOf: selection, encoding: .utf8), CLTInspector.directory)
            XCTAssertEqual(FileExistenceCache.inspect(container.path), .present)
            XCTAssertEqual(FileExistenceCache.inspect(fixture.file.path), .present)
            XCTAssertEqual(FileExistenceCache.inspect(fixture.directory.appendingPathComponent("forgotten").path), .missing)
        }
    }
}


extension ValidatedCleanupScriptExporterTests {
    func testTerminalRevalidationStopsBeforePayloadAndReceiptChanges() throws {
        for failOnSecondPreflight in [false, true] {
            let fixture = try ScriptFixture()
            defer { try? FileManager.default.removeItem(at: fixture.directory) }
            let verifier = fixture.directory.appendingPathComponent("verifier'$(printf unsafe)")
            let marker = fixture.directory.appendingPathComponent("first-verification")
            let firstPass = failOnSecondPreflight ? "/usr/bin/touch " + ShellLiteral.quote(marker.path) : "exit 19"
            let code = "#!/bin/bash\n[[ $1 == __verify ]] || exit 8\nif [[ -e " + ShellLiteral.quote(marker.path)
                + " ]]; then exit 19; fi\n" + firstPass + "\n"
            try code.write(to: verifier, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: verifier.path)
            let script = try ValidatedCleanupScriptExporter(tools: fixture.tools).generate(
                fixture.request, currentVolume: fixture.request.plan.volume,
                terminalVerification: .init(executablePath: verifier.path,
                    requestPath: fixture.directory.appendingPathComponent("request'$(printf unsafe).json").path))
            let (status, output) = try fixture.run(script)
            XCTAssertNotEqual(status, 0, output)
            XCTAssertEqual(FileManager.default.fileExists(atPath: marker.path), failOnSecondPreflight)
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.file.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("forgotten").path))
        }
    }
}


extension ValidatedCleanupScriptExporterTests {
    func testPartialReceiptRetirementStopsAndFreshRemainingReceiptRetrySucceeds() throws {
        let fixture = try ScriptFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let first = try PackageID("com.apple.pkg.CLTools_Executables")
        let last = try PackageID("com.apple.dt.commandlinetools")
        let snapshots = [first, last].map { ReceiptSnapshot(PackageReceipt(id: $0, version: "1", volume: "/", installLocation: "/", installTime: Date(timeIntervalSince1970: 1))) }
        try Data((first.rawValue + "\n" + last.rawValue + "\n").utf8).write(to: fixture.directory.appendingPathComponent("catalog"))
        try Data().write(to: fixture.directory.appendingPathComponent("inventory"))
        let marker = fixture.directory.appendingPathComponent("fail-second")
        try Data().write(to: marker)
        var tool = try String(contentsOfFile: fixture.tools.pkgutil, encoding: .utf8)
        tool = tool.replacingOccurrences(of: "if [[ -f \"$base/fail-forget\" ]]; then exit 7; fi", with: "if [[ $2 == com.apple.dt.commandlinetools && -f \"$base/fail-second\" ]]; then exit 7; fi")
        try tool.write(toFile: fixture.tools.pkgutil, atomically: true, encoding: .utf8)
        var tools = fixture.tools
        tools.cltContainer = fixture.directory.appendingPathComponent("absent-clt").path
        let plan = CleanupEvidencePlan(volume: fixture.request.plan.volume, receipts: snapshots, entries: [], isComplete: true)
        let request = CleanupExecutionRequest(plan: plan, dryRun: false, forgetReceipts: true, recipe: .clt)
        let script = try ValidatedCleanupScriptExporter(tools: tools).generate(request, currentVolume: plan.volume)
        let (failedStatus, failedOutput) = try fixture.run(script)
        XCTAssertNotEqual(failedStatus, 0, failedOutput)
        XCTAssertFalse(failedOutput.contains("Commands finished."))
        XCTAssertEqual(try String(contentsOf: fixture.directory.appendingPathComponent("forgotten-ids"), encoding: .utf8), first.rawValue + "\n")
        try FileManager.default.removeItem(at: marker)
        let remaining = CleanupEvidencePlan(volume: plan.volume, receipts: [snapshots[1]], entries: [], isComplete: true)
        let retry = CleanupExecutionRequest(plan: remaining, dryRun: false, forgetReceipts: true, recipe: .clt)
        let (retryStatus, retryOutput) = try fixture.run(ValidatedCleanupScriptExporter(tools: tools).generate(retry, currentVolume: remaining.volume))
        XCTAssertEqual(retryStatus, 0, retryOutput)
        XCTAssertEqual(Set(try String(contentsOf: fixture.directory.appendingPathComponent("forgotten-ids"), encoding: .utf8).split(separator: "\n").map(String.init)), [first.rawValue, last.rawValue])
    }
}
