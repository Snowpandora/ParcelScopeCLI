import Foundation

public struct CLTEnvironment: Sendable, Equatable {
    public let directory: FileObservation
    public let activeDeveloperPath: String?
    public let compilerAvailable: Bool?
    public let diagnostics: [ReceiptDiagnostic]
    public init(directory: FileObservation, activeDeveloperPath: String?, compilerAvailable: Bool?, diagnostics: [ReceiptDiagnostic] = []) {
        self.directory = directory
        self.activeDeveloperPath = activeDeveloperPath
        self.compilerAvailable = compilerAvailable
        self.diagnostics = diagnostics
    }
}

public struct CLTInspection: Sendable {
    public let environment: CLTEnvironment
    public let receiptIDs: [PackageID]
    public let warning: String?
    public var hasInconsistency: Bool {
        environment.directory == .missing && !receiptIDs.isEmpty
    }
}

public struct CLTInspector: Sendable {
    public static let directory = "/Library/Developer/CommandLineTools"
    public static let updateReceiptID = "com.apple.dt.commandlinetools"
    public init() {}
    public static func isCLTReceipt(_ raw: String) -> Bool {
        raw == updateReceiptID || raw == "com.apple.pkg.CLTools_SDK_macOS_NMOS" || raw == "com.apple.pkg.CLTools_SDK_macOS_LMOS"
            || raw == "com.apple.pkg.CLTools_SwiftBackDeploy" || raw == "com.apple.pkg.CLTools_Executables" || raw == "com.apple.pkg.CLTools_macOS_SDK"
            || (raw.hasPrefix("com.apple.pkg.CLTools_SDK_macOS") && !raw.dropFirst("com.apple.pkg.CLTools_SDK_macOS".count).isEmpty && raw.dropFirst("com.apple.pkg.CLTools_SDK_macOS".count).allSatisfy(\.isNumber))
    }
    public static let legacyPlaceholderReceiptIDs: Set<String> = [
        "com.apple.pkg.CLTools_SDK_macOS110", "com.apple.pkg.CLTools_SDK_macOS12",
        "com.apple.pkg.CLTools_SDK_macOS13", "com.apple.pkg.CLTools_SDK_macOS14"
    ]

    public static func isLegacyPlaceholderReceipt(_ id: String) -> Bool {
        legacyPlaceholderReceiptIDs.contains(id)
    }

    public static func isLegacyPlaceholderPath(_ path: String) -> Bool {
        let prefix = "/private/tmp/."
        guard path.hasPrefix(prefix) else { return false }
        let hash = path.utf8.dropFirst(prefix.utf8.count)
        return hash.count == 64 && hash.allSatisfy { (48...57).contains($0) || (65...70).contains($0) }
    }
    public static func legacyPlaceholderLeaf(id: String, all: [ReceiptFile], files: [ReceiptFile], directories: [ReceiptFile]) -> String? {
        guard isLegacyPlaceholderReceipt(id), all.count == 3, files.count == 1, directories.count == 2,
              Set(directories.map(\.relativePath)) == ["private", "private/tmp"],
              let leaf = files.first?.relativePath, isLegacyPlaceholderPath("/" + leaf),
              Set(all.map(\.relativePath)) == ["private", "private/tmp", leaf] else { return nil }
        return "/" + leaf
    }
    public static func isInstallationContainer(_ path: String, itemType: CleanupPathEvidence.ItemType) -> Bool {
        itemType == .directory && (path == "/Library" || path == "/Library/Developer")
    }
    public static func isValidatedFullXcodeDeveloperPath(_ path: String) -> Bool {
        guard path.hasSuffix(".app/Contents/Developer"), CleanupPathSafety.isLexicallyValid(path: path, volume: "/"),
              !CleanupPathEvidence.isSymbolicLink(path), !CleanupPathEvidence.hasSymbolicLinkAncestor(path) else { return false }
        let bundle = (path as NSString).deletingLastPathComponent
        guard let data = FileManager.default.contents(atPath: bundle + "/Info.plist"),
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              info["CFBundleIdentifier"] as? String == "com.apple.dt.Xcode" else { return false }
        return FileManager.default.isExecutableFile(atPath: path + "/usr/bin/xcodebuild")
            && FileManager.default.isExecutableFile(atPath: path + "/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang")
            && FileExistenceCache.inspect(path + "/Platforms") == .present
    }
    public static func environment() async -> CLTEnvironment {
        await environment(runner: ProcessRunner())
    }
    public static func environment(runner: any ProcessExecuting,
                            observe: @Sendable (String) -> FileObservation = FileExistenceCache.inspect,
                            isExecutable: @Sendable (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) }) async -> CLTEnvironment {
        var diagnostics: [ReceiptDiagnostic] = []
        var path: String?
        var compilerAvailable: Bool?
        do {
            let selection = try await runner.run(path: "/usr/bin/xcode-select", arguments: ["-p"])
            let selected = String(data: selection.stdout, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let selected, selected.hasPrefix("/"), !selected.contains("\n") else { throw ReceiptReadError.invalidOutput("xcode-select -p") }
            path = selected
        } catch {
            diagnostics.append(.init(kind: .unreadableStore, resource: "xcode-select -p", message: "Developer selection could not be read: \(error.localizedDescription)"))
        }
        // Invoking xcrun on a tool-free Mac can prompt to install the tools being removed.
        if let path {
            let candidate: String?
            if path == directory { candidate = directory + "/usr/bin/clang" }
            else if isValidatedFullXcodeDeveloperPath(path) {
                candidate = path + "/Toolchains/XcodeDefault.xctoolchain/usr/bin/clang"
            } else { candidate = nil }
            if let candidate, observe(candidate) == .present, isExecutable(candidate) {
                compilerAvailable = true
            }
        }
        return CLTEnvironment(directory: observe(directory), activeDeveloperPath: path,
            compilerAvailable: compilerAvailable, diagnostics: diagnostics)
    }
    public func inspect(repository: any PackageRepository, volume: String,
                        environment: CLTEnvironment) async throws -> CLTInspection {
        let catalog = try await repository.fetchCatalog()
        try catalog.requireComplete()
        let ids = catalog.packages.filter { Self.isCLTReceipt($0.rawValue) }.sorted { $0.rawValue < $1.rawValue }
        return CLTInspection(environment: environment, receiptIDs: ids, warning: volume == "/" ? nil : "CLT reset supports the startup volume only.")
    }
}
