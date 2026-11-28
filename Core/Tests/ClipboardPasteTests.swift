import Foundation
import Testing
import UniformTypeIdentifiers
@testable import BoopstashCore

/// Pasting an image on iOS (#310): what a paste takes, and where an
/// image's text goes.
@Suite struct ClipboardPasteTests {
    static let png = "public.png"
    static let text = "public.utf8-plain-text"

    @Test func textAloneIsText() {
        #expect(ClipboardPaste.decide(types: [Self.text], hasText: true) == .text)
    }

    @Test func anImageAloneIsTheImage() {
        #expect(ClipboardPaste.decide(types: [Self.png], hasText: false) == .image(.png))
        // The best kept type of those offered, as for every import.
        #expect(ClipboardPaste.decide(types: ["public.tiff", "public.jpeg"], hasText: false) == .image(.jpeg))
    }

    @Test func textWinsOverAnImage() {
        #expect(ClipboardPaste.decide(types: [Self.png, Self.text], hasText: true) == .text)
    }

    @Test func blankTextBesideAnImageIsTheImage() {
        #expect(ClipboardPaste.decide(types: [Self.png, Self.text], hasText: false) == .image(.png))
    }

    @Test func anImageOfATypeNotKeptIsNamed() {
        guard case .otherImage(let name) = ClipboardPaste.decide(types: ["com.microsoft.bmp"], hasText: false) else {
            Issue.record("a BMP is an image")
            return
        }
        #expect(!name.isEmpty)
    }

    @Test func nothingIsNothing() {
        #expect(ClipboardPaste.decide(types: [], hasText: false) == .nothing)
        #expect(ClipboardPaste.decide(types: [Self.text], hasText: false) == .nothing)
        #expect(ClipboardPaste.decide(types: ["public.url"], hasText: false) == .nothing)
    }

    @Test func aConcealedOrTransientClipboardIsRefusedWhateverItHolds() {
        for other in [[Self.text], [Self.png], [Self.png, Self.text]] {
            #expect(ClipboardPaste.decide(types: other + ["org.nspasteboard.ConcealedType"], hasText: true) == .refuse(.refuseConcealed))
            #expect(ClipboardPaste.decide(types: other + ["org.nspasteboard.TransientType"], hasText: false) == .refuse(.refuseTransient))
        }
    }

    @Test func aRefusalSaysWhy() {
        #expect(ClipboardPaste.message(for: .refuseConcealed, verb: "pasted") == "Not pasted: the clipboard holds a password manager item.")
        #expect(ClipboardPaste.message(for: .refuseTransient, verb: "saved") == "Not saved: the app it came from marked it as not to be kept.")
        #expect(ClipboardPaste.message(for: .accept, verb: "pasted") == nil)
    }
}

@Suite struct ImageTextInsertionTests {
    static let one = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    static let two = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    static func reference(_ id: UUID) -> String { AttachmentReference.markdown(for: id) }
    static var length: Int { (reference(one) as NSString).length }

    @Test func theTextGoesOnALineOfItsOwnUnderTheReferencesLine() {
        let text = "before\nsee \(Self.reference(Self.one)) here\nafter"
        let lineEnd = (text as NSString).range(of: " here").upperBound
        let outcome = ImageTextInsertion.insertion(of: "read text", under: Self.one, chosenAt: 11, in: text)
        #expect(outcome == .edit(.init(location: lineEnd, text: "\nread text", selection: NSRange(location: lineEnd + 1, length: 9))))
    }

    @Test func aReferenceOnTheLastLineTakesTheTextAfterIt() {
        let text = Self.reference(Self.one)
        #expect(ImageTextInsertion.insertion(of: "t", under: Self.one, chosenAt: 0, in: text)
            == .edit(.init(location: Self.length, text: "\nt", selection: NSRange(location: Self.length + 1, length: 1))))
    }

    @Test func aCRLFLineEndsBeforeItsCR() {
        let text = Self.reference(Self.one) + "\r\nnext"
        guard case .edit(let edit) = ImageTextInsertion.insertion(of: "t", under: Self.one, chosenAt: 0, in: text) else {
            Issue.record("the reference is there")
            return
        }
        #expect(edit.location == Self.length)
    }

    @Test func aReferenceThatMovedIsStillTheOnlyOne() {
        let text = "typed meanwhile\n" + Self.reference(Self.one)
        guard case .edit(let edit) = ImageTextInsertion.insertion(of: "t", under: Self.one, chosenAt: 0, in: text) else {
            Issue.record("one reference is the one")
            return
        }
        #expect(edit.location == (text as NSString).length)
    }

    @Test func withCopiesTheOneStillInPlaceIsChosen() {
        let text = Self.reference(Self.one) + "\n" + Self.reference(Self.one)
        guard case .edit(let second) = ImageTextInsertion.insertion(of: "t", under: Self.one, chosenAt: Self.length + 1, in: text) else {
            Issue.record("the second copy is in place")
            return
        }
        #expect(second.location == (text as NSString).length)
        guard case .edit(let first) = ImageTextInsertion.insertion(of: "t", under: Self.one, chosenAt: 0, in: text) else {
            Issue.record("the first copy is in place")
            return
        }
        #expect(first.location == Self.length)
    }

    @Test func withCopiesAndNoneInPlaceNothingIsInserted() {
        let text = "x" + Self.reference(Self.one) + "\n" + Self.reference(Self.one)
        let outcome = ImageTextInsertion.insertion(of: "t", under: Self.one, chosenAt: 0, in: text)
        #expect(outcome == .ambiguous && outcome.message?.contains("other copies") == true)
        #expect(ImageTextInsertion.insertion(of: "t", under: Self.one, chosenAt: nil, in: text) == .ambiguous)
    }

    @Test func anImageNoLongerInTheNoteIsGone() {
        let outcome = ImageTextInsertion.insertion(of: "t", under: Self.one, chosenAt: 0, in: Self.reference(Self.two))
        #expect(outcome == .gone && outcome.message?.contains("no longer in this note") == true)
    }

    @Test func theReferenceUnderTheCaretOrTheSelection() {
        let text = "ab " + Self.reference(Self.one) + " cd " + Self.reference(Self.two)
        let first = NSRange(location: 3, length: Self.length)
        func id(_ location: Int, _ length: Int = 0) -> UUID? {
            ImageTextInsertion.reference(in: text, at: NSRange(location: location, length: length))?.id
        }
        // The caret inside, and at either end.
        #expect(id(first.location) == Self.one && id(first.location + 5) == Self.one && id(NSMaxRange(first)) == Self.one)
        #expect(ImageTextInsertion.reference(in: text, at: NSRange(location: 10, length: 0))?.range == first)
        // Outside.
        #expect(id(0) == nil && id(2) == nil && id(NSMaxRange(first) + 1) == nil)
        // A selection that overlaps; one that only touches does not.
        #expect(id(0, 4) == Self.one && id(0, 3) == nil)
        // Over both: the first.
        #expect(id(0, (text as NSString).length) == Self.one)
        #expect(id(NSMaxRange(first) + 2, 10) == Self.two)
    }
}
