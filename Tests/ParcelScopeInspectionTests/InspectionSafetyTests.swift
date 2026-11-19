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
