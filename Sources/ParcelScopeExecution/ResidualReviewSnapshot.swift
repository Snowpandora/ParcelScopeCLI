import Foundation

/// Every review freezes either an approved residual action or its observed absence.
public struct ResidualReviewSnapshot: Codable, Sendable, Equatable {
    public var action: ResidualQuarantineAction?
    public init(action: ResidualQuarantineAction?) { self.action = action }
    public func validate(current: ResidualQuarantineAction?) throws {
        guard action == current else { throw ResidualQuarantineError.unsafeOrChanged }
    }
}
