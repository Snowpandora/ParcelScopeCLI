import Foundation
import CryptoKit
import Darwin

public struct ResidualQuarantineAction: Codable, Sendable, Equatable {
    public let path: String
    public let executablesVersion: String
    public let sha256: String
    public let catalogDigest: String
    let anchor: String
    let identity: ResidualIdentity
    let ancestors: [ResidualIdentity]
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.path == rhs.path && lhs.executablesVersion == rhs.executablesVersion && lhs.sha256 == rhs.sha256
            && lhs.catalogDigest == rhs.catalogDigest && lhs.anchor == rhs.anchor && lhs.identity == rhs.identity
            && lhs.ancestors.count == rhs.ancestors.count && zip(lhs.ancestors, rhs.ancestors).allSatisfy { $0.sameDirectory($1) }
    }
    public var reviewSummary: String { "Quarantine preserved installer-generated index: \(path) (SHA-256 \(sha256)); retain recovery record and bytes in /private/var/db/parcelscope-residual.<session>/; never delete this unreceipted file." }
}

public struct ResidualRecoveryRecord: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case prepared, quarantined }
    public let action: ResidualQuarantineAction
    public let directory: String
    public var state: State
    public var recordPath: String { directory + "/recovery.json" }
    public var quarantinedPath: String { directory + "/whatis" }
}

struct ResidualIdentity: Codable, Sendable, Equatable {
    let device: UInt64
    let inode: UInt64
    let mode: UInt16
    let uid: UInt32
    let gid: UInt32
    let links: UInt64
    let size: Int64
    let modifiedSeconds: Int64
    let modifiedNanoseconds: Int64
    let changedSeconds: Int64
    let changedNanoseconds: Int64
    init(_ s: stat) {
        device = UInt64(s.st_dev); inode = UInt64(s.st_ino); mode = s.st_mode
        uid = s.st_uid; gid = s.st_gid; links = UInt64(s.st_nlink); size = s.st_size
        modifiedSeconds = Int64(s.st_mtimespec.tv_sec); modifiedNanoseconds = Int64(s.st_mtimespec.tv_nsec)
        changedSeconds = Int64(s.st_ctimespec.tv_sec); changedNanoseconds = Int64(s.st_ctimespec.tv_nsec)
    }
    func sameDirectory(_ other: Self) -> Bool { device == other.device && inode == other.inode && mode == other.mode && uid == other.uid && gid == other.gid }
}

public enum ResidualQuarantineError: Error { case unsafeOrChanged, unsupportedVersion, ownershipUnavailable, receiptOwner, ioFailure }

/// The allowlist is deliberately limited to the installer/version and bytes observed on the stock clone.
public struct ResidualQuarantinePlanner: Sendable {
    public static let path = "/Library/Developer/CommandLineTools/usr/share/man/whatis"
    public static let version = "26.5.0.0.1777544298"
    public static let sha256 = "55951d565ada97d622c9771c7fe5f6691c76fae61fd844970c0eead022ebf766"

