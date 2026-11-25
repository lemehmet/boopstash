import Foundation

/// Comparing a script's output with the expected text. Trailing spaces on a
/// line and blank lines at the end are not counted; everything else is.
public enum Score: Equatable, Sendable {
    case pass
    /// The first line that differs (1-based), what was expected there and
    /// what the script wrote ("" past the end), and how many lines matched.
    case wrong(line: Int, expected: String, actual: String, matching: Int, of: Int)

    public static func compare(actual: String, expected: String) -> Score {
        let got = lines(actual), want = lines(expected)
        if got == want { return .pass }
        let matching = zip(got, want).filter { $0 == $1 }.count
        let first = zip(got, want).enumerated().first { $0.element.0 != $0.element.1 }?.offset ?? min(got.count, want.count)
        return .wrong(line: first + 1,
                      expected: first < want.count ? want[first] : "",
                      actual: first < got.count ? got[first] : "",
                      matching: matching, of: want.count)
    }

    static func lines(_ text: String) -> [String] {
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                var line = Substring(line)
                while let last = line.last, last == " " || last == "\t" { line.removeLast() }
                return String(line)
            }
        while lines.last == "" { lines.removeLast() }
        return lines
    }
}
