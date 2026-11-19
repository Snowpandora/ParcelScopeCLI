import Foundation

/// The result of evaluating whether a package is permitted to be forgotten.
public enum ForgetPolicyResult: Sendable, Equatable {
    case allowed
    case blocked(reason: String)

    public var isAllowed: Bool {
        if case .allowed = self { return true }
        return false
    }

    public var blockReason: String? {
        if case let .blocked(reason) = self { return reason }
        return nil
    }
}
