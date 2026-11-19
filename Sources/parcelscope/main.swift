import Darwin
import Foundation
import ParcelScopeInspection
import ParcelScopeExecution
import Security

// This executable is launched by the user in Terminal. It never elevates itself.
struct ParcelScopeTerminal {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            switch arguments {
            case [], ["--help"], ["help"], ["-h"]:
                print(help)
            case ["--version"], ["version"]:
                print("parcelscope 0.1.0")
            case ["clt", "inspect"], ["clt", "inspect", "--json"]:
                try await inspect(json: arguments.last == "--json")
            case ["clt", "recover"]:
                guard geteuid() == 0 else { throw TerminalError("Recovery verification requires root. Run sudo /Library/ParcelScopeCLI/bin/parcelscope clt recover.") }
                try listRecoverySessions()
            case let input where input.count == 3 && input[0] == "clt" && input[1] == "recover":
                guard let id = UUID(uuidString: input[2]) else {
                    throw TerminalError("Recovery requires a session UUID, not a file path. List sessions with sudo /Library/ParcelScopeCLI/bin/parcelscope clt recover.")
                }
                guard geteuid() == 0 else { throw TerminalError("Recovery verification requires root.") }
                let path = "/private/var/db/parcelscope-residual." + id.uuidString + "/recovery.json"
                let record = try ResidualQuarantineExecutor().recover(recordPath: path)
                print("Recovery state: \(record.state.rawValue)")
                print("Preserved residual bytes verified: \(record.quarantinedPath)")
                print("Recovery record: \(record.recordPath)")
                print("Verification only: no bytes restored or deleted, no receipts changed, no uninstall or Software Update result claimed.")
            case ["clt", "uninstall"]:
                guard geteuid() == 0 else { throw TerminalError("Run sudo /Library/ParcelScopeCLI/bin/parcelscope clt uninstall explicitly in an interactive Terminal.") }
                guard isatty(STDIN_FILENO) == 1, isatty(STDOUT_FILENO) == 1 else {
                    throw TerminalError("Uninstall requires an interactive Terminal; piped confirmation is rejected.")
                }
                let repository = PackageRepositoryImpl()
                let environment = await CLTInspector.environment()
                let catalog = try await repository.fetchCatalog()
                try catalog.requireComplete()
                let targets = catalog.packages.filter { CLTInspector.isCLTReceipt($0.rawValue) }
                guard !targets.isEmpty else { throw TerminalError("No CLT receipts found. Unrecorded files are retained; no uninstall is claimed.") }
                let plan = try await CleanupPlanBuilder(allowsPresentLegacySDKPlaceholder: true)
                    .build(targets: targets, repository: repository, volume: catalog.volume)
                guard let ownership = plan.ownershipEvidence else { throw TerminalError("Complete ownership evidence is required.") }
                let inputs = CLTReviewInputs(id: plan.id, createdAt: plan.generatedAt, volume: plan.volume,
                    receipts: plan.receipts, ownershipEvidence: ownership,
                    activeDeveloperPath: environment.activeDeveloperPath, replacementDeveloperPath: nil, dryRun: false)
                let request = try await TerminalCleanupWorkflow().makeRequest(inputs: inputs, repository: repository, environment: environment)
                let action = try await ResidualQuarantinePlanner().review(repository: repository)
                try await review(request, residualAction: action)
            case let input where input.count == 2 && input[0] == "__verify":
                let path = input[1]
                guard geteuid() == 0 else { throw TerminalError("Verification requires the root review session.") }
                let request = try JSONDecoder().decode(CleanupExecutionRequest.self, from: readFrozenRequest(path))
                let residualPath = (path as NSString).deletingLastPathComponent + "/residual.json"
                let snapshot = try JSONDecoder().decode(ResidualReviewSnapshot.self, from: readFrozenRequest(residualPath))
                let current = try await ResidualQuarantinePlanner().review(repository: PackageRepositoryImpl())
                try snapshot.validate(current: current)
                try await TerminalCleanupWorkflow().revalidate(request, repository: PackageRepositoryImpl(),
                    environment: await CLTInspector.environment(), currentVolume: .capture("/"))
            case let input where input.count == 2 && input[0] == "__quarantine":
                guard geteuid() == 0 else { throw TerminalError("Quarantine requires the root review session.") }
                let snapshot = try JSONDecoder().decode(ResidualReviewSnapshot.self, from: readFrozenRequest(input[1]))
                guard let action = snapshot.action else { throw TerminalError("No residual quarantine was reviewed.") }
                let record = try await ResidualQuarantineExecutor().quarantine(action: action, repository: PackageRepositoryImpl())
                let resultURL = URL(fileURLWithPath: (input[1] as NSString).deletingLastPathComponent + "/residual-result.json")
                try writePrivate(try encoder().encode(record), to: resultURL, mode: 0o400)
                print("Preserved residual bytes and recovery evidence: \(record.recordPath)")
            default:
                throw TerminalError("Unknown command or options. Run parcelscope --help.")
            }
        } catch {
            FileHandle.standardError.write(Data(("ParcelScope: " + error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    private static let help = """
    Usage: parcelscope --help | --version
           parcelscope clt inspect [--json]
           sudo /Library/ParcelScopeCLI/bin/parcelscope clt uninstall
           sudo /Library/ParcelScopeCLI/bin/parcelscope clt recover [SESSION_UUID]

    inspect is read-only and does not require root. Limited access is reported
    explicitly. uninstall reconstructs and freezes live evidence, requires an
    interactive root session and two typed confirmations, and removes only
    supported standalone Command Line Tools payload and receipts. Full Xcode
    is preserved. No GUI, review inputs, package ID or arbitrary removal path is accepted.
    Failed/partial attempts retain private review files; rerun to inspect and
    review a fresh plan. recover without a UUID lists private recovery sessions;
    with a UUID it verifies preserved bytes and original-path absence, and may
    complete an interrupted recovery record. It never restores or deletes bytes
    or changes receipts. Repeat verification safely before reviewing a fresh
    uninstall plan. Software Update eligibility is not verified.
    """

    private static func listRecoverySessions() throws {
        let base = "/private/var/db"
        let descriptor = open(base, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw TerminalError("Cannot inspect the fixed recovery directory.") }
        defer { close(descriptor) }
        var baseInfo = stat()
        guard fstat(descriptor, &baseInfo) == 0, baseInfo.st_uid == 0,
              baseInfo.st_mode & 0o022 == 0 else { throw TerminalError("The recovery directory is not protected by root.") }
        let prefix = "parcelscope-residual."
        var sessions: [String] = []
        for name in try FileManager.default.contentsOfDirectory(atPath: base) where name.hasPrefix(prefix) {
            let text = String(name.dropFirst(prefix.count))
            guard let id = UUID(uuidString: text), id.uuidString == text else { continue }
            var info = stat()
            guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0,
                  info.st_mode & S_IFMT == S_IFDIR, info.st_uid == 0,
                  info.st_mode & 0o7777 == 0o700 else { continue }
            sessions.append(text)
        }
        if sessions.isEmpty { print("No private residual recovery sessions found.") }
        for id in sessions.sorted() {
            print("Unverified recovery session: " + id)
            print("  sudo /Library/ParcelScopeCLI/bin/parcelscope clt recover " + id)
        }
        print("Listing does not verify recovery state or authorize removal. Sessions are retained for audit.")
    }

    private struct InspectionOutput: Encodable {
        var schemaVersion = 1
        var directory = CLTInspector.directory
        var directoryObservation: FileObservation
        var activeDeveloperPath: String?
        var compilerAvailable: Bool?
        var coverage: ReceiptCoverage
        var receiptIDs: [String]
        var diagnostics: [ReceiptDiagnostic]
        var softwareUpdateVerified = false
    }

    private static func inspect(json: Bool) async throws {
        let repository = PackageRepositoryImpl()
        let environment = await CLTInspector.environment()
        let catalog = try await repository.fetchCatalog()
        let output = InspectionOutput(directoryObservation: environment.directory,
            activeDeveloperPath: environment.activeDeveloperPath, compilerAvailable: environment.compilerAvailable,
            coverage: catalog.coverage, receiptIDs: catalog.packages.map(\.rawValue).filter(CLTInspector.isCLTReceipt).sorted(),
            diagnostics: catalog.diagnostics + environment.diagnostics)
        if json {
            FileHandle.standardOutput.write(try encoder().encode(output))
            FileHandle.standardOutput.write(Data("\n".utf8))
        } else {
            print("Command Line Tools: \(output.directoryObservation)")
            print("Developer selection: \(output.activeDeveloperPath ?? "unavailable")")
            print("Receipt coverage: \(output.coverage.rawValue)")
            print("CLT receipts: \(output.receiptIDs.count)")
            output.receiptIDs.forEach { print("  " + $0) }
            output.diagnostics.forEach { print("Diagnostic: " + $0.message) }
            print("Software Update eligibility: not verified")
        }
        if catalog.coverage != .complete { exit(2) }
    }

    private static func encoder() -> JSONEncoder {
        let result = JSONEncoder()
        result.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return result
    }

    private static func readFrozenRequest(_ path: String) throws -> Data {
        // A generated root-only parent prevents another user from replacing the frozen file.
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        let prefix = "parcelscope-terminal."
        guard components.count == 5, components[0].isEmpty, components[1] == "private",
              components[2] == "tmp", components[3].hasPrefix(prefix), ["request.json", "residual.json", "residual-result.json"].contains(String(components[4])) else {
            throw TerminalError("Request is outside the private Terminal review directory.")
        }
        let suffix = components[3].dropFirst(prefix.count).utf8
        guard suffix.count == 6, suffix.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) }) else {
            throw TerminalError("Request is outside the private Terminal review directory.")
        }
        let parent = "/private/tmp/" + components[3]
        let directoryDescriptor = open(parent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directoryDescriptor >= 0 else { throw TerminalError("Review directory is unavailable.") }
        defer { close(directoryDescriptor) }
        var directoryInfo = stat()
        guard fstat(directoryDescriptor, &directoryInfo) == 0, directoryInfo.st_uid == 0,
              directoryInfo.st_mode & 0o777 == 0o700 else { throw TerminalError("Review directory is not private to root.") }
        // Do not follow a replaced leaf or accept a request writable by another user.
        let descriptor = openat(directoryDescriptor, String(components[4]), O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard descriptor >= 0 else { throw TerminalError("Frozen request is unavailable.") }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_uid == 0, info.st_mode & 0o777 == 0o400, info.st_size >= 0, info.st_size <= 256_000_000 else {
            throw TerminalError("Frozen request must be a private root-owned regular file.")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        return try handle.readToEnd() ?? Data()
    }

    private static func review(_ request: CleanupExecutionRequest, residualAction: ResidualQuarantineAction?) async throws {
        guard request.dryRun || (isatty(STDIN_FILENO) == 1 && isatty(STDOUT_FILENO) == 1) else {
            throw TerminalError("Execution review requires an interactive Terminal.")
        }
        var template = Array("/private/tmp/parcelscope-terminal.XXXXXX".utf8CString)
        guard mkdtemp(&template) != nil else { throw TerminalError("Cannot create private review directory.") }
        let root = URL(fileURLWithPath: String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        let frozen = root.appendingPathComponent("request.json")
        let listing = root.appendingPathComponent("review.txt")
        let script = root.appendingPathComponent("cleanup.sh")
        let residualURL = root.appendingPathComponent("residual.json")
        try writePrivate(try encoder().encode(ResidualReviewSnapshot(action: residualAction)), to: residualURL, mode: 0o400)
        // Frozen paths are generated locally from this independent CLI session.
        try writePrivate(try encoder().encode(request), to: frozen, mode: 0o400)
        let plan = request.plan
        let removalCount = plan.entries.filter(\.proposesRemoval).count
        let retainedCount = plan.entries.count - removalCount
        let header = "Plan: \(plan.id.uuidString)\n" + CLTReviewPresentation.targetReceipts(plan.receipts) + "Proposed removals: \(removalCount)\nRetained entries: \(retainedCount)\nDry run: \(request.dryRun)\nActive developer: \(String(reflecting: request.activeDeveloperPath))\nReplacement developer: \(String(reflecting: request.replacementDeveloperPath))\nForget receipts: \(request.forgetReceipts)\n"
        let entries = plan.entries.map { entry in
            "\(entry.proposesRemoval ? "REMOVE" : "RETAIN")\t\(entry.itemType.rawValue)\t\(entry.reason.rawValue)\t\(String(reflecting: entry.path))\towners=\(entry.owners.joined(separator: ","))"
        }.joined(separator: "\n")
        try writePrivate(Data((header + "\n" + entries + "\n" + (residualAction?.reviewSummary ?? "No residual quarantine proposed.") + "\n").utf8), to: listing, mode: 0o400)
        print(header)
        if let residualAction { print(residualAction.reviewSummary) }
        print("Full review: \(listing.path)")
        print("Frozen JSON: \(frozen.path)")
        print("Review files remain private to root for this local session.")
        let executable = try freezeTrustedVerifier(in: root)
        print("Fixed signed verifier: \(executable.path)")
        guard !request.dryRun else {
            print("Simulation review complete; no script was executed and no cleanup is claimed.")
            return
        }
        let content = try ValidatedCleanupScriptExporter().generate(request, currentVolume: .capture("/"),
            terminalVerification: .init(executablePath: executable.path, requestPath: frozen.path),
            residualAction: residualAction, residualActionPath: residualAction == nil ? nil : residualURL.path)
        try writePrivate(Data(content.utf8), to: script, mode: 0o700)
        print("Read the complete review using sudo /usr/bin/less in another Terminal.")
        print("Type REVIEWED after checking every proposed removal: ", terminator: "")
        fflush(nil)
        guard readLine() == "REVIEWED" else { throw TerminalError("Review cancelled; no changes made.") }
        let terminationStatus = try ForegroundShell.run(scriptPath: script.path)
        let status: [String: String] = ["terminationStatus": String(terminationStatus), "finishedAt": Date().ISO8601Format()]
        try writePrivate(try encoder().encode(status), to: root.appendingPathComponent("execution-status.json"), mode: 0o400)
        let environment = await CLTInspector.environment()
        let report = await CleanupVerifier().verify(request, repository: PackageRepositoryImpl(),
            currentVolume: .capture("/"), developerPath: environment.activeDeveloperPath)
        let reportURL = root.appendingPathComponent("verification.json")
        try writePrivate(try encoder().encode(report), to: reportURL, mode: 0o400)
        var residualVerified = residualAction == nil
        var residualStatus = "Residual quarantine: none was proposed."
        if let residualAction {
            let resultPath = root.appendingPathComponent("residual-result.json").path
            residualStatus = "Residual quarantine is unverified. Frozen action: \(residualURL.path). Result record: \(resultPath). Discover durable recovery sessions with sudo /Library/ParcelScopeCLI/bin/parcelscope clt recover."
            if FileExistenceCache.inspect(resultPath) == .present {
                do {
                    let record = try JSONDecoder().decode(ResidualRecoveryRecord.self, from: readFrozenRequest(resultPath))
                    guard record.action == residualAction else { throw TerminalError("Quarantine result does not match review.") }
                    _ = try ResidualQuarantineExecutor().recover(recordPath: record.recordPath)
                    residualVerified = true
                    residualStatus = "Residual quarantine verified; preserved bytes and recovery record: \(record.recordPath)"
                } catch {
                    residualStatus += " Recovery verification refused: " + error.localizedDescription
                }
            }
        }
        print(report.summary)
        print(residualStatus)
        print("Verification evidence: \(reportURL.path)")
        if terminationStatus != 0 || report.outcome != .verified || !residualVerified {
            throw TerminalError("Uninstall failed or is partial (shell status \(terminationStatus)).\n" + CLTReviewPresentation.retrySummary(report)
                + "\nRead the frozen review at \(listing.path) and verification at \(reportURL.path). Preserve this directory and review a fresh plan before retrying. Software Update remains unverified.")
        }
    }

    private static func freezeTrustedVerifier(in directory: URL) throws -> URL {
        var runningCode: SecCode?
        try checkSecurity(SecCodeCopySelf(SecCSFlags(), &runningCode))
        guard let runningCode else { throw TerminalVerifierError.missingIdentity }
        try checkSecurity(SecCodeCheckValidity(runningCode, SecCSFlags(), nil))
        var runningStaticCode: SecStaticCode?
        try checkSecurity(SecCodeCopyStaticCode(runningCode, SecCSFlags(), &runningStaticCode))
        guard let runningStaticCode else { throw TerminalVerifierError.missingIdentity }
        var runningInformation: CFDictionary?
        try checkSecurity(SecCodeCopySigningInformation(runningStaticCode,
            SecCSFlags(rawValue: kSecCSSigningInformation), &runningInformation))
        guard let runningHash = (runningInformation as? [String: Any])?[kSecCodeInfoUnique as String] as? Data,
              !runningHash.isEmpty else { throw TerminalVerifierError.missingIdentity }

        guard let executableURL = Bundle.main.executableURL else { throw TerminalVerifierError.sourceUnavailable }
        let source = executableURL.resolvingSymlinksInPath()
        let descriptor = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw TerminalVerifierError.sourceUnavailable }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG,
              info.st_size > 0, info.st_size <= 100_000_000 else { throw TerminalVerifierError.sourceUnavailable }
        let sourceHandle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var binary = Data()
        while let chunk = try sourceHandle.read(upToCount: 65_536), !chunk.isEmpty {
            guard binary.count + chunk.count <= 100_000_000 else { throw TerminalVerifierError.sourceUnavailable }
            binary.append(chunk)
        }
        let frozen = directory.appendingPathComponent("parcelscope")
        try writePrivate(binary, to: frozen, mode: 0o500)
        var copiedCode: SecStaticCode?
        try checkSecurity(SecStaticCodeCreateWithPath(frozen as CFURL, SecCSFlags(), &copiedCode))
        guard let copiedCode else { throw TerminalVerifierError.missingIdentity }
        try checkSecurity(SecStaticCodeCheckValidity(copiedCode,
            SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures), nil))
        var copiedInformation: CFDictionary?
        try checkSecurity(SecCodeCopySigningInformation(copiedCode,
            SecCSFlags(rawValue: kSecCSSigningInformation), &copiedInformation))
        guard let copiedHash = (copiedInformation as? [String: Any])?[kSecCodeInfoUnique as String] as? Data,
              copiedHash == runningHash else { throw TerminalVerifierError.identityMismatch }

        // Signing information can come from disk. Bind the copied CDHash to the running
        // process dynamically as well, so replacing the source path cannot change identity.
        let hashText = copiedHash.map { String(format: "%02x", $0) }.joined()
        var requirement: SecRequirement?
        try checkSecurity(SecRequirementCreateWithString(("cdhash H\"" + hashText + "\"") as CFString,
            SecCSFlags(), &requirement))
        guard let requirement else { throw TerminalVerifierError.missingIdentity }
        try checkSecurity(SecCodeCheckValidity(runningCode, SecCSFlags(), requirement))
        return frozen
    }

    private static func checkSecurity(_ status: OSStatus) throws {
        guard status == errSecSuccess else { throw TerminalVerifierError.securityStatus(status) }
    }

    private static func writePrivate(_ data: Data, to url: URL, mode: mode_t) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        guard descriptor >= 0 else { throw TerminalError("Cannot create private review file.") }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try handle.write(contentsOf: data)
        try handle.close()
    }
}

private enum TerminalVerifierError: LocalizedError {
    case missingIdentity, sourceUnavailable, identityMismatch, securityStatus(OSStatus)
    var errorDescription: String? {
        switch self {
        case .missingIdentity: "Cannot establish the running verifier's signed identity."
        case .sourceUnavailable: "Cannot read a bounded regular verifier executable for a private copy."
        case .identityMismatch: "The private verifier copy does not match the running executable."
        case .securityStatus(let status): "Verifier signature validation failed (Security status \(status))."
        }
    }
}

private struct TerminalError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

await ParcelScopeTerminal.main()
