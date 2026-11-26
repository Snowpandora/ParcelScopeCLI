import Foundation
import Testing
@testable import ParcelScopeInspection

@Suite struct InspectionSafetyTests {
    @Test func receiptAllowlistExcludesFullXcode() {
        #expect(CLTInspector.isCLTReceipt("com.apple.pkg.CLTools_Executables"))
        #expect(CLTInspector.isCLTReceipt("com.apple.dt.commandlinetools"))
        #expect(CLTInspector.isCLTReceipt("com.apple.pkg.CLTools_SDK_macOS27"))
        #expect(!CLTInspector.isCLTReceipt("com.apple.pkg.XcodeSystemResources"))
        #expect(!CLTInspector.isCLTReceipt("com.apple.pkg.CLTools_Executables.extra"))
        #expect(!CLTInspector.isCLTReceipt("com.example.synthetic"))
    }
    @Test func catalogCoverageCannotProveAbsence() throws {
        let catalog = ReceiptCatalog(packages: [], coverage: .partial, volume: .init(mountPoint: "/", uuid: "synthetic", device: "1"))
        #expect(throws: (any Error).self) { try catalog.requireComplete() }
    }
    @Test func malformedStorePathDoesNotIndicateAccessDenial() throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: parent)
        defer { try? FileManager.default.removeItem(at: parent) }
        let store = parent.appendingPathComponent("receipts")

        let observation = ReceiptStoreSnapshot.capture(paths: [store.path])

        #expect(!observation.isComplete)
        #expect(observation.diagnostics.map(\.kind) == [.unreadableStore])
        #expect(observation.diagnostics.map(\.resource) == [store.path])
    }
    @Test func deniedReceiptFilesIdentifyTheirReadFailure() throws {
        let store = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: store, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: store) }
        let receipts = ["com.example.synthetic.bom", "com.example.synthetic.plist"].map {
            store.appendingPathComponent($0)
        }
        for url in receipts {
            try Data("fixture".utf8).write(to: url)
            try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
        }

        let observation = ReceiptStoreSnapshot.capture(paths: [store.path])

        #expect(!observation.isComplete)
        #expect(observation.diagnostics.map(\.kind) == [.accessDenied, .accessDenied])
        #expect(observation.diagnostics.map(\.resource) == receipts.map(\.path))
    }
    @Test func incompleteReceiptErrorExplainsTheFailureAndPrioritizesDuplicateIDs() {
        let unreadable = ReceiptDiagnostic(kind: .unreadableStore, resource: "fixture", message: "Receipt data could not be read.")
        let duplicate = ReceiptDiagnostic(kind: .duplicateIdentifier, resource: "com.example.synthetic",
                                          message: "More than one registration matches this identifier.")

        #expect(ReceiptReadError.incomplete([unreadable]).localizedDescription == unreadable.message)
        #expect(ReceiptReadError.incomplete([unreadable, duplicate]).localizedDescription == duplicate.message)
    }
    @Test func strictIdentifierParserRejectsOptionsAndControlCharacters() {
        #expect(throws: (any Error).self) { try PkgutilParser.parsePackageIDsStrict(Data("--forget\n".utf8)) }
        #expect(throws: (any Error).self) { try PkgutilParser.parsePackageIDsStrict(Data("com.example.synthetic\tname\n".utf8)) }
    }
    @Test func legacyPlaceholderRequiresExactShape() {
        #expect(CLTInspector.isLegacyPlaceholderPath("/private/tmp/." + String(repeating: "A", count: 64)))
        #expect(!CLTInspector.isLegacyPlaceholderPath("/private/tmp/." + String(repeating: "a", count: 64)))
        #expect(!CLTInspector.isLegacyPlaceholderPath("/private/tmp/." + String(repeating: "A", count: 63)))
    }
    @Test func shellLiteralPreservesApostropheAsData() {
        #expect(ShellLiteral.quote("a'b") == "'a'\\''b'")
    }
}
