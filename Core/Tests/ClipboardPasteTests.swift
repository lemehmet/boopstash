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
    static func at(_ location: Int) -> NSRange { NSRange(location: location, length: length) }

    @Test func theTextGoesOnALineOfItsOwnUnderTheReferencesLine() {
        let text = "before\nsee \(Self.reference(Self.one)) here\nafter"
        let lineEnd = (text as NSString).range(of: " here").upperBound
        let outcome = ImageTextInsertion.insertion(of: "read text", under: Self.one, at: Self.at(11), in: text)
        #expect(outcome == .edit(.init(location: lineEnd, text: "\nread text", selection: NSRange(location: lineEnd + 1, length: 9))))
    }

    @Test func aReferenceOnTheLastLineTakesTheTextAfterIt() {
        #expect(ImageTextInsertion.insertion(of: "t", under: Self.one, at: Self.at(0), in: Self.reference(Self.one))
            == .edit(.init(location: Self.length, text: "\nt", selection: NSRange(location: Self.length + 1, length: 1))))
    }

    @Test func aCRLFLineEndsBeforeItsCR() {
        let text = Self.reference(Self.one) + "\r\nnext"
        guard case .edit(let edit) = ImageTextInsertion.insertion(of: "t", under: Self.one, at: Self.at(0), in: text) else {
            Issue.record("the reference is there")
            return
        }
        #expect(edit.location == Self.length)
    }

    @Test func withCopiesOnlyTheChosenOneTakesTheText() {
        let text = Self.reference(Self.one) + "\n" + Self.reference(Self.one)
        guard case .edit(let second) = ImageTextInsertion.insertion(of: "t", under: Self.one, at: Self.at(Self.length + 1), in: text) else {
            Issue.record("the second copy was chosen")
            return
        }
        #expect(second.location == (text as NSString).length)
        guard case .edit(let first) = ImageTextInsertion.insertion(of: "t", under: Self.one, at: Self.at(0), in: text) else {
            Issue.record("the first copy was chosen")
            return
        }
        #expect(first.location == Self.length)
    }

    /// The review's case: the chosen copy deleted while the image was read
    /// leaves one other copy, which never takes the text.
    @Test func theChosenCopyGoneLeavesTheOtherAlone() {
        let after = Self.reference(Self.one)
        // The second copy was chosen; the tracker lost it with the delete.
        #expect(ImageTextInsertion.insertion(of: "t", under: Self.one, at: nil, in: after) == .gone)
        // Nor does another copy that came to sit where the chosen one was.
        #expect(ImageTextInsertion.insertion(of: "t", under: Self.two, at: Self.at(0), in: after) == .gone)
    }

    @Test func aRangeThatIsNotAReferenceToTheImageIsGone() {
        let text = "xx" + Self.reference(Self.one)
        let outcome = ImageTextInsertion.insertion(of: "t", under: Self.one, at: Self.at(0), in: text)
        #expect(outcome == .gone && outcome.message?.contains("no longer in this note") == true)
        #expect(ImageTextInsertion.insertion(of: "t", under: Self.one, at: Self.at(2), in: text) != .gone)
    }

    /// The tracking the iOS editor does, from the choice to the insert.
    @Test func aChosenReferenceFollowedThroughEditsStillTakesTheText() {
        var text = Self.reference(Self.one) + "\n" + Self.reference(Self.one)
        var chosen: NSRange? = Self.at(Self.length + 1)
        func edit(_ range: NSRange, _ replacement: String) {
            text = (text as NSString).replacingCharacters(in: range, with: replacement)
            let edited = NSRange(location: range.location, length: (replacement as NSString).length)
            chosen = chosen.flatMap { TrackedRange.adjusted($0, editedRange: edited, delta: edited.length - range.length) }
        }
        // Typed above both copies: the chosen one moves with its text.
        edit(NSRange(location: 0, length: 0), "abc\n")
        guard case .edit(let moved) = ImageTextInsertion.insertion(of: "t", under: Self.one, at: chosen, in: text) else {
            Issue.record("the chosen copy moved and is still there")
            return
        }
        #expect(moved.location == (text as NSString).length)
        // The chosen copy deleted: the first one is left, and is not it.
        edit(chosen!, "")
        #expect(chosen == nil)
        #expect(ImageTextInsertion.insertion(of: "t", under: Self.one, at: chosen, in: text) == .gone)
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
