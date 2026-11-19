import Foundation

public enum PackageSearch {
    public static func filter(_ packages: [PackageID], matching query: String) throws -> [PackageID] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return packages
        }

        let regex: NSRegularExpression
        do {
            regex = try NSRegularExpression(pattern: trimmedQuery, options: [.caseInsensitive])
        } catch {
            throw PackageSearchError.invalidPattern(trimmedQuery)
        }

        return packages.filter { packageID in
            let candidate = packageID.rawValue
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            return regex.firstMatch(in: candidate, options: [], range: range) != nil
        }
    }

    /// Case-insensitive literal substring filtering.
    public static func filterLiteral(_ packages: [PackageID], matching query: String) -> [PackageID] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return packages
        }
        return packages.filter {
            $0.rawValue.localizedCaseInsensitiveContains(trimmedQuery)
        }
    }

    /// Resilient search that uses regex if enclosed in `/.../` or falls back to literal substring matching.
    public static func filterSmart(_ packages: [PackageID], matching query: String) -> [PackageID] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            return packages
        }

        if trimmedQuery.hasPrefix("/") && trimmedQuery.hasSuffix("/") && trimmedQuery.count > 1 {
            let pattern = String(trimmedQuery.dropFirst().dropLast())
            if let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
                return packages.filter { pkg in
                    let candidate = pkg.rawValue
                    let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
                    return regex.firstMatch(in: candidate, options: [], range: range) != nil
                }
            }
        }

        return filterLiteral(packages, matching: trimmedQuery)
    }
}

public enum PackageSearchError: LocalizedError, Equatable {
    case invalidPattern(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPattern(let pattern):
            return "Invalid package search pattern: \(pattern)"
        }
    }
}
