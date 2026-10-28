import Foundation
import Testing
import UniformTypeIdentifiers
@testable import BoopstashCore

@Suite struct TextFileImportTests {
    @Test func acceptsTextLikeAndUnknownTypes() {
        let unknown = UTType(filenameExtension: "conf")! // dynamic: no registered type
        for type in [UTType.plainText, .json, .yaml, .xml, .swiftSource, .pythonScript, .shellScript, UTType(filenameExtension: "md")!, unknown, .data] {
            #expect(TextFileImport.accepts(type), "\(type)")
        }
        for type in [UTType.png, .pdf, .zip, .mpeg4Movie] {
            #expect(!TextFileImport.accepts(type), "\(type)")
        }
    }

    @Test func decodesCommonEncodings() {
        #expect(TextFileImport.text(from: Data("café".utf8), type: .plainText) == .success("café"))
        #expect(TextFileImport.text(from: Data([0xEF, 0xBB, 0xBF]) + Data("bom".utf8), type: .plainText) == .success("bom"))
        let utf16 = "héllo".data(using: .utf16)! // carries a BOM
        #expect(TextFileImport.text(from: utf16, type: .plainText) == .success("héllo"))
        let utf32le = Data([0xFF, 0xFE, 0x00, 0x00, 0x41, 0x00, 0x00, 0x00])
        #expect(TextFileImport.text(from: utf32le, type: .plainText) == .success("A"))
        let utf32be = Data([0x00, 0x00, 0xFE, 0xFF, 0x00, 0x00, 0x00, 0x42])
        #expect(TextFileImport.text(from: utf32be, type: .plainText) == .success("B"))
        let latin1 = "naïve".data(using: .isoLatin1)!
        #expect(TextFileImport.text(from: latin1, type: .plainText) == .success("naïve"))
    }

    @Test func unknownTypesAreJudgedByContent() {
        let unknown = UTType(filenameExtension: "conf")!
        #expect(TextFileImport.text(from: Data("listen 80;".utf8), type: unknown) == .success("listen 80;"))
        #expect(TextFileImport.text(from: Data([0x7F, 0x45, 0x4C, 0x46, 0x00]), type: .data) == .failure(.notText))
    }

    @Test func refusesBinaryLargeAndNonText() {
        #expect(TextFileImport.text(from: Data([0x41, 0x00, 0x42]), type: .plainText) == .failure(.notText))
        #expect(TextFileImport.text(from: Data("x".utf8), type: .png) == .failure(.notText))
        let big = Data(repeating: 0x61, count: TextFileImport.sizeLimit + 1)
        #expect(TextFileImport.text(from: big, type: .plainText) == .failure(.tooLarge(bytes: big.count)))
    }

    @Test func titlesComeFromTheFileName() {
        #expect(TextFileImport.title(forFileNamed: "nginx.conf") == "nginx")
        #expect(TextFileImport.title(forFileNamed: "deploy notes.md") == "deploy notes")
        #expect(TextFileImport.title(forFileNamed: ".env") == ".env")
    }
}
