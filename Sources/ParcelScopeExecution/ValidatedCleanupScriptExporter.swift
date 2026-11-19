import Foundation
import ParcelScopeInspection

struct CleanupScriptTools: Sendable {
    var pkgutil = "/usr/sbin/pkgutil"
    var diskutil = "/usr/sbin/diskutil"
    var stat = "/usr/bin/stat"
    var date = "/bin/date"
    var id = "/usr/bin/id"
    var open = "/usr/bin/open"
    var cltContainer = CLTInspector.directory
    var xcodeSelect = "/usr/bin/xcode-select"
    var xcrun = "/usr/bin/xcrun"
}

public struct TerminalCleanupVerification: Sendable {
    public var executablePath: String
    public var requestPath: String
    public init(executablePath: String, requestPath: String) {
        self.executablePath = executablePath
        self.requestPath = requestPath
    }
}

/// Only evidence-backed requests enter this exporter. Legacy Nuke manifests remain rejected.
public struct ValidatedCleanupScriptExporter: Sendable {
    public enum ExportError: LocalizedError {
        case unavailable
        case retainedPayload
        public var errorDescription: String? {
            switch self {
            case .unavailable:
                "The plan is incomplete, stale, or outside the supported execution scope. Re-scan and review it."
            case .retainedPayload:
                "This CLT plan retains files. Receipt removal is blocked before any changes. Review the retained items."
            }
        }
    }
    private let tools: CleanupScriptTools
    public init() { tools = CleanupScriptTools() }
    init(tools: CleanupScriptTools) { self.tools = tools }