    public init() {}
    static func review(path: String, version: String, digest: String, size: Int64,
                       catalogDigest: String, ownerIDs: [String], uid: uid_t, anchor: String = "/") throws -> ResidualQuarantineAction? {
        guard version == Self.version else { throw ResidualQuarantineError.unsupportedVersion }
        guard !catalogDigest.isEmpty else { throw ResidualQuarantineError.ownershipUnavailable }
        guard ownerIDs.isEmpty else { throw ResidualQuarantineError.receiptOwner }
        let directory = try ResidualDirectory.openParent(path: path, anchor: anchor, uid: uid)
        defer { close(directory.fd) }
        let leaf = openat(directory.fd, "whatis", O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        if leaf < 0, errno == ENOENT { return nil }
        guard leaf >= 0 else { throw ResidualQuarantineError.unsafeOrChanged }
        defer { close(leaf) }
        let identity = try ResidualDirectory.identity(leaf)
        guard identity.mode & S_IFMT == S_IFREG, identity.uid == uid,
              identity.gid == (uid == 0 ? 0 : getgid()), identity.links == 1,
              identity.mode & 0o7777 == 0o644, identity.size == size,
              identity.device == directory.ancestors.last?.device,
              try ResidualDirectory.hash(leaf) == digest,
              try ResidualDirectory.identity(leaf) == identity else { throw ResidualQuarantineError.unsafeOrChanged }
        return ResidualQuarantineAction(path: path, executablesVersion: version, sha256: digest,
            catalogDigest: catalogDigest, anchor: anchor, identity: identity, ancestors: directory.ancestors)
    }
}


/// All traversals remain relative to held directory descriptors; no Foundation canonicalization is authority.
private struct ResidualDirectory {
    let fd: Int32
    let ancestors: [ResidualIdentity]
    static func identity(_ fd: Int32) throws -> ResidualIdentity {
        var s = stat()
        guard fstat(fd, &s) == 0 else { throw ResidualQuarantineError.ioFailure }
        return ResidualIdentity(s)
    }
    static func openParent(path: String, anchor: String, uid: uid_t) throws -> Self {
        guard path.hasPrefix(anchor == "/" ? "/" : anchor + "/"), path.hasSuffix("/whatis"),
              !path.utf8.contains(0), !anchor.utf8.contains(0) else { throw ResidualQuarantineError.unsafeOrChanged }
        let suffix = anchor == "/" ? String(path.dropFirst()) : String(path.dropFirst(anchor.count + 1))
        let parts = suffix.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw ResidualQuarantineError.unsafeOrChanged }
        var fd = open(anchor, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw ResidualQuarantineError.unsafeOrChanged }
        do {
            var ids: [ResidualIdentity] = []
            for part in [String? (nil)] + parts.dropLast().map(Optional.some) {
                if let part {
                    let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
                    guard next >= 0 else { throw ResidualQuarantineError.unsafeOrChanged }
                    close(fd); fd = next
                }
                let id = try identity(fd)
                guard id.mode & S_IFMT == S_IFDIR, id.uid == uid,
                      id.mode & 0o022 == 0 else { throw ResidualQuarantineError.unsafeOrChanged }
                ids.append(id)
            }
            return Self(fd: fd, ancestors: ids)
        } catch { close(fd); throw error }
    }
    static func requireMissing(path: String, anchor: String, uid: uid_t) throws {
        guard path.hasPrefix(anchor == "/" ? "/" : anchor + "/"), !path.utf8.contains(0) else { throw ResidualQuarantineError.unsafeOrChanged }
        let suffix = anchor == "/" ? String(path.dropFirst()) : String(path.dropFirst(anchor.count + 1))
        let parts = suffix.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw ResidualQuarantineError.unsafeOrChanged }
        var fd = open(anchor, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard fd >= 0 else { throw ResidualQuarantineError.unsafeOrChanged }
        defer { close(fd) }
        for part in parts.dropLast() {
            let id = try identity(fd)
            guard id.uid == uid, id.mode & 0o022 == 0 else { throw ResidualQuarantineError.unsafeOrChanged }
            let next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            if next < 0, errno == ENOENT { return }
            guard next >= 0 else { throw ResidualQuarantineError.unsafeOrChanged }
            close(fd); fd = next
        }
        let id = try identity(fd)
        guard id.uid == uid, id.mode & 0o022 == 0 else { throw ResidualQuarantineError.unsafeOrChanged }
        var value = stat()
        guard fstatat(fd, parts.last!, &value, AT_SYMLINK_NOFOLLOW) == -1, errno == ENOENT else {
            throw ResidualQuarantineError.unsafeOrChanged
        }
    }
    static func hash(_ fd: Int32) throws -> String {
        guard lseek(fd, 0, SEEK_SET) == 0 else { throw ResidualQuarantineError.ioFailure }
        var hash = SHA256()
        var bytes = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = read(fd, &bytes, bytes.count)
            guard count >= 0 else { throw ResidualQuarantineError.ioFailure }
            if count == 0 { break }
            hash.update(data: Data(bytes.prefix(count)))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public struct ResidualQuarantineExecutor: Sendable {
    public init() {}

    static func quarantine(_ action: ResidualQuarantineAction, fresh: ResidualQuarantineAction,
                           base: String, uid: uid_t, anchor: String = "/") throws -> ResidualRecoveryRecord {
        guard action == fresh else { throw ResidualQuarantineError.unsafeOrChanged }
        let source = try ResidualDirectory.openParent(path: action.path, anchor: action.anchor, uid: uid)
        defer { close(source.fd) }
        guard zip(source.ancestors, action.ancestors).allSatisfy({ $0.sameDirectory($1) }),
              source.ancestors.count == action.ancestors.count else { throw ResidualQuarantineError.unsafeOrChanged }
        let leaf = openat(source.fd, "whatis", O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard leaf >= 0 else { throw ResidualQuarantineError.unsafeOrChanged }
        defer { close(leaf) }
        guard try ResidualDirectory.identity(leaf) == action.identity,
              try ResidualDirectory.hash(leaf) == action.sha256 else { throw ResidualQuarantineError.unsafeOrChanged }
        let destination = try ResidualDirectory.openParent(path: base + "/whatis", anchor: anchor, uid: uid)
        defer { close(destination.fd) }
        guard try ResidualDirectory.identity(destination.fd).device == action.identity.device else {
            throw ResidualQuarantineError.unsafeOrChanged
        }
        // No mutation has occurred before every source, ownership, and same-volume check above.
        let name = "parcelscope-residual." + UUID().uuidString
        guard mkdirat(destination.fd, name, 0o700) == 0 else { throw ResidualQuarantineError.ioFailure }
        let quarantine = openat(destination.fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard quarantine >= 0 else { throw ResidualQuarantineError.ioFailure }
        defer { close(quarantine) }
        guard fsync(destination.fd) == 0 else { throw ResidualQuarantineError.ioFailure }
        let id = try ResidualDirectory.identity(quarantine)
        guard id.uid == uid, id.mode & 0o7777 == 0o700, id.device == action.identity.device else {
            throw ResidualQuarantineError.unsafeOrChanged
        }
        var record = ResidualRecoveryRecord(action: action, directory: base + "/" + name, state: .prepared)
        try writeRecord(record, directoryFD: quarantine)
        var current = stat()
        guard fstatat(source.fd, "whatis", &current, AT_SYMLINK_NOFOLLOW) == 0,
              ResidualIdentity(current) == action.identity else { throw ResidualQuarantineError.unsafeOrChanged }
        guard renameat(source.fd, "whatis", quarantine, "whatis") == 0 else { throw ResidualQuarantineError.ioFailure }
        guard fsync(source.fd) == 0, fsync(quarantine) == 0 else { throw ResidualQuarantineError.ioFailure }
        let preserved = openat(quarantine, "whatis", O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard preserved >= 0 else { throw ResidualQuarantineError.ioFailure }
        defer { close(preserved) }
        let preservedIdentity = try ResidualDirectory.identity(preserved)
        guard preservedIdentity.inode == action.identity.inode, preservedIdentity.device == action.identity.device,
              preservedIdentity.mode == action.identity.mode, preservedIdentity.links == 1,
              preservedIdentity.uid == uid, try ResidualDirectory.hash(preserved) == action.sha256 else {
            throw ResidualQuarantineError.unsafeOrChanged
        }
        record.state = .quarantined
        try writeRecord(record, directoryFD: quarantine)
        return record
    }

    /// Resolve a prepared record after interruption, or verify an already completed quarantine.
    /// This never restores or deletes bytes and does not authorize receipt retirement.
    public func recover(recordPath: String) throws -> ResidualRecoveryRecord {
        guard geteuid() == 0 else { throw ResidualQuarantineError.unsafeOrChanged }
        return try Self.recover(recordPath: recordPath, base: "/private/var/db", uid: 0)
    }

    static func recover(recordPath: String, base: String, uid: uid_t, anchor: String = "/") throws -> ResidualRecoveryRecord {
        let directory = String(recordPath.dropLast("/recovery.json".count))
        let prefix = base + "/parcelscope-residual."
        guard recordPath.hasSuffix("/recovery.json"), directory.hasPrefix(prefix),
              UUID(uuidString: String(directory.dropFirst(prefix.count))) != nil else { throw ResidualQuarantineError.unsafeOrChanged }
        let folder = try ResidualDirectory.openParent(path: directory + "/whatis", anchor: anchor, uid: uid)
        defer { close(folder.fd) }
        guard let last = folder.ancestors.last, last.mode & 0o7777 == 0o700 else { throw ResidualQuarantineError.unsafeOrChanged }
        let fd = openat(folder.fd, "recovery.json", O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw ResidualQuarantineError.unsafeOrChanged }
        defer { close(fd) }
        let id = try ResidualDirectory.identity(fd)
        guard id.uid == uid, id.mode & S_IFMT == S_IFREG, id.mode & 0o7777 == 0o600,
              id.links == 1, id.size > 0, id.size <= 64 * 1024 else { throw ResidualQuarantineError.unsafeOrChanged }
        var bytes = [UInt8](repeating: 0, count: Int(id.size))
        var offset = 0
        while offset < bytes.count {
            let n = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            guard n > 0 else { throw ResidualQuarantineError.ioFailure }
            offset += n
        }
        var record = try JSONDecoder().decode(ResidualRecoveryRecord.self, from: Data(bytes))
        if uid == 0 {
            guard record.action.path == ResidualQuarantinePlanner.path, record.action.anchor == "/",
                  record.action.executablesVersion == ResidualQuarantinePlanner.version,
                  record.action.sha256 == ResidualQuarantinePlanner.sha256,
                  record.action.identity.size == 18_034 else { throw ResidualQuarantineError.unsafeOrChanged }
        }
        guard record.directory == directory else { throw ResidualQuarantineError.unsafeOrChanged }
        let leaf = openat(folder.fd, "whatis", O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard leaf >= 0 else { throw ResidualQuarantineError.unsafeOrChanged }
        defer { close(leaf) }
        let item = try ResidualDirectory.identity(leaf)
        guard item.uid == uid, item.links == 1, item.mode & S_IFMT == S_IFREG,
              item.mode == record.action.identity.mode, item.size == record.action.identity.size,
              item.inode == record.action.identity.inode, item.device == record.action.identity.device,
              try ResidualDirectory.hash(leaf) == record.action.sha256 else { throw ResidualQuarantineError.unsafeOrChanged }
        try ResidualDirectory.requireMissing(path: record.action.path, anchor: record.action.anchor, uid: uid)
        if record.state == .prepared {
            record.state = .quarantined
            try Self.writeRecord(record, directoryFD: folder.fd)
        }
        return record
    }

    private static func writeRecord(_ record: ResidualRecoveryRecord, directoryFD: Int32) throws {
        let temporary = "recovery." + UUID().uuidString + ".new"
        let fd = openat(directoryFD, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ResidualQuarantineError.ioFailure }
        defer { close(fd) }
        let data = try JSONEncoder().encode(record)
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let n = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                guard n > 0 else { throw ResidualQuarantineError.ioFailure }
                offset += n
            }
        }
        guard fsync(fd) == 0, renameat(directoryFD, temporary, directoryFD, "recovery.json") == 0,
              fsync(directoryFD) == 0 else { throw ResidualQuarantineError.ioFailure }
    }
}
