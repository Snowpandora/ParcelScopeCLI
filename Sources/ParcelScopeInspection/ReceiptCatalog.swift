import Foundation

public enum ReceiptCoverage: String, Sendable, Codable {
    case complete, partial, unavailable
}

public struct ReceiptDiagnostic: Sendable, Codable, Equatable {
    public enum Kind: String, Sendable, Codable {
        case accessDenied, unreadableStore, unsupportedLayout, invalidData, inconsistentResults, changedDuringRead, duplicateIdentifier
    }
    public let kind: Kind
    public let resource: String
    public let message: String

    public init(kind: Kind, resource: String, message: String) {
        self.kind = kind
        self.resource = resource
        self.message = message
    }
}

public struct ReceiptCatalog: Sendable {
    public let packages: [PackageID]
    public let coverage: ReceiptCoverage
    public let volume: CleanupVolumeIdentity
    public let observedAt: Date
    public let generation: UUID
    public let diagnostics: [ReceiptDiagnostic]
    public var context: ReceiptReadContext {
        ReceiptReadContext(coverage: coverage, volume: volume, observedAt: observedAt, generation: generation)
    }

    public init(packages: [PackageID], coverage: ReceiptCoverage, volume: CleanupVolumeIdentity,
                observedAt: Date = Date(), generation: UUID = UUID(), diagnostics: [ReceiptDiagnostic] = []) {
        self.packages = packages
        self.coverage = coverage
        self.volume = volume
        self.observedAt = observedAt
        self.generation = generation
        self.diagnostics = diagnostics
    }

    public func requireComplete() throws {
        guard coverage == .complete else { throw ReceiptReadError.incomplete(diagnostics) }
    }
}

public struct ReceiptReadContext: Sendable, Codable, Equatable {
    public let coverage: ReceiptCoverage
    public let volume: CleanupVolumeIdentity
    public let observedAt: Date
    public let generation: UUID
    public init(coverage: ReceiptCoverage, volume: CleanupVolumeIdentity, observedAt: Date, generation: UUID) {
        self.coverage = coverage
        self.volume = volume
        self.observedAt = observedAt
        self.generation = generation
    }
}

public enum ReceiptReadError: LocalizedError, Sendable {
    case incomplete([ReceiptDiagnostic])
    case changedDuringRead
    case invalidOutput(String)

    public var errorDescription: String? {
        switch self {
        case .incomplete(let diagnostics):
            diagnostics.first(where: { $0.kind == .duplicateIdentifier })?.message
                ?? diagnostics.first?.message
                ?? "The installed package receipts could not be read completely."
        case .changedDuringRead:
            "Installed package records or their access changed during inspection. Refresh and review a new plan."
        case .invalidOutput(let command):
            "The installed package query returned invalid data: \(command)."
        }
    }
}