    public func generate(_ request: CleanupExecutionRequest,
                         currentVolume: CleanupVolumeIdentity, now: Date = Date(),
                         terminalVerification: TerminalCleanupVerification? = nil,
                         residualAction: ResidualQuarantineAction? = nil,
                         residualActionPath: String? = nil) throws -> String {
        if let terminalVerification {
            guard [terminalVerification.executablePath, terminalVerification.requestPath].allSatisfy({
                $0.hasPrefix("/") && !$0.utf8.contains(0)
            }) else { throw ExportError.unavailable }
        }
        if let residualAction {
            try validateResidual(residualAction, request: request)
            guard request.dryRun || (terminalVerification != nil && residualActionPath?.hasPrefix("/") == true
                && residualActionPath?.utf8.contains(0) == false) else { throw ExportError.unavailable }
        } else if residualActionPath != nil { throw ExportError.unavailable }
        let removable = try validatePlan(request, currentVolume: currentVolume, now: now,
                                         allowsTerminalPlaceholder: terminalVerification != nil)
        let plan = request.plan
        let ownership = plan.ownershipEvidence
        let preservedDeveloperPath = request.resetDeveloperSelection ? request.replacementDeveloperPath : nil
        let legacyPlaceholder = request.recipe == .clt
            ? removable.first { CLTInspector.isLegacyPlaceholderPath($0.path) } : nil
        let quote = ShellLiteral.quote
        if request.dryRun {
            return (["#!/usr/bin/env bash", "set -euo pipefail", ShellLiteral.printLine("[DRY-RUN] Plan \(plan.id.uuidString). No changes will be made.")]
                + removable.map { ShellLiteral.printLine("[DRY-RUN] Proposed removal: " + $0.path) }
                + (residualAction.map { [ShellLiteral.printLine("[DRY-RUN] " + $0.reviewSummary)] } ?? [])
                + [ShellLiteral.printLine("Simulation complete; no execution or verification claimed.")]).joined(separator: "\n") + "\n"
        }
        let pkgutil = quote(tools.pkgutil), stat = quote(tools.stat), date = quote(tools.date)
        var lines = ["#!/usr/bin/env bash", "set -euo pipefail", "umask 077",
            "fail() { printf '%s\\n' \"$1\" >&2; exit 1; }",
            "[[ $(\(quote(tools.id)) -u) == 0 ]] || fail 'Root authorization is required in Terminal.'",
            "plan_expiry=\(Int(plan.generatedAt.timeIntervalSince1970) + 1_800)",
            "[[ $(\(date) +%s) -le $plan_expiry ]] || fail 'Plan expired. Re-scan.'",
            "work=$(/usr/bin/mktemp -d /private/tmp/parcelscope.\(plan.id.uuidString).XXXXXX)",
            "finish() {",
            "  local result=$?",
            "  trap - EXIT",
            "  /bin/rm -f \"$work/receipt.plist\" \"$work/owners.plist\" \"$work/volume.plist\" \"$work/fingerprints.expected\" \"$work/fingerprints.actual\"",
            "  /bin/rmdir \"$work\" || true"
        ]
        // Shell existence tests also return false for EACCES/EPERM. Only ENOENT proves absence.
        let absenceProbe = "use strict; use Errno qw(ENOENT); for my $path (@ARGV) { my @info = lstat($path); if (@info || $! != ENOENT) { print STDERR \"Path present or unreadable; receipts retained: $path\\n\"; exit 1; } }"
        lines += ["  exit \"$result\"", "}", "trap finish EXIT",
            "check_missing() { /usr/bin/perl -e \(quote(absenceProbe)) -- \"$@\"; }", "preflight() {"]
        if let terminalVerification {
            lines.append("\(quote(terminalVerification.executablePath)) __verify \(quote(terminalVerification.requestPath)) || fail 'Live ownership or reviewed plan changed. Re-scan and review again.'")
        }
        lines += [
            "[[ $(\(date) +%s) -le $plan_expiry ]] || fail 'Plan expired. Re-scan.'",
            "\(quote(tools.diskutil)) info -plist / > \"$work/volume.plist\"",
            "[[ $(/usr/bin/plutil -extract VolumeUUID raw -o - \"$work/volume.plist\") == \(quote(plan.volume.uuid!)) ]] || fail 'Volume identity changed.'",
            "[[ $(\(stat) -f %d /) == \(quote(plan.volume.device!)) ]] || fail 'Volume device changed.'",
            "check_path() {", "  local candidate=\"${1%/*}\"; [[ -n \"$candidate\" ]] || candidate=/",
            "  while [[ \"$candidate\" != / ]]; do",
            "    [[ ! -L \"$candidate\" ]] || fail 'Symbolic link encountered. Replan.'",
            "    candidate=\"${candidate%/*}\"; [[ -n \"$candidate\" ]] || candidate=/",
            "  done", "}"]
        if let ownership {
            lines += ["catalog_digest=$(\(pkgutil) --pkgs | LC_ALL=C /usr/bin/sort | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}') || fail 'Receipt catalog unavailable.'",
                "[[ $catalog_digest == \(quote(ownership.catalogSHA256)) ]] || fail 'Receipt catalog changed.'"]
        }
        let receiptChecks = ownership?.records.map(\.receipt) ?? plan.receipts
        for receipt in receiptChecks {
            let id = quote(receipt.packageID)
            lines += ["\(pkgutil) --pkg-info-plist \(id) > \"$work/receipt.plist\"",
                "[[ $(/usr/bin/plutil -extract pkg-version raw -o - \"$work/receipt.plist\") == \(quote(receipt.version)) ]] || fail 'Receipt version changed.'",
                "[[ $(/usr/bin/plutil -extract install-time raw -o - \"$work/receipt.plist\") == \(quote(String(Int(receipt.installTime.timeIntervalSince1970)))) ]] || fail 'Receipt installation changed.'",
                "[[ $(/usr/bin/plutil -extract install-location raw -o - \"$work/receipt.plist\") == \(quote(receipt.installLocation)) ]] || fail 'Receipt location changed.'"]
            if request.recipe == .clt, receipt.packageID == CLTInspector.updateReceiptID {
                lines += ["update_files=$(\(pkgutil) --files \(id)) || fail 'Could not read the Command Line Tools update receipt inventory.'",
                    "[[ -z $update_files ]] || fail 'The Command Line Tools update receipt lists installed files.'"]
            }
            if let record = ownership?.records.first(where: { $0.receipt.packageID == receipt.packageID }) {
                lines += ["files_digest=$(\(pkgutil) --files \(id) | /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}') || fail 'Receipt file inventory unavailable.'",
                    "[[ $files_digest == \(quote(record.filesSHA256)) ]] || fail 'Receipt file inventory changed.'"]
            }
        }
        for entry in plan.entries where entry.reason == .installationContainer {
            let path = quote(entry.path)
            lines += ["check_path \(path)", "[[ -d \(path) && ! -L \(path) ]] || fail 'Installation container changed.'"]
        }
        for chunk in chunks(plan.entries.filter { $0.reason == .alreadyMissing }, size: 128) {
            let paths = chunk.map { request.recipe == .clt && $0.path == CLTInspector.directory ? tools.cltContainer : $0.path }
            lines.append("paths=(" + paths.map(quote).joined(separator: " ") + ")")
            lines += ["for candidate in \"${paths[@]}\"; do check_path \"$candidate\"; done", "check_missing \"${paths[@]}\""]
        }
        if ownership != nil {
            lines += batchPreflight(removable, stat: stat)
        }
        for entry in ownership == nil ? removable : [] {
            let path = quote(entry.path)
            let patterns = entry.owners.map(quote).joined(separator: "|")
            let leafCheck = entry.itemType == .symbolicLink ? "[[ -L \(path) ]]" : (entry.itemType == .directory ? "[[ -d \(path) && ! -L \(path) ]]" : "[[ -f \(path) && ! -L \(path) ]]")
            lines += ["check_path \(path)", leafCheck + " || fail 'Leaf type changed.'",
                "[[ $(\(stat) -f '%m:%z:%i:%d:%p' \(path)) == \(quote(entry.fingerprint!)) ]] || fail 'Path changed since planning.'",
                "\(pkgutil) --file-info-plist \(path) > \"$work/owners.plist\"",
                "if lookup_path=$(/usr/bin/plutil -extract path raw -o - \"$work/owners.plist\" 2>/dev/null); then [[ $lookup_path == \(path) ]] || fail 'Lookup path evidence changed.'; fi",
                "index=0", "observed_owners=()", "while owner=$(/usr/bin/plutil -extract \"path-info.$index.pkgid\" raw -o - \"$work/owners.plist\" 2>/dev/null); do",
                "  case \"$owner\" in \(patterns)) ;; *) fail 'Ownership changed. Replan.' ;; esac",
                "  for previous in \"${observed_owners[@]-}\"; do [[ $previous != \"$owner\" ]] || fail 'Duplicate owner evidence.'; done",
                "  observed_owners+=(\"$owner\")",
                "  index=$((index + 1))", "done",
                "[[ $index -eq \(entry.owners.count) ]] || fail 'Owner evidence changed or unavailable.'"]
            if let target = entry.symbolicLinkTarget, entry.itemType == .symbolicLink {
                lines.append("[[ $(/usr/bin/readlink \(path)) == \(quote(target)) ]] || fail 'Symbolic link destination changed.'")
            }
        }
        if let legacyPlaceholder {
            lines.append(validateLegacyPlaceholder(legacyPlaceholder.path, stat: stat))
        }
        if request.resetDeveloperSelection || request.activeDeveloperPath != nil {
            lines.append("[[ $(\(quote(tools.xcodeSelect)) -p) == \(quote(request.activeDeveloperPath ?? "")) ]] || fail 'Developer selection changed.'")
        }
        if request.recipe == .clt, let preservedDeveloperPath {
            let path = quote(preservedDeveloperPath)
            let contents = quote((preservedDeveloperPath as NSString).deletingLastPathComponent + "/Info.plist")
            lines += ["check_path \(path)",
                "[[ -d \(path) && ! -L \(path) && -d \(path)/Platforms && -x \(path)/usr/bin/xcodebuild && -x \(path)/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang ]] || fail 'The preserved full Xcode is unavailable.'",
                "[[ $(/usr/bin/plutil -extract CFBundleIdentifier raw -o - \(contents)) == com.apple.dt.Xcode ]] || fail 'Xcode identity changed.'",
                "compiler_path=$(/usr/bin/env \(quote("DEVELOPER_DIR=" + preservedDeveloperPath)) \(quote(tools.xcrun)) --find clang) || fail 'The preserved Xcode compiler lookup failed. No cleanup can proceed.'",
                "[[ $compiler_path == \(quote(preservedDeveloperPath + "/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang")) ]] || fail 'Compiler lookup did not resolve to the preserved Xcode.'"]
        }
        lines += ["}", "preflight"]
        lines.append(ShellLiteral.printLine("Preflight complete. Close active build tasks before proceeding."))
        lines += ["printf '%s' 'Type REMOVE to execute this reviewed plan: '", "read -r confirmation",
            "[[ $confirmation == REMOVE ]] || fail 'Execution cancelled; no changes made.'", "preflight"]
        if let residualAction, let residualActionPath, let terminalVerification {
            lines.append(ShellLiteral.printLine(residualAction.reviewSummary))
            lines.append("\(quote(terminalVerification.executablePath)) __quarantine \(quote(residualActionPath)) || fail 'Residual quarantine did not complete; receipts retained. Inspect the recovery record before retrying.'")
        }
        if request.resetDeveloperSelection, let replacement = request.replacementDeveloperPath {
            lines += ["\(quote(tools.xcodeSelect)) --switch \(quote(replacement))",
                "[[ $(\(quote(tools.xcodeSelect)) -p) == \(quote(replacement)) ]] || fail 'Developer selection switch failed.'"]
        }
        // Recheck ancestry immediately before each use; this is not a race-free filesystem executor.
        if ownership != nil {
            // Removing every non-directory first preserves leaf-first order for the remaining directories.
            for type in [CleanupPathEvidence.ItemType.file, .symbolicLink, .directory] {
                for chunk in chunks(removable.filter { $0.itemType == type }, size: 64) {
                    lines.append("paths=(" + chunk.map { quote($0.path) }.joined(separator: " ") + ")")
                    if type != .directory { lines += batchFingerprints(chunk, stat: stat) }
                    lines.append("for candidate in \"${paths[@]}\"; do check_path \"$candidate\"; done")
                    if let legacyPlaceholder, chunk.contains(where: { $0.path == legacyPlaceholder.path }) {
                        lines.append(validateLegacyPlaceholder(legacyPlaceholder.path, stat: stat))
                    }
                    lines.append((type == .directory ? "/bin/rmdir" : "/bin/rm -f") + " \"${paths[@]}\"")
                    lines.append("check_missing \"${paths[@]}\"")
                }
            }
        } else {
            for entry in removable {
                let path = quote(entry.path)
                lines.append("check_path \(path)")
                lines.append(entry.itemType == .directory ? "/bin/rmdir \(path)" : "/bin/rm -f \(path)")
                lines.append("check_missing \(path)")
            }
        }
        if request.recipe == .clt {
            let root = quote(tools.cltContainer)
            lines += ["check_path \(root)", "[[ ! -L \(root) ]] || fail 'CLT container became a symbolic link.'"]
            if plan.entries.contains(where: { $0.path == CLTInspector.directory && $0.reason == .alreadyMissing }) {
                lines.append("check_missing \(root)")
            } else {
                lines.append("if [[ -e \(root) ]]; then /bin/rmdir \(root) || fail 'CLT container is not empty; receipts retained.'; fi")
            }
            lines.append("check_missing \(root)")
            for entry in plan.entries where entry.reason == .installationContainer {
                let path = quote(entry.path)
                lines += ["check_path \(path)", "[[ -d \(path) && ! -L \(path) ]] || fail 'Installation container was not preserved.'"]
            }
            if request.forgetReceipts {
                let payload = plan.entries.filter { $0.reason != .emptyContainer && $0.reason != .installationContainer }
                for chunk in chunks(payload, size: 128) {
                    lines.append("paths=(" + chunk.map { quote($0.path) }.joined(separator: " ") + ")")
                    lines.append("check_missing \"${paths[@]}\"")
                }
            }
        }
        if request.forgetReceipts {
            let receipts = request.recipe == .clt
                ? plan.receipts.filter { $0.packageID != CLTInspector.updateReceiptID }
                    + plan.receipts.filter { $0.packageID == CLTInspector.updateReceiptID }
                : plan.receipts
            for receipt in receipts { lines.append("\(pkgutil) --forget \(quote(receipt.packageID))") }
            if request.recipe == .clt {
                lines += ["receipt_catalog=$(\(pkgutil) --pkgs) || fail 'Could not verify installed package receipts after cleanup.'",
                    "receipt_catalog=$'\\n'\"$receipt_catalog\"$'\\n'"]
                for receipt in plan.receipts {
                    lines.append("[[ $receipt_catalog != *$'\\n'\(quote(receipt.packageID))$'\\n'* ]] || fail \(quote("Receipt is still registered after pkgutil --forget: " + receipt.packageID))")
                }
            }
        }
        lines.append(ShellLiteral.printLine("Commands finished. The CLI will independently verify this frozen plan. Software Update eligibility remains unverified."))
        return lines.joined(separator: "\n") + "\n"
    }

