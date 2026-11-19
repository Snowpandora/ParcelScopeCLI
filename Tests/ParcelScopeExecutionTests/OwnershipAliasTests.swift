import Foundation
import Testing
@testable import ParcelScopeInspection
@testable import ParcelScopeExecution

struct AliasReceiptClient: PkgutilClient {
    let selected: PackageID
    let retained: PackageID
    let selectedPath: String
    let retainedPath: String
    var selectedUnclassified = false
    func listPackages() async throws -> [PackageID] { [selected, retained] }
    func listGroups() async throws -> [String] { [] }
    func listPackages(inGroup: String) async throws -> [PackageID] { [] }
    func getPackageInfo(for id: PackageID) async throws -> PackageReceipt {
        PackageReceipt(id: id, version: "1", volume: "/", installLocation: "/", installTime: Date(timeIntervalSince1970: 1))
    }
    func getFiles(for id: PackageID) async throws -> [ReceiptFile] {
        [ReceiptFile(relativePath: String((id == selected ? selectedPath : retainedPath).dropFirst()))]
    }
    func getFiles(for id: PackageID, filter: ReceiptFileFilter) async throws -> [ReceiptFile] {
        if selectedUnclassified && id == selected && filter != .all { return [] }
        return filter == .onlyDirectories ? [] : try await getFiles(for: id)
    }
    func reverseLookup(path: String) async throws -> FileLookupResult {
        throw ReceiptReadError.invalidOutput("The bulk index must establish ownership independently.")
    }

}

