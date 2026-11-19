import Foundation
import XCTest

final class CLIContractTests: XCTestCase {
    private func invoke(_ arguments: [String]) throws -> (Int32, String) {
        var root = Bundle(for: CLIContractTests.self).bundleURL
        var executable: URL?
        for _ in 0..<7 {
            let candidate = root.appendingPathComponent("parcelscope")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { executable = candidate; break }
            root.deleteLastPathComponent()
        }
        let path = try XCTUnwrap(executable, "swift test must build the parcelscope executable")
        let process = Process(), pipe = Pipe(), input = Pipe()
        process.executableURL = path
        process.arguments = arguments
        process.standardOutput = pipe; process.standardError = pipe; process.standardInput = input
        try process.run()
        try input.fileHandleForWriting.close()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: output, as: UTF8.self))
    }

    func testRealHelpUsesExactInstalledPrivilegedPath() throws {
        let (status, output) = try invoke(["--help"])
        XCTAssertEqual(status, 0)
        XCTAssertTrue(output.contains("sudo /Library/ParcelScopeCLI/bin/parcelscope clt uninstall"))
        XCTAssertTrue(output.contains("sudo /Library/ParcelScopeCLI/bin/parcelscope clt recover"))
        XCTAssertFalse(output.contains("sudo parcelscope"))
        XCTAssertFalse(output.contains("/usr/local/bin/parcelscope"))
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let packaging = try String(contentsOf: repository.appendingPathComponent("Scripts/package.sh"), encoding: .utf8)
        XCTAssertTrue(packaging.contains("$payload/Library/ParcelScopeCLI/bin"))
        XCTAssertTrue(packaging.contains("--install-location /Library/ParcelScopeCLI"))
    }

    func testRecoveryRejectsArbitraryPathsBeforeReadingThem() throws {
        for value in ["/tmp/forged.json", "../forged", "00000000-0000-0000-0000-000000000000/../other"] {
            let (status, output) = try invoke(["clt", "recover", value])
            XCTAssertNotEqual(status, 0)
            XCTAssertTrue(output.contains("Recovery requires a session UUID"), output)
        }
    }

    func testRecoveryAndUninstallHaveExplicitAuthorizationGates() throws {
        let (status, output) = try invoke(["clt", "recover"])
        if geteuid() != 0 {
            XCTAssertNotEqual(status, 0)
            XCTAssertTrue(output.contains("Recovery verification requires root"), output)
        }
        let (uninstallStatus, uninstallOutput) = try invoke(["clt", "uninstall"])
        XCTAssertNotEqual(uninstallStatus, 0)
        XCTAssertTrue(uninstallOutput.contains(geteuid() == 0 ? "interactive Terminal" : "sudo /Library/ParcelScopeCLI/bin/parcelscope"))
    }
}
