import Foundation
import Darwin

/// A compatibility check of known receipt stores, never an alternate receipt database.
/// pkgutil remains the query authority; unexplained layouts fail closed.
public struct ReceiptStoreSnapshot: Sendable, Equatable {
    public let packageIDs: Set<String>
    public let fileInventoryPackageIDs: Set<String>
    public let fingerprints: [String: String]
    public let diagnostics: [ReceiptDiagnostic]
    let inventoryPaths: [String: Set<String>]
    private var validatedBOMs: [String: ValidatedBOM] = [:]

    private struct ValidatedBOM: Sendable, Equatable {
        let fingerprint: String
        let paths: Set<String>
    }

    public init(packageIDs: Set<String>, fingerprints: [String: String], diagnostics: [ReceiptDiagnostic] = [], fileInventoryPackageIDs: Set<String>? = nil,
                inventoryPaths: [String: Set<String>] = [:]) {
        self.packageIDs = packageIDs
        self.fileInventoryPackageIDs = fileInventoryPackageIDs ?? packageIDs
        self.fingerprints = fingerprints
        self.diagnostics = diagnostics
        self.inventoryPaths = inventoryPaths
    }

    public var isComplete: Bool { diagnostics.isEmpty }

    public static func paths(volume: String) -> [String] {
        let prefix = volume == "/" ? "" : volume.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let root = prefix.isEmpty ? "" : "/" + prefix
        return ["/private/var/db/receipts", "/Library/Apple/System/Library/Receipts",
                "/System/Library/Receipts", "/Library/Receipts"].map { root + $0 }
    }

    public static func capture(volume: String = "/") -> Self {
        capture(paths: paths(volume: volume))
    }

    static func makeReader(volume: String) -> @Sendable () -> Self {
        let reader = Reader(volume: volume)
        return { reader.capture() }
    }

    static func capture(paths: [String]) -> Self { capture(paths: paths, reusing: nil) }