    private func chunks(_ entries: [CleanupPathEvidence], size: Int) -> [[CleanupPathEvidence]] {
        stride(from: 0, to: entries.count, by: size).map { Array(entries[$0..<min($0 + size, entries.count)]) }
    }

    public func validateTerminalReview(_ request: CleanupExecutionRequest, currentVolume: CleanupVolumeIdentity, now: Date, residualAction: ResidualQuarantineAction? = nil) throws {
        if let residualAction { try validateResidual(residualAction, request: request) }
        _ = try validatePlan(request, currentVolume: currentVolume, now: now, allowsTerminalPlaceholder: true)
    }

    private func validateResidual(_ action: ResidualQuarantineAction, request: CleanupExecutionRequest) throws {
        guard request.recipe == .clt, request.cltDirectory == CLTInspector.directory,
              action.path == ResidualQuarantinePlanner.path, action.anchor == "/",
              action.executablesVersion == ResidualQuarantinePlanner.version,
              action.sha256 == ResidualQuarantinePlanner.sha256, action.identity.size == 18_034,
              !request.plan.entries.contains(where: { $0.path == action.path }),
              let evidence = request.plan.ownershipEvidence,
              action.catalogDigest == (try? ResidualQuarantinePlanner.ownershipDigest(evidence)) else {
            throw ExportError.unavailable
        }
    }

