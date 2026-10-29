import Foundation
import Testing
import UniformTypeIdentifiers
@testable import BoopstashCore

@Suite struct ImageImportTests {
    @Test func originalsAreChosenOverAppKitsTIFF() {
        #expect(ImageImport.preferredType(among: ["public.tiff", "public.png"]) == .png)
        #expect(ImageImport.preferredType(among: ["public.tiff"]) == .tiff)
        #expect(ImageImport.preferredType(among: ["public.utf8-plain-text"]) == nil)
        #expect(ImageImport.preferredType(among: ["com.adobe.pdf"]) == nil, "a PDF is not an image here")
    }

    @Test func sizeAndTypeAreChecked() {
        let small = Data([1, 2, 3])
        #expect(ImageImport.check(small, type: .png) == .success(.png))
        #expect(ImageImport.check(Data(), type: .png) == .failure(.empty))
        #expect(ImageImport.check(Data(count: ImageImport.sizeLimit + 1), type: .jpeg) == .failure(.tooLarge(bytes: ImageImport.sizeLimit + 1)))
        if case .failure(.unsupported) = ImageImport.check(small, type: .pdf) {} else { Issue.record("PDF accepted") }
    }

    @Test func refusalsReadWell() {
        #expect(ImageImport.message(for: .tooLarge(bytes: 25_000_000), name: "shot.png").hasPrefix("shot.png is 25"))
        #expect(ImageImport.message(for: .empty) == "The image is empty.")
    }

    @Test func imageNotesAreTitledByTheirTextNotTheirMarkup() {
        let id = UUID()
        let reference = AttachmentReference.markdown(for: id)
        #expect(RuleTitler.title(for: reference, kind: .plain) == "Image")
        #expect(RuleTitler.title(for: AttachmentReference.markdown(for: id, alt: "Q3 chart"), kind: .plain) == "Q3 chart")
        #expect(RuleTitler.title(for: "\(reference)\nmeeting notes", kind: .plain) == "meeting notes")
    }
}
