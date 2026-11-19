import Foundation

/// Parser for pkgutil command output.
public enum PkgutilParser {
    public static func parsePackageIDsStrict(_ data: Data) throws -> [PackageID] {
        guard let text = String(data: data, encoding: .utf8) else { throw ParserError.invalidFormat }
        let lines = text.components(separatedBy: .newlines).filter { !$0.isEmpty }
        guard lines.allSatisfy({ !$0.hasPrefix("-") && !$0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }) else {
            throw ParserError.invalidFormat
        }
        return try lines.map { try PackageID($0) }
    }
    /// Parses the output of `pkgutil --pkg-info-plist`.
    public static func parsePackageInfo(_ data: Data, packageID: PackageID) throws -> PackageReceipt {
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw ParserError.invalidFormat
        }

        let version = plist["pkg-version"] as? String ?? "unknown"
        let volume = plist["volume"] as? String ?? "/"
        let location = plist["install-location"] as? String ?? "/"
        let installTimeInterval = timeInterval(from: plist["install-time"]) ?? 0
        let installTime = Date(timeIntervalSince1970: installTimeInterval)
        let groups = (plist["groups"] as? [String] ?? []).sorted()

        // M2 logic: SIP identification (simple version for now)
        let isSystemProtected = packageID.rawValue.starts(with: "com.apple.pkg.")

        return PackageReceipt(
            id: packageID,
            version: version,
            volume: volume,
            installLocation: location,
            installTime: installTime,
            groups: groups,
            isSystemProtected: isSystemProtected
        )
    }

    /// Parses the output of `pkgutil --files`.
    public static func parseFiles(_ data: Data) -> [ReceiptFile] {
        let content = String(data: data, encoding: .utf8) ?? ""
        return content.components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
            .map { ReceiptFile(relativePath: $0) }
    }

    /// Parses plist output from `pkgutil --groups-plist`.
    public static func parseGroups(_ data: Data) throws -> [String] {
        guard let groups = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String] else {
            throw ParserError.invalidFormat
        }

        return groups.sorted()
    }

    /// Parses newline-delimited group identifiers from `pkgutil --pkg-groups <id>`.
    public static func parsePackageGroups(_ data: Data) -> [String] {
        let content = String(data: data, encoding: .utf8) ?? ""
        return content.components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()
    }

    /// Parses newline-delimited package identifiers.
    public static func parsePackageIDs(_ data: Data) throws -> [PackageID] {
        let content = String(data: data, encoding: .utf8) ?? ""
        return try content.components(separatedBy: .newlines)
            .filter { !$0.isEmpty }
            .map { try PackageID($0) }
    }

    /// Parses plist output from `pkgutil --file-info-plist`.
    public static func parseFileInfo(_ data: Data, queriedPath: String? = nil) throws -> FileLookupResult {
        guard let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any],
              let path = (plist["path"] as? String) ?? queriedPath,
              let entries = plist["path-info"] as? [[String: Any]] else {
            throw ParserError.invalidFormat
        }

        let owners = try entries.map { entry in
            guard let rawPackageID = entry["pkgid"] as? String else {
                throw ParserError.invalidFormat
            }

            let installTime = timeInterval(from: entry["install-time"]).map {
                Date(timeIntervalSince1970: $0)
            }

            return FileOwner(
                packageID: try PackageID(rawPackageID),
                version: entry["pkg-version"] as? String,
                installTime: installTime
            )
        }

        return FileLookupResult(path: path, owners: owners)
    }

    public enum ParserError: Error {
        case invalidFormat
    }

    private static func timeInterval(from value: Any?) -> TimeInterval? {
        if let value = value as? TimeInterval {
            return value
        }

        if let value = value as? NSNumber {
            return value.doubleValue
        }

        return nil
    }
}
