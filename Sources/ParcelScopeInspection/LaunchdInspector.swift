import Foundation

/// Protocol abstraction for querying system launchd state.
public protocol LaunchdCommandRunning: Sendable {
    func list() async throws -> String
}

/// Default system runner invoking `/bin/launchctl list`.
public struct SystemLaunchdCommandRunner: LaunchdCommandRunning {
    public init() {}

    public func list() async throws -> String {
        let runner = ProcessRunner()
        let result = try await runner.run(path: "/bin/launchctl", arguments: ["list"])
        return String(data: result.stdout, encoding: .utf8) ?? ""
    }
}

/// Service that discovers launchd plist registrations in a package and inspects their active state.
public final class LaunchdInspector: Sendable {
    private let runner: any LaunchdCommandRunning

    public init(runner: any LaunchdCommandRunning = SystemLaunchdCommandRunner()) {
        self.runner = runner
    }

    /// Inspects the receipt's files for launchd registrations and checks whether they are currently loaded or running.
    public func inspect(receipt: PackageReceipt, files: [ReceiptFile]) async -> [LaunchdService] {
        let plistFiles = files.filter { LaunchdService.isLaunchdPlistPath($0.relativePath) }
        guard !plistFiles.isEmpty else { return [] }

        let activeTable: [String: (pid: pid_t?, status: Int32)]
        do {
            let output = try await runner.list()
            activeTable = parseLaunchctlList(output)
        } catch {
            activeTable = [:]
        }

        var results: [LaunchdService] = []

        for file in plistFiles {
            let fullURL = receipt.absoluteURL(for: file)
            let inferredLabel = fullURL.deletingPathExtension().lastPathComponent
            let isDaemon = LaunchdService.isDaemonPath(file.relativePath)

            let entry = activeTable[inferredLabel]
            let isLoaded = entry != nil
            let pid = entry?.pid

            results.append(
                LaunchdService(
                    label: inferredLabel,
                    plistPath: fullURL.path,
                    isDaemon: isDaemon,
                    isLoaded: isLoaded,
                    pid: pid
                )
            )
        }

        return results.sorted { $0.label < $1.label }
    }

    /// Parses the tab-delimited output from `launchctl list`.
    public func parseLaunchctlList(_ output: String) -> [String: (pid: pid_t?, status: Int32)] {
        var table: [String: (pid: pid_t?, status: Int32)] = [:]
        let lines = output.components(separatedBy: .newlines)

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = line.components(separatedBy: "\t")
            guard parts.count >= 3 else { continue }

            let pidString = parts[0].trimmingCharacters(in: .whitespaces)
            let statusString = parts[1].trimmingCharacters(in: .whitespaces)
            let label = parts[2].trimmingCharacters(in: .whitespaces)

            guard label != "Label" else { continue } // skip header

            let pid: pid_t? = pidString == "-" ? nil : pid_t(pidString)
            let status = Int32(statusString) ?? 0

            table[label] = (pid: pid, status: status)
        }

        return table
    }
}