    private func validatePlan(_ request: CleanupExecutionRequest, currentVolume: CleanupVolumeIdentity,
                              now: Date, allowsTerminalPlaceholder: Bool) throws -> [CleanupPathEvidence] {
        let plan = request.plan
        guard plan.schemaVersion == 2, !plan.receipts.isEmpty, plan.isCurrent(at: now, volume: currentVolume),
              plan.volume.mountPoint == "/", Set(plan.entries.map(\.path)).count == plan.entries.count,
              plan.entries.filter({ $0.reason == .installationContainer }).allSatisfy({ request.recipe == .clt
                  && (CLTInspector.isInstallationContainer($0.path, itemType: $0.itemType)
                      || ($0.itemType == .directory && ["/private", "/private/tmp"].contains($0.path)
                          && plan.receipts.contains(where: { CLTInspector.isLegacyPlaceholderReceipt($0.packageID) }))) }),
              plan.entries.filter({ $0.reason == .emptyContainer }).allSatisfy({ request.recipe == .clt
                  && $0.path == CLTInspector.directory && $0.itemType == .directory && $0.owners.isEmpty }),
              request.cltDirectory == nil || request.cltDirectory == CLTInspector.directory,
              request.recipe == .clt || (!request.resetDeveloperSelection && request.cltDirectory == nil),
              plan.receipts.allSatisfy({ !$0.packageID.utf8.contains(0) && !$0.version.utf8.contains(0) && !$0.installLocation.utf8.contains(0) }),
              !request.resetDeveloperSelection || (request.activeDeveloperPath == CLTInspector.directory
                  && request.replacementDeveloperPath.map(CLTInspector.isValidatedFullXcodeDeveloperPath) == true),
              request.recipe != .clt || plan.receipts.allSatisfy({ CLTInspector.isCLTReceipt($0.packageID) }) else {
            throw ExportError.unavailable
        }
        let removalByPath = Dictionary(uniqueKeysWithValues: plan.entries.filter { $0.proposesRemoval && $0.reason != .emptyContainer }.map { ($0.path, $0) })
        let removable = CleanupPlanner.sortLeafFirst(Array(removalByPath.keys)).compactMap { removalByPath[$0] }
        let removalSet = Set(plan.receipts.map(\.packageID))
        guard removable.allSatisfy({ entry in
            CleanupPathSafety.isValid(path: entry.path, volume: "/") && !CleanupPlanner.isProtected(path: entry.path)
                && entry.itemType != .unknown && entry.baseline == .present
                && (entry.itemType != .symbolicLink || entry.symbolicLinkTarget != nil)
                && !CleanupPathEvidence.hasSymbolicLinkAncestor(entry.path)
                && !entry.owners.isEmpty && Set(entry.owners).isSubset(of: removalSet)
                && (request.recipe != .clt || entry.path.hasPrefix(CLTInspector.directory + "/")
                    || (entry.path == CLTInspector.directory && entry.itemType == .directory)
                    || (allowsTerminalPlaceholder && plan.ownershipEvidence != nil
                        && CLTInspector.isLegacyPlaceholderPath(entry.path) && entry.itemType == .file
                        && Set(entry.owners) == CLTInspector.legacyPlaceholderReceiptIDs))
        }) else { throw ExportError.unavailable }
        let ownership = plan.ownershipEvidence
        if let ownership {
            if let context = ownership.readContext {
                guard context.coverage == .complete, context.volume == plan.volume,
                      context.observedAt <= plan.generatedAt,
                      now.timeIntervalSince(context.observedAt) <= 1_800 else { throw ExportError.unavailable }
            }
            let ids = ownership.records.map { $0.receipt.packageID }
            let snapshots = Dictionary(ownership.records.map { ($0.receipt.packageID, $0.receipt) }, uniquingKeysWith: { first, _ in first })
            guard ownership.volume == plan.volume, !ownership.records.isEmpty, Set(ids).count == ids.count,
                  ownership.catalogSHA256 == ReceiptOwnershipEvidence(volume: ownership.volume, records: ownership.records).catalogSHA256,
                  plan.receipts.allSatisfy({ snapshots[$0.packageID] == $0 }),
                  ownership.records.allSatisfy({ record in
                      record.filesSHA256.count == 64 && record.filesSHA256.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
                          && !record.receipt.packageID.utf8.contains(0) && !record.receipt.version.utf8.contains(0)
                          && !record.receipt.installLocation.utf8.contains(0)
                  }) else { throw ExportError.unavailable }
        }
        guard !request.dryRun else { return removable }
        if request.recipe == .clt && request.forgetReceipts && plan.entries.contains(where: {
            !$0.proposesRemoval && $0.reason != .alreadyMissing && $0.reason != .installationContainer
        }) { throw ExportError.retainedPayload }
        guard removable.allSatisfy({ $0.fingerprint != nil }) else { throw ExportError.unavailable }
        return removable
    }