    private static func capture(paths: [String], reusing previous: Self?) -> Self {
        var ids: Set<String> = []
        var inventoryIDs: Set<String> = []
        var fingerprints: [String: String] = [:]
        var diagnostics: [ReceiptDiagnostic] = []
        var inventoryPaths: [String: Set<String>] = [:]
        var validatedBOMs: [String: ValidatedBOM] = [:]
        func diagnose(_ kind: ReceiptDiagnostic.Kind, _ path: String, _ message: String) {
            diagnostics.append(.init(kind: kind, resource: path, message: message))
        }
        func diagnoseReadFailure(
            _ error: Error, at path: String, message: String, fallback: ReceiptDiagnostic.Kind = .unreadableStore
        ) {
            if case .changedDuringRead? = error as? ReceiptReadError {
                diagnose(.changedDuringRead, path, message)
                return
            }
            let reportedError = error as NSError
            // FileHandle can wrap a read failure with a misleading Cocoa error code.
            let failure: NSError
            if let underlying = reportedError.userInfo[NSUnderlyingErrorKey] as? NSError,
               underlying.domain == NSPOSIXErrorDomain {
                failure = underlying
            } else {
                failure = reportedError
            }
            switch (failure.domain, failure.code) {
            case (NSPOSIXErrorDomain, Int(EACCES)), (NSPOSIXErrorDomain, Int(EPERM)),
                 (NSCocoaErrorDomain, NSFileReadNoPermissionError):
                diagnose(.accessDenied, path, message)
            case (NSPOSIXErrorDomain, Int(ENOENT)),
                 (NSCocoaErrorDomain, NSFileReadNoSuchFileError), (NSCocoaErrorDomain, NSFileNoSuchFileError):
                diagnose(.changedDuringRead, path, message)
            default:
                diagnose(fallback, path, message)
            }
        }

        for path in paths {
            var metadata = stat()
            if lstat(path, &metadata) != 0 {
                let errorCode = errno
                if errorCode == ENOENT {
                    fingerprints[path] = "absent"
                } else {
                    let error = POSIXError(POSIXErrorCode(rawValue: errorCode) ?? .EIO)
                    diagnoseReadFailure(error, at: path, message: "The receipt store could not be inspected.")
                }
                continue
            }
            guard metadata.st_mode & S_IFMT == S_IFDIR else {
                diagnose(.unsupportedLayout, path, "Expected a receipt directory without symbolic links.")
                continue
            }
            fingerprints[path] = fingerprint(metadata)
            do {
                let children = try FileManager.default.contentsOfDirectory(atPath: path).sorted()
                var plistStems: Set<String> = [], bomStems: Set<String> = []
                var idsByStem: [String: String] = [:]
                var pathsByStem: [String: Set<String>] = [:]
                for name in children where name != ".DS_Store" {
                    let child = path + "/" + name
                    var item = stat()
                    guard lstat(child, &item) == 0 else {
                        let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                        diagnoseReadFailure(error, at: child, message: "A receipt entry changed or could not be read.")
                        continue
                    }
                    fingerprints[child] = fingerprint(item)
                    if name == "db", path.hasSuffix("/Library/Receipts"), item.st_mode & S_IFMT == S_IFDIR {
                        if try !FileManager.default.contentsOfDirectory(atPath: child).isEmpty {
                            diagnose(.unsupportedLayout, child, "The legacy receipt database layout is not validated.")
                        }
                        continue
                    }
                    guard item.st_mode & S_IFMT == S_IFREG else {
                        diagnose(.unsupportedLayout, child, "The receipt layout contains an unsupported entry.")
                        continue
                    }
                    if name == "InstallHistory.plist", path.hasSuffix("/Library/Receipts") { continue }
                    switch (name as NSString).pathExtension {
                    case "plist":
                        plistStems.insert((name as NSString).deletingPathExtension)
                        do {
                            guard let value = try PropertyListSerialization.propertyList(from: Data(contentsOf: URL(fileURLWithPath: child)), options: [], format: nil) as? [String: Any],
                                  let id = value["PackageIdentifier"] as? String,
                                  (try? PackageID(id)) != nil else {
                                diagnose(.invalidData, child, "The receipt identifier could not be decoded.")
                                continue
                            }
                            ids.insert(id)
                            idsByStem[(name as NSString).deletingPathExtension] = id
                        } catch {
                            diagnoseReadFailure(error, at: child, message: "Receipt metadata could not be read.")
                        }
                    case "bom":
                        bomStems.insert((name as NSString).deletingPathExtension)
                        do {
                            let handle = try FileHandle(forReadingFrom: URL(fileURLWithPath: child))
                            defer { try? handle.close() }
                            var opened = stat()
                            guard fstat(handle.fileDescriptor, &opened) == 0, fingerprint(opened) == fingerprint(item) else { throw ReceiptReadError.changedDuringRead }
                            let header = try handle.read(upToCount: 32) ?? Data()
                            let cached = previous?.validatedBOMs[child]
                            let paths: Set<String>
                            if header.count == 32, header.prefix(8) == Data("BOMStore".utf8), cached?.fingerprint == fingerprint(item), let cached {
                                // Reuse parsing only inside this reader, after reopening the same unchanged file.
                                // Revoked access must still fail, even when metadata remains visible.
                                paths = cached.paths
                            } else {
                                var data = header
                                data.append(try handle.readToEnd() ?? Data())
                                paths = try ReceiptBOMInventory(data: data).paths
                            }
                            guard fstat(handle.fileDescriptor, &opened) == 0, fingerprint(opened) == fingerprint(item) else { throw ReceiptReadError.changedDuringRead }
                            pathsByStem[(name as NSString).deletingPathExtension] = paths
                            validatedBOMs[child] = ValidatedBOM(fingerprint: fingerprint(item), paths: paths)
                        } catch {
                            diagnoseReadFailure(error, at: child,
                                                message: "The receipt file inventory could not be completely validated.",
                                                fallback: .invalidData)
                        }
                    default:
                        diagnose(.unsupportedLayout, child, "The receipt layout contains an unrecognized entry.")
                    }
                }
                for stem in bomStems.subtracting(plistStems) {
                    diagnose(.invalidData, path + "/" + stem + ".bom", "A file inventory has no corresponding receipt metadata.")
                }
                for stem in bomStems {
                    if let id = idsByStem[stem], let paths = pathsByStem[stem] {
                        if let previous = inventoryPaths[id], previous != paths {
                            diagnose(.inconsistentResults, path, "Multiple inventories disagree for the same receipt identifier.")
                        }
                        inventoryIDs.insert(id)
                        inventoryPaths[id] = paths
                    }
                }
            } catch {
                diagnoseReadFailure(error, at: path, message: "The receipt directory could not be enumerated.")
            }
        }
        var snapshot = Self(packageIDs: ids, fingerprints: fingerprints, diagnostics: diagnostics, fileInventoryPackageIDs: inventoryIDs, inventoryPaths: inventoryPaths)
        snapshot.validatedBOMs = validatedBOMs
        return snapshot
    }

    public func validateUnchanged() throws {
        for (path, expected) in fingerprints {
            var metadata = stat()
            let result = lstat(path, &metadata)
            if expected == "absent" {
                guard result != 0, errno == ENOENT else { throw ReceiptReadError.changedDuringRead }
            } else {
                guard result == 0, Self.fingerprint(metadata) == expected else { throw ReceiptReadError.changedDuringRead }
            }
        }
    }

    private static func fingerprint(_ metadata: stat) -> String {
        "\(metadata.st_dev):\(metadata.st_ino):\(metadata.st_mode):\(metadata.st_size):\(metadata.st_mtimespec.tv_sec):\(metadata.st_mtimespec.tv_nsec):\(metadata.st_ctimespec.tv_sec):\(metadata.st_ctimespec.tv_nsec)"
    }

    /// A reader owns its parse cache; observations still reopen every inventory and rescan all stores.
    private final class Reader: @unchecked Sendable {
        private let lock = NSLock()
        private let volume: String
        private var previous: ReceiptStoreSnapshot?
        init(volume: String) { self.volume = volume }
        func capture() -> ReceiptStoreSnapshot {
            lock.lock()
            defer { lock.unlock() }
            let current = ReceiptStoreSnapshot.capture(paths: ReceiptStoreSnapshot.paths(volume: volume), reusing: previous)
            previous = current
            return current
        }
    }
}
