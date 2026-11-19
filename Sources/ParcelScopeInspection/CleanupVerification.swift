import Foundation

public struct CleanupExecutionRequest: Sendable, Codable, Equatable, Identifiable {
    public enum Recipe: String, Sendable, Codable { case ordinary, clt }
    public let recipe: Recipe
    public var id: UUID { plan.id }
    public let plan: CleanupEvidencePlan
    public let dryRun: Bool
    public let forgetReceipts: Bool
    public let resetDeveloperSelection: Bool
    public let cltDirectory: String?
    public let activeDeveloperPath: String?
    public let replacementDeveloperPath: String?

    public init(plan: CleanupEvidencePlan, dryRun: Bool = true, forgetReceipts: Bool = false,
                resetDeveloperSelection: Bool = false, cltDirectory: String? = nil,
                activeDeveloperPath: String? = nil, replacementDeveloperPath: String? = nil, recipe: Recipe? = nil) {
        self.recipe = recipe ?? (cltDirectory == nil ? .ordinary : .clt)
        self.plan = plan
        self.dryRun = dryRun
        self.forgetReceipts = forgetReceipts
        self.resetDeveloperSelection = resetDeveloperSelection
        self.cltDirectory = cltDirectory
        self.activeDeveloperPath = activeDeveloperPath
        self.replacementDeveloperPath = replacementDeveloperPath
    }
    private enum CodingKeys: String, CodingKey {
        case recipe, plan, dryRun, forgetReceipts, resetDeveloperSelection, cltDirectory, activeDeveloperPath, replacementDeveloperPath
    }
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        let directory = try values.decodeIfPresent(String.self, forKey: .cltDirectory)
        self.init(plan: try values.decode(CleanupEvidencePlan.self, forKey: .plan),
            dryRun: try values.decode(Bool.self, forKey: .dryRun),
            forgetReceipts: try values.decode(Bool.self, forKey: .forgetReceipts),
            resetDeveloperSelection: try values.decode(Bool.self, forKey: .resetDeveloperSelection),
            cltDirectory: directory,
            activeDeveloperPath: try values.decodeIfPresent(String.self, forKey: .activeDeveloperPath),
            replacementDeveloperPath: try values.decodeIfPresent(String.self, forKey: .replacementDeveloperPath),
            recipe: try values.decodeIfPresent(Recipe.self, forKey: .recipe))
    }

}

public struct CleanupVerificationReport: Sendable, Codable, Equatable, Identifiable {
    public enum Outcome: String, Sendable, Codable { case verified, partial, failed, unchanged, unknown, stale, simulation }
    public enum PathOutcome: String, Sendable, Codable { case newlyAbsent, alreadyAbsent, retained, stillPresent, unavailable }
    public struct PathResult: Sendable, Codable, Equatable {
        public let path: String
        public let outcome: PathOutcome
    }
    public struct ReceiptResult: Sendable, Codable, Equatable {
        public let packageID: String
        public let observation: String
    }
    public let schemaVersion: Int
    public let id: UUID
    public let request: CleanupExecutionRequest
    public let observedAt: Date
    public let outcome: Outcome
    public let paths: [PathResult]
    public let receipts: [ReceiptResult]
    public let notes: [String]

    public init(request: CleanupExecutionRequest, outcome: Outcome, paths: [PathResult] = [],
                receipts: [ReceiptResult] = [], notes: [String] = []) {
        schemaVersion = 2
        id = UUID()
        self.request = request
        observedAt = Date()
        self.outcome = outcome
        self.paths = paths
        self.receipts = receipts
        self.notes = notes
    }

    public var summary: String { renderSummary(limit: nil) }
    public var previewSummary: String { renderSummary(limit: 100) }

    private func renderSummary(limit: Int?) -> String {
        let evidence = Dictionary(request.plan.entries.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        let shownPaths = limit.map { Array(paths.prefix($0)) } ?? paths
        let shownReceipts = limit.map { Array(receipts.prefix($0)) } ?? receipts
        var lines = ["Observation report: \(outcome.rawValue)", "Plan: \(request.id.uuidString)",
            "Volume: \(request.plan.volume.mountPoint)", "Observed: \(observedAt.formatted(.iso8601))",
            "Options: simulation=\(request.dryRun), forget receipts=\(request.forgetReceipts), reset developer selection=\(request.resetDeveloperSelection)",
            "Absence is an observation, not proof of which process removed a path."]
        lines += shownPaths.map { result in
            let entry = evidence[result.path]
            return "\(result.outcome.rawValue): \(result.path) · planned=\(entry?.reason.rawValue ?? "unknown") · owners=\(entry?.owners.joined(separator: ", ") ?? "unknown")"
        }
        lines += shownReceipts.map { "Receipt \($0.packageID): \($0.observation)" }
        lines += notes
        if let limit, paths.count > limit || receipts.count > limit {
            lines.append("Preview truncated. Copy Summary or save JSON for all \(paths.count) paths and \(receipts.count) receipts.")
        }
        return lines.joined(separator: "\n")
    }

    public func jsonData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
