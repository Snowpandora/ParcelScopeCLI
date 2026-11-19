import Foundation
import ParcelScopeInspection

public enum CLTReviewPresentation {
    public static func targetReceipts(_ receipts: [ReceiptSnapshot]) -> String {
        let ids = receipts.map(\.packageID).sorted()
        return "Target receipt IDs (\(ids.count)):\n" + ids.map { "  " + $0 + "\n" }.joined()
    }

    public static func retrySummary(_ report: CleanupVerificationReport) -> String {
        let observations = Dictionary(report.receipts.map { ($0.packageID, $0.observation) }, uniquingKeysWith: { first, _ in first })
        let outstanding = report.request.plan.receipts.map(\.packageID).sorted().compactMap { id -> String? in
            let observation = observations[id] ?? "unverified"
            return observation == "absent" ? nil : "  " + id + ": " + observation
        }
        return outstanding.isEmpty ? "All target receipts were observed absent."
            : "Target receipts remaining or unverified:\n" + outstanding.joined(separator: "\n")
    }
}
