import Foundation
import Testing
@testable import BoopstashCore

@Suite struct TextFindTests {
    func ranges(_ text: String, _ query: FindQuery) throws -> [NSRange] {
        try TextFind.matches(in: text, for: query)
    }

    func range(_ text: String, of part: String, occurrence: Int = 0) -> NSRange {
        let ns = text as NSString
        var search = NSRange(location: 0, length: ns.length)
        var found = NSRange(location: NSNotFound, length: 0)
        for _ in 0...occurrence {
            found = ns.range(of: part, options: .literal, range: search)
            search = NSRange(location: NSMaxRange(found), length: ns.length - NSMaxRange(found))
        }
        return found
    }

    @Test func literalSearchIgnoresCaseUnlessAsked() throws {
        let text = "Foo foo FOO fool"
        #expect(try ranges(text, FindQuery("foo")).count == 4)
        #expect(try ranges(text, FindQuery("foo", matchCase: true)) == [NSRange(location: 4, length: 3), NSRange(location: 12, length: 3)])
    }

    @Test func emptyQueryMatchesNothing() throws {
        #expect(try ranges("anything", FindQuery("")).isEmpty)
        #expect(try ranges("anything", FindQuery("", isRegex: true)).isEmpty)
    }

    @Test func literalQueryIsNotARegex() throws {
        #expect(try ranges("a.c abc", FindQuery("a.c")) == [NSRange(location: 0, length: 3)])
        #expect(try ranges("a.c abc", FindQuery("a.c", isRegex: true)).count == 2)
    }

    @Test func wholeWordStopsAtWordCharactersOnly() throws {
        let text = "cat catalog cat. -cat bobcat"
        #expect(try ranges(text, FindQuery("cat", wholeWord: true)) == [NSRange(location: 0, length: 3), NSRange(location: 12, length: 3), NSRange(location: 18, length: 3)])
        // A query that begins or ends with punctuation is still "not inside
        // a word", which `\b` would get wrong.
        #expect(try ranges("x -cat y-cat", FindQuery("-cat", wholeWord: true)) == [NSRange(location: 2, length: 4)])
        #expect(try ranges("ab abc", FindQuery("ab|abc", wholeWord: true, isRegex: true)).count == 2)
    }

    @Test func matchesDoNotOverlap() throws {
        #expect(try ranges("aaaa", FindQuery("aa")) == [NSRange(location: 0, length: 2), NSRange(location: 2, length: 2)])
    }

    @Test func anchorsAreLineAnchors() throws {
        #expect(try ranges("one\ntwo\r\nthree", FindQuery("^", isRegex: true)).map(\.location) == [0, 4, 9])
        #expect(try ranges("one\ntwo", FindQuery("o$", isRegex: true)).count == 1)
    }

    @Test func invalidRegexIsAnError() {
        #expect(throws: FindError.self) { try TextFind.matches(in: "x", for: FindQuery("(", isRegex: true)) }
        #expect(throws: Never.self) { try TextFind.matches(in: "x", for: FindQuery("(")) }
    }

    @Test func searchStopsAtTheLimit() throws {
        let text = String(repeating: "a", count: 100)
        #expect(try TextFind.matches(in: text, for: FindQuery("a"), limit: 10).count == 10)
    }

    // MARK: Navigation

    let matches = [NSRange(location: 2, length: 3), NSRange(location: 10, length: 3), NSRange(location: 20, length: 3)]

    @Test func firstFromTheSelectionPrefersTheMatchItIsOn() {
        #expect(TextFind.first(from: NSRange(location: 10, length: 3), in: matches) == 1)
        #expect(TextFind.first(from: NSRange(location: 0, length: 0), in: matches) == 0)
        #expect(TextFind.first(from: NSRange(location: 11, length: 0), in: matches) == 2)
        #expect(TextFind.first(from: NSRange(location: 30, length: 0), in: matches) == 0, "wraps")
        #expect(TextFind.first(from: NSRange(location: 0, length: 0), in: []) == nil)
    }

    @Test func nextAndPreviousWrap() {
        #expect(TextFind.next(after: NSRange(location: 10, length: 3), in: matches) == 2)
        #expect(TextFind.next(after: NSRange(location: 20, length: 3), in: matches) == 0)
        #expect(TextFind.next(after: NSRange(location: 11, length: 0), in: matches) == 2, "a caret inside a match goes past it")
        #expect(TextFind.next(after: NSRange(location: 2, length: 0), in: matches) == 0, "a caret at a match's start takes it")
        #expect(TextFind.previous(before: NSRange(location: 10, length: 3), in: matches) == 0)
        #expect(TextFind.previous(before: NSRange(location: 2, length: 3), in: matches) == 2)
        #expect(TextFind.previous(before: NSRange(location: 11, length: 0), in: matches) == 0, "a caret inside a match goes before it")
        #expect(TextFind.previous(before: NSRange(location: 13, length: 0), in: matches) == 1, "a caret at a match's end takes it")
    }