struct OwnershipAliasTests {
    @Test(arguments: [true, false])
    func unknownTypeOrCrossDeviceTargetKeepsFullParentProof(_ unknownType: Bool) async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = root.appendingPathComponent("payload")
        try Data().write(to: payload)
        let unresolved = root.appendingPathComponent("unresolved-parent")
        try FileManager.default.createSymbolicLink(at: unresolved, withDestinationURL: root.appendingPathComponent("missing"))
        let selected = try PackageID("com.example.selected"), retained = try PackageID("com.example.retained")
        let payloadPath = payload.path
        let repository = PackageRepositoryImpl(client: AliasReceiptClient(selected: selected, retained: retained,
            selectedPath: payloadPath, retainedPath: unresolved.appendingPathComponent("record.plist").path),
            observeObject: { path in
                guard let object = try OwnershipObject.inspect(path) else { return nil }
                guard path == payloadPath else { return object }
                return OwnershipObject(identity: object.identity, type: unknownType ? .unknown : object.type,
                    linkCount: object.linkCount, device: unknownType ? object.device : object.device &+ 1)
            })
        await #expect(throws: ReceiptReadError.self) {
            try await repository.fetchOwnershipEvidence(paths: [payloadPath])
        }
    }

    @Test(arguments: [".", "child/.."])
    func directoryDotAliasesRetainSharedOwnership(_ suffix: String) async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        let directory = root.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: directory.appendingPathComponent("child"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = try PackageID("com.example.selected"), retained = try PackageID("com.example.retained")
        let repository = PackageRepositoryImpl(client: AliasReceiptClient(selected: selected, retained: retained,
            selectedPath: directory.path, retainedPath: directory.path + "/" + suffix))
        let result = try await repository.fetchOwnershipEvidence(paths: [directory.path])
        #expect(Set(result.owners[directory.path]?.owners.map(\.packageID) ?? []) == [selected, retained])
    }

    @Test func unrelatedDanglingParentDoesNotBlockSingleLinkPayloadPlanning() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        let selectedFolder = root.appendingPathComponent("selected")
        try FileManager.default.createDirectory(at: selectedFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = selectedFolder.appendingPathComponent("payload")
        try Data("keep ownership evidence complete".utf8).write(to: payload)
        let unresolved = root.appendingPathComponent("unresolved-parent")
        try FileManager.default.createSymbolicLink(at: unresolved, withDestinationURL: root.appendingPathComponent("missing"))
        let selected = try PackageID("com.example.selected"), retained = try PackageID("com.example.retained")
        let client = AliasReceiptClient(selected: selected, retained: retained,
            selectedPath: payload.path, retainedPath: unresolved.appendingPathComponent("record.plist").path)
        let repository = PackageRepositoryImpl(client: client)
        let plan = try await CleanupPlanBuilder().build(targets: [selected], repository: repository, volume: .capture("/"))
        #expect(plan.isComplete)
        #expect(plan.entries.first?.reason == .selectedReceiptOnly)
        #expect(plan.entries.first?.owners == [selected.rawValue])
        let records = try #require(plan.ownershipEvidence?.records)
        #expect(Set(records.map(\.receipt.packageID)) == [selected.rawValue, retained.rawValue])
        let inventory = try await client.getFileInventory(for: retained)
        #expect(records.first { $0.receipt.packageID == retained.rawValue }?.filesSHA256 == inventory.sha256)
    }

    @Test(arguments: ["PAYLOAD", "caf\u{00E9}"])
    func potentiallyEquivalentOrUnicodeLeafStillRequiresParentProof(_ leaf: String) async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = root.appendingPathComponent("payload")
        try Data().write(to: payload)
        let unresolved = root.appendingPathComponent("unresolved-parent")
        try FileManager.default.createSymbolicLink(at: unresolved, withDestinationURL: root.appendingPathComponent("missing"))
        let selected = try PackageID("com.example.selected"), retained = try PackageID("com.example.retained")
        let repository = PackageRepositoryImpl(client: AliasReceiptClient(selected: selected, retained: retained,
            selectedPath: payload.path, retainedPath: unresolved.appendingPathComponent(leaf).path))
        await #expect(throws: ReceiptReadError.self) {
            try await CleanupPlanBuilder().build(targets: [selected], repository: repository, volume: .capture("/"))
        }
    }

    @Test func absentUnclassifiedReceiptEntryNeedsNoDeletionTypeButLiveEntryDoes() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let path = root.appendingPathComponent("removed-framework-link")
        let selected = try PackageID("com.example.selected"), retained = try PackageID("com.example.retained")
        let repo = PackageRepositoryImpl(client: AliasReceiptClient(selected: selected, retained: retained,
            selectedPath: path.path, retainedPath: root.appendingPathComponent("unrelated").path, selectedUnclassified: true))
        let missing = try await CleanupPlanBuilder().build(targets: [selected], repository: repo, volume: .capture("/"))
        #expect(missing.isComplete)
        #expect(missing.entries.first?.itemType == .unknown)
        #expect(missing.entries.first?.reason == .alreadyMissing)
        #expect(missing.entries.first?.proposesRemoval == false)
        try Data().write(to: path)
        let present = try await CleanupPlanBuilder().build(targets: [selected], repository: repo, volume: .capture("/"))
        #expect(!present.isComplete)
        #expect(present.entries.first?.reason == .unknownType)
        #expect(present.entries.first?.proposesRemoval == false)
    }

    @Test func absentPayloadDoesNotInspectUnrelatedReceiptParents() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = try PackageID("com.example.selected"), retained = try PackageID("com.example.retained")
        let missing = root.appendingPathComponent("removed/payload").path
        let unrelated = root.appendingPathComponent("protected").path
        try FileManager.default.createDirectory(atPath: unrelated, withIntermediateDirectories: true)
        let repo = PackageRepositoryImpl(client: AliasReceiptClient(selected: selected, retained: retained,
            selectedPath: missing, retainedPath: unrelated + "/payload"), observeObject: { path in
                if path == unrelated { throw ReceiptReadError.invalidOutput("Protected parent must not be inspected for missing payload.") }
                return try OwnershipObject.inspect(path)
            })
        let plan = try await CleanupPlanBuilder().build(targets: [selected], repository: repo, volume: .capture("/"))
        #expect(plan.isComplete)
        #expect(plan.entries.allSatisfy { $0.reason == .alreadyMissing && !$0.proposesRemoval })
        #expect(plan.ownershipEvidence?.records.count == 2)
        // A later scan with a live target must regain the full alias proof requirement.
        try FileManager.default.createDirectory(atPath: (missing as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try Data().write(to: URL(fileURLWithPath: missing))
        await #expect(throws: ReceiptReadError.self) {
            try await CleanupPlanBuilder().build(targets: [selected], repository: repo, volume: .capture("/"))
        }
    }

    @Test func unrelatedUnreadableLeafDoesNotPreventSingleLinkTargetPlanning() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        let targetFolder = root.appendingPathComponent("selected")
        let unrelatedFolder = root.appendingPathComponent("unrelated")
        try FileManager.default.createDirectory(at: targetFolder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: unrelatedFolder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = targetFolder.appendingPathComponent("payload"), denied = unrelatedFolder.appendingPathComponent("Store")
        try Data().write(to: file)
        let selected = try PackageID("com.example.selected"), retained = try PackageID("com.example.retained")
        let deniedPath = denied.path
        let repository = PackageRepositoryImpl(client: AliasReceiptClient(selected: selected, retained: retained,
            selectedPath: file.path, retainedPath: deniedPath), observeObject: { path in
                guard path != deniedPath else { throw ReceiptReadError.invalidOutput("Unrelated protected metadata must not be queried.") }
                return try OwnershipObject.inspect(path)
            })
        let plan = try await CleanupPlanBuilder().build(targets: [selected], repository: repository, volume: .capture("/"))
        let entry = try #require(plan.entries.first)
        #expect(plan.isComplete)
        #expect(entry.reason == .selectedReceiptOnly)
        #expect(entry.owners == [selected.rawValue])
        #expect(plan.ownershipEvidence?.records.count == 2)
    }

    @Test func inaccessiblePotentialHardLinkBlocksPlanning() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = a.appendingPathComponent("file"), alias = b.appendingPathComponent("other-name")
        try Data().write(to: file)
        try FileManager.default.linkItem(at: file, to: alias)
        let selected = try PackageID("com.example.selected"), retained = try PackageID("com.example.retained")
        let denied = alias.path
        let repo = PackageRepositoryImpl(client: AliasReceiptClient(selected: selected, retained: retained,
            selectedPath: file.path, retainedPath: denied), observeObject: { path in
                if path == denied { throw ReceiptReadError.invalidOutput("Metadata denied") }
                return try OwnershipObject.inspect(path)
            })
        await #expect(throws: ReceiptReadError.self) {
            try await CleanupPlanBuilder().build(targets: [selected], repository: repo, volume: .capture("/"))
        }
    }

    @Test func unavailableSameParentOrParentIdentityCannotAuthorizeCleanup() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        let a = root.appendingPathComponent("a"), b = root.appendingPathComponent("b")
        try FileManager.default.createDirectory(at: a, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: b, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = a.appendingPathComponent("payload")
        try Data().write(to: file)
        let selected = try PackageID("com.example.selected"), retained = try PackageID("com.example.retained")
        for candidate in [a.appendingPathComponent("PAYLOAD"), b.appendingPathComponent("payload")] {
            let deniedPath = candidate.deletingLastPathComponent().path == a.path ? candidate.path : b.path
            let repo = PackageRepositoryImpl(client: AliasReceiptClient(selected: selected, retained: retained,
                selectedPath: file.path, retainedPath: candidate.path), observeObject: { path in
                    if path == deniedPath { throw ReceiptReadError.invalidOutput("Metadata denied") }
                    return try OwnershipObject.inspect(path)
                })
            await #expect(throws: ReceiptReadError.self) {
                try await CleanupPlanBuilder().build(targets: [selected], repository: repo, volume: .capture("/"))
            }
        }
    }

    @Test func absentPayloadCanBePlannedWithoutUnrelatedProtectedLeafMetadata() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        let unrelated = root.appendingPathComponent("unrelated")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let selected = try PackageID("com.example.selected"), retained = try PackageID("com.example.retained")
        let deniedPath = unrelated.appendingPathComponent("Store").path
        let repo = PackageRepositoryImpl(client: AliasReceiptClient(selected: selected, retained: retained,
            selectedPath: root.appendingPathComponent("removed-root/payload").path, retainedPath: deniedPath), observeObject: { path in
                guard path != deniedPath else { throw ReceiptReadError.invalidOutput("Unrelated protected leaf queried") }
                return try OwnershipObject.inspect(path)
            })
        let plan = try await CleanupPlanBuilder().build(targets: [selected], repository: repo, volume: .capture("/"))
        #expect(plan.isComplete)
        #expect(plan.entries.allSatisfy { $0.reason == .alreadyMissing && !$0.proposesRemoval })
    }

    @Test func sharedOwnershipIncludesSystemAndCustomParentAliases() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent("payload")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("shared")
        try Data("preserve shared payload".utf8).write(to: file)
        let link = root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: directory)
        #expect(try OwnershipObject.inspect(file.path)?.linkCount == 1)
        var aliases = [file.path.replacingOccurrences(of: "/private/tmp/", with: "/tmp/"), link.appendingPathComponent("shared").path]
        let caseAlias = directory.appendingPathComponent("SHARED").path
        if FileManager.default.fileExists(atPath: caseAlias) { aliases.append(caseAlias) }
        func check(_ alias: String) async throws {
            let selected = try PackageID("com.example.selected"), retained = try PackageID("com.example.retained")
            let repository = PackageRepositoryImpl(client: AliasReceiptClient(selected: selected, retained: retained,
                selectedPath: file.path, retainedPath: alias))
            let plan = try await CleanupPlanBuilder().build(targets: [selected], repository: repository, volume: .capture("/"))
            let entry = try #require(plan.entries.first)
            #expect(entry.path == file.path)
            #expect(Set(entry.owners) == [selected.rawValue, retained.rawValue])
            #expect(entry.reason == .sharedOwnership)
            #expect(!entry.proposesRemoval)
        }
        for alias in aliases { try await check(alias) }
        let hardLink = root.appendingPathComponent("same-object")
        try FileManager.default.linkItem(at: file, to: hardLink)
        #expect(try OwnershipObject.inspect(file.path)?.linkCount == 2)
        try await check(hardLink.path)
    }

    @Test func singleLinkUnicodeNameAliasesRemainShared() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("caf\u{00E9}")
        let alias = root.appendingPathComponent("cafe\u{0301}")
        try Data().write(to: file)
        #expect(FileManager.default.fileExists(atPath: alias.path))
        #expect(try OwnershipObject.inspect(file.path)?.linkCount == 1)
        let selected = try PackageID("com.example.selected"), retained = try PackageID("com.example.retained")
        let repo = PackageRepositoryImpl(client: AliasReceiptClient(selected: selected, retained: retained,
            selectedPath: file.path, retainedPath: alias.path))
        let plan = try await CleanupPlanBuilder().build(targets: [selected], repository: repo, volume: .capture("/"))
        #expect(plan.entries.first?.reason == .sharedOwnership)
        #expect(plan.entries.first?.proposesRemoval == false)
    }

    @Test func leafSymlinksDoNotTransferOwnershipToTheirTargets() async throws {
        let root = URL(fileURLWithPath: "/private/tmp").appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("file"), link = root.appendingPathComponent("link")
        try Data().write(to: file)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        let selected = try PackageID("com.example.selected"), retained = try PackageID("com.example.retained")
        let repository = PackageRepositoryImpl(client: AliasReceiptClient(selected: selected, retained: retained,
            selectedPath: link.path, retainedPath: file.path))
        let read = try await repository.fetchOwnershipEvidence(paths: [link.path])
        #expect(read.owners[link.path]?.owners.map(\.packageID) == [selected])
    }
}