    private func validateLegacyPlaceholder(_ path: String, stat: String) -> String {
        // The sticky temporary directory permits other users to create names. Require the original
        // root-owned regular file and a single link immediately before unlinking it.
        let leaf = ShellLiteral.quote(path)
        return "[[ -f \(leaf) && ! -L \(leaf) && $(\(stat) -f '%u:%g:%l:%Lp' \(leaf)) == 0:0:1:644 ]] || fail 'Legacy SDK placeholder changed.'"
    }

    private func batchFingerprints(_ entries: [CleanupPathEvidence], stat: String) -> [String] {
        let expected = entries.compactMap(\.fingerprint).joined(separator: "\n")
        return [ShellLiteral.printLine(expected) + " > \"$work/fingerprints.expected\"",
            "\(stat) -f '%m:%z:%i:%d:%p' \"${paths[@]}\" > \"$work/fingerprints.actual\"",
            "/usr/bin/cmp -s \"$work/fingerprints.expected\" \"$work/fingerprints.actual\" || fail 'Path changed since planning.'"]
    }

    private func batchPreflight(_ entries: [CleanupPathEvidence], stat: String) -> [String] {
        var lines: [String] = []
        for type in [CleanupPathEvidence.ItemType.file, .symbolicLink, .directory] {
            for chunk in chunks(entries.filter { $0.itemType == type }, size: 128) {
                lines.append("paths=(" + chunk.map { ShellLiteral.quote($0.path) }.joined(separator: " ") + ")")
                let leaf = type == .symbolicLink ? "[[ -L \"$candidate\" ]]" : (type == .directory ? "[[ -d \"$candidate\" && ! -L \"$candidate\" ]]" : "[[ -f \"$candidate\" && ! -L \"$candidate\" ]]")
                lines.append("for candidate in \"${paths[@]}\"; do check_path \"$candidate\"; " + leaf + " || fail 'Leaf type changed.'; done")
                lines += batchFingerprints(chunk, stat: stat)
                if type == .symbolicLink {
                    for entry in chunk {
                        lines.append("[[ $(/usr/bin/readlink \(ShellLiteral.quote(entry.path))) == \(ShellLiteral.quote(entry.symbolicLinkTarget!)) ]] || fail 'Symbolic link destination changed.'")
                    }
                }
            }
        }
        return lines
    }

}