    @Test func aZeroLengthMatchNeverHoldsTheCaret() {
        let empties = [NSRange(location: 0, length: 0), NSRange(location: 4, length: 0)]
        #expect(TextFind.next(after: NSRange(location: 0, length: 0), in: empties) == 1)
        #expect(TextFind.next(after: NSRange(location: 4, length: 0), in: empties) == 0)
        #expect(TextFind.previous(before: NSRange(location: 0, length: 0), in: empties) == 1)
    }

    @Test func indexOfSelectionNeedsAnExactMatch() {
        #expect(TextFind.index(of: NSRange(location: 10, length: 3), in: matches) == 1)
        #expect(TextFind.index(of: NSRange(location: 10, length: 2), in: matches) == nil)
        #expect(TextFind.index(of: NSRange(location: 9, length: 0), in: matches) == nil)
    }

    // MARK: Replacing

    @Test func literalReplacementIsTakenAsWritten() throws {
        let text = "price: 5"
        let match = range(text, of: "5")
        #expect(try TextFind.replacement(for: match, in: text, query: FindQuery("5"), template: "$1\\n") == "$1\\n")
    }

    @Test func regexReplacementExpandsGroups() throws {
        let text = "2026-11-05"
        let query = FindQuery(#"(\d+)-(\d+)-(\d+)"#, isRegex: true)
        let match = try #require(try ranges(text, query).first)
        #expect(try TextFind.replacement(for: match, in: text, query: query, template: "$3/$2/$1") == "05/11/2026")
    }

    @Test func replacementOfARangeThatIsNoMatchIsNil() throws {
        let text = "cat concat"
        let query = FindQuery("cat", wholeWord: true)
        #expect(try TextFind.replacement(for: range(text, of: "cat", occurrence: 1), in: text, query: query, template: "dog") == nil)
        #expect(try TextFind.replacement(for: range(text, of: "cat"), in: text, query: query, template: "dog") == "dog")
        // `^` at a range's start means the line's start, not the range's.
        #expect(try TextFind.replacement(for: NSRange(location: 4, length: 0), in: text, query: FindQuery("^", isRegex: true), template: "> ") == nil)
        #expect(try TextFind.replacement(for: NSRange(location: 0, length: 0), in: text, query: FindQuery("^", isRegex: true), template: "> ") == "> ")
    }

    @Test func replaceAllListsEveryMatchInOrder() throws {
        let text = "a1 b22 c333"
        let edits = try TextFind.replacements(in: text, for: FindQuery(#"\d+"#, isRegex: true), template: "<$0>")
        #expect(edits.map(\.text) == ["<1>", "<22>", "<333>"])
        #expect(edits.map(\.range) == [NSRange(location: 1, length: 1), NSRange(location: 4, length: 2), NSRange(location: 8, length: 3)])
        let replaced = edits.reversed().reduce(text as NSString) { $0.replacingCharacters(in: $1.range, with: $1.text) as NSString }
        #expect(replaced == "a<1> b<22> c<333>")
    }

    @Test func regexReplaceAtEveryLineStart() throws {
        let edits = try TextFind.replacements(in: "one\ntwo", for: FindQuery("^", isRegex: true), template: "- ")
        let replaced = edits.reversed().reduce("one\ntwo" as NSString) { $0.replacingCharacters(in: $1.range, with: $1.text) as NSString }
        #expect(replaced == "- one\n- two")
    }

    @Test func replacementsCanRunPastTheCountingCap() throws {
        let text = String(repeating: "a", count: TextFind.matchLimit + 5)
        #expect(try TextFind.replacements(in: text, for: FindQuery("a"), template: "b").count == TextFind.matchLimit)
        #expect(try TextFind.replacements(in: text, for: FindQuery("a"), template: "b", limit: .max).count == TextFind.matchLimit + 5)
    }

    @Test func seedingEscapesForARegexQuery() {
        #expect(TextFind.seed("a.b", isRegex: false) == "a.b")
        #expect(TextFind.seed("a.b", isRegex: true) == "a\\.b")
    }
}
