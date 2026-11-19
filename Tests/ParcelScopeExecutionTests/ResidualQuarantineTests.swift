import Foundation
import Testing
import Darwin
import CryptoKit
@testable import ParcelScopeExecution

struct ResidualQuarantineTests {
    @Test func knownSyntheticIndexIsReviewedWithoutMutation() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(atPath: root) }
        let path = root + "/usr/share/man/whatis"
        let data = Data("synthetic public fixture\n".utf8)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let action = try ResidualQuarantinePlanner.review(path: path, version: ResidualQuarantinePlanner.version,
            digest: digest, size: Int64(data.count), catalogDigest: "catalog", ownerIDs: [], uid: getuid(), anchor: root)
        #expect(action?.path == path)
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root).sorted() == ["usr"])
    }
    @Test(arguments: ["digest", "version", "owner", "hardlink", "symlink", "ancestor", "ancestorSymlink", "mode"])
    func unexpectedItemsStopBeforeMutation(kind: String) throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(atPath: root) }
        let path = root + "/usr/share/man/whatis"
        let digest = SHA256.hash(data: Data("synthetic public fixture\n".utf8)).map { String(format: "%02x", $0) }.joined()
        if kind == "hardlink" { #expect(link(path, root + "/second") == 0) }
        if kind == "symlink" {
            try FileManager.default.moveItem(atPath: path, toPath: root + "/original")
            #expect(symlink(root + "/original", path) == 0)
        }
        if kind == "ancestorSymlink" {
            try FileManager.default.moveItem(atPath: root + "/usr/share/man", toPath: root + "/manuals")
            #expect(symlink(root + "/manuals", root + "/usr/share/man") == 0)
        }
        if kind == "ancestor" { chmod(root + "/usr/share", 0o777) }
        if kind == "mode" { chmod(path, 0o666) }
        #expect(throws: (any Error).self) {
            try ResidualQuarantinePlanner.review(path: path,
                version: kind == "version" ? "unknown" : ResidualQuarantinePlanner.version,
                digest: kind == "digest" ? "wrong" : digest, size: 25,
                catalogDigest: "catalog", ownerIDs: kind == "owner" ? ["unrelated.owner"] : [], uid: getuid(), anchor: root)
        }
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(try FileManager.default.contentsOfDirectory(atPath: root).allSatisfy { !$0.hasPrefix("parcelscope-residual.") })
    }

    @Test func quarantinePreservesBytesAndDurableRecovery() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(atPath: root) }
        let path = root + "/usr/share/man/whatis"
        let original = try Data(contentsOf: URL(fileURLWithPath: path))
        let digest = SHA256.hash(data: original).map { String(format: "%02x", $0) }.joined()
        let action = try #require(try ResidualQuarantinePlanner.review(path: path,
            version: ResidualQuarantinePlanner.version, digest: digest, size: Int64(original.count),
            catalogDigest: "catalog", ownerIDs: [], uid: getuid(), anchor: root))
        let record = try ResidualQuarantineExecutor.quarantine(action, fresh: action, base: root, uid: getuid(), anchor: root)
        #expect(record.state == .quarantined)
        let repeated = try ResidualQuarantineExecutor.recover(recordPath: record.recordPath, base: root, uid: getuid(), anchor: root)
        #expect(repeated == record)
        var interrupted = record
        interrupted.state = .prepared
        try JSONEncoder().encode(interrupted).write(to: URL(fileURLWithPath: record.recordPath))
        chmod(record.recordPath, 0o600)
        let recovered = try ResidualQuarantineExecutor.recover(recordPath: record.recordPath, base: root, uid: getuid(), anchor: root)
        #expect(recovered == record)
        #expect(!FileManager.default.fileExists(atPath: path))
        #expect(try Data(contentsOf: URL(fileURLWithPath: record.quarantinedPath)) == original)
        #expect(try JSONDecoder().decode(ResidualRecoveryRecord.self, from: Data(contentsOf: URL(fileURLWithPath: record.recordPath))) == record)
        try original.write(to: URL(fileURLWithPath: path))
        #expect(throws: (any Error).self) {
            try ResidualQuarantineExecutor.recover(recordPath: record.recordPath, base: root, uid: getuid(), anchor: root)
        }
        #expect(try Data(contentsOf: URL(fileURLWithPath: record.quarantinedPath)) == original)
    }

    @Test func changedLeafStopsBeforeQuarantineDirectoryCreation() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(atPath: root) }
        let path = root + "/usr/share/man/whatis"
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let action = try #require(try ResidualQuarantinePlanner.review(path: path, version: ResidualQuarantinePlanner.version,
            digest: digest, size: Int64(data.count), catalogDigest: "catalog", ownerIDs: [], uid: getuid(), anchor: root))
        try Data("replacement\n".utf8).write(to: URL(fileURLWithPath: path))
        #expect(throws: (any Error).self) {
            try ResidualQuarantineExecutor.quarantine(action, fresh: action, base: root, uid: getuid(), anchor: root)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: root) == ["usr"])
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == Data("replacement\n".utf8))
    }

    @Test func frozenAbsenceRejectsNewlyObservedResidualWithoutMutation() throws {
        let root = try fixture(); defer { try? FileManager.default.removeItem(atPath: root) }
        let path = root + "/usr/share/man/whatis"
        let bytes = try Data(contentsOf: URL(fileURLWithPath: path))
        let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
        let action = try #require(try ResidualQuarantinePlanner.review(path: path,
            version: ResidualQuarantinePlanner.version, digest: digest, size: Int64(bytes.count),
            catalogDigest: "catalog", ownerIDs: [], uid: getuid(), anchor: root))
        let absent = ResidualReviewSnapshot(action: nil)
        try absent.validate(current: nil)
        #expect(throws: (any Error).self) { try absent.validate(current: action) }
        let present = ResidualReviewSnapshot(action: action)
        try present.validate(current: action)
        #expect(throws: (any Error).self) { try present.validate(current: nil) }
        #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == bytes)
        #expect(try JSONDecoder().decode(ResidualReviewSnapshot.self, from: JSONEncoder().encode(absent)) == absent)
    }

    private func fixture() throws -> String {
        let root = "/private/tmp/parcelscope-residual-test-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: root + "/usr/share/man", withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try Data("synthetic public fixture\n".utf8).write(to: URL(fileURLWithPath: root + "/usr/share/man/whatis"))
        for suffix in ["", "/usr", "/usr/share", "/usr/share/man"] { chmod(root + suffix, 0o755) }
        chown(root + "/usr/share/man/whatis", getuid(), getgid())
        chmod(root + "/usr/share/man/whatis", 0o644)
        return root
    }
}
