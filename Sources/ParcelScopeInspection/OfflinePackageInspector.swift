import Foundation

public struct OfflineInspectionResult: Sendable {
    public let metadata: OfflinePackageMetadata?
    public let errors: [String]
}

/// Protocol abstraction for executing system commands required for offline package inspection.
public protocol OfflineCommandRunning: Sendable {
    func run(path: String, arguments: [String]) async throws -> String
}

/// Default system command runner executing processes directly without shell interpolation.
public struct SystemOfflineCommandRunner: OfflineCommandRunning {
    public init() {}

    public func run(path: String, arguments: [String]) async throws -> String {
        let runner = ProcessRunner()
        let result = try await runner.run(path: path, arguments: arguments)
        return String(data: result.stdout, encoding: .utf8) ?? ""
    }
}

/// Inspector for offline, uninstalled `.pkg` packages using system `xar` and `pkgutil --check-signature`.
public final class OfflinePackageInspector: Sendable {
    private let runner: any OfflineCommandRunning

    public init(runner: any OfflineCommandRunning = SystemOfflineCommandRunner()) {
        self.runner = runner
    }

    public func inspectResult(pkgPath: String) async -> OfflineInspectionResult {
        let entries: [String]
        do {
            let output = try await runner.run(path: "/usr/bin/xar", arguments: ["-t", "-f", pkgPath])
            entries = output.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        } catch {
            return OfflineInspectionResult(metadata: nil, errors: ["Could not read archive contents. " + diagnostic(error)])
        }
        var signature: String?
        var errors: [String] = []
        do {
            let output = try await runner.run(path: "/usr/sbin/pkgutil", arguments: ["--check-signature", pkgPath])
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            signature = trimmed.isEmpty ? nil : trimmed
            if signature == nil { errors.append("Signature status was not returned.") }
        } catch {
            errors.append("Signature could not be verified. " + diagnostic(error))
        }
        return OfflineInspectionResult(metadata: OfflinePackageMetadata(path: pkgPath,
            title: URL(fileURLWithPath: pkgPath).deletingPathExtension().lastPathComponent,
            entries: entries, signatureInfo: signature), errors: errors)
    }

    private func diagnostic(_ error: Error) -> String {
        guard let processError = error as? ProcessRunner.ProcessError else { return error.localizedDescription }
        switch processError {
        case .executionFailed(let message): return "The check could not start. " + message
        case .nonZeroExitCode(_, let detail):
            return detail.trimmingCharacters(in: .whitespacesAndNewlines)
        case .timedOut: return "The check took too long. Try again."
        }
    }

    /// Inspects an offline `.pkg` file at the specified filesystem path.
    public func inspect(pkgPath: String) async -> OfflinePackageMetadata {
        async let entriesTask = fetchEntries(pkgPath: pkgPath)
        async let signatureTask = fetchSignature(pkgPath: pkgPath)

        let entries = await entriesTask
        let signature = await signatureTask

        return OfflinePackageMetadata(
            path: pkgPath,
            packageID: nil,
            version: nil,
            title: URL(fileURLWithPath: pkgPath).deletingPathExtension().lastPathComponent,
            entries: entries,
            signatureInfo: signature,
            scripts: []
        )
    }

    /// Lists table of contents inside the xar package.
    public func fetchEntries(pkgPath: String) async -> [String] {
        do {
            let output = try await runner.run(path: "/usr/bin/xar", arguments: ["-t", "-f", pkgPath])
            return output
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        } catch {
            return []
        }
    }

    /// Queries Developer ID and Apple certificate chain signature via pkgutil.
    public func fetchSignature(pkgPath: String) async -> String? {
        do {
            let output = try await runner.run(path: "/usr/sbin/pkgutil", arguments: ["--check-signature", pkgPath])
            let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        } catch {
            return nil
        }
    }

    /// Extracts package identifier and version from PackageInfo XML text.
    public func parsePackageInfo(_ xml: String) -> (packageID: String?, version: String?) {
        var packageID: String?
        var version: String?

        // Match identifier="..."
        if let idRange = xml.range(of: #"(?:^|\s)identifier="([^"]+)""#, options: .regularExpression) {
            let matched = String(xml[idRange])
            packageID = extractAttributeValue(from: matched)
        }

        // Match version="..." avoiding format-version
        if let verRange = xml.range(of: #"(?:^|\s)version="([^"]+)""#, options: .regularExpression) {
            let matched = String(xml[verRange])
            version = extractAttributeValue(from: matched)
        }

        return (packageID, version)
    }

    private func extractAttributeValue(from attributePair: String) -> String? {
        guard let firstQuote = attributePair.firstIndex(of: "\""),
              let lastQuote = attributePair.lastIndex(of: "\""),
              firstQuote != lastQuote else {
            return nil
        }
        let afterFirst = attributePair.index(after: firstQuote)
        return String(attributePair[afterFirst..<lastQuote])
    }
}
