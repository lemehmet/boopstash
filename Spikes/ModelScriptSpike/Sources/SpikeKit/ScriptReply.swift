import Foundation

/// Finding the script in a model's reply. The model is asked for one code
/// block; it also answers with prose around the block, several blocks, or
/// bare code.
public enum ScriptReply {
    /// The script, or nil when the reply holds nothing that defines `main`.
    /// A fenced block that defines `main` wins (the last one, as a model
    /// that corrects itself puts the fix last); otherwise the whole reply,
    /// when it is bare code.
    public static func extract(_ reply: String) -> String? {
        let blocks = fencedBlocks(reply)
        if let block = blocks.last(where: definesMain) { return block }
        let bare = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        return blocks.isEmpty && definesMain(bare) ? bare : nil
    }

    /// The bodies of the reply's ``` blocks, without the fences and the
    /// language tag. A last block that was never closed (a reply cut off at
    /// the token cap) counts, whatever came before it.
    static func fencedBlocks(_ reply: String) -> [String] {
        var blocks: [String] = []
        var current: [Substring]?
        for line in reply.split(separator: "\n", omittingEmptySubsequences: false) {
            let isFence = line.trimmingCharacters(in: .whitespaces).hasPrefix("```")
            if isFence {
                if let body = current {
                    blocks.append(body.joined(separator: "\n"))
                    current = nil
                } else {
                    current = []
                }
            } else {
                current?.append(line)
            }
        }
        if let open = current {
            let body = open.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !body.isEmpty { blocks.append(body) }
        }
        return blocks
    }

    /// Whether the code defines `main` where the script service looks for
    /// it, as a property of the global object: a function declaration, or a
    /// function assigned to `main` with `var` or with no keyword. `const
    /// main = …` and `let main = …` do not count: they bind a name the
    /// service cannot see, and such a script fails there with "no main
    /// function".
    public static func definesMain(_ code: String) -> Bool {
        if code.range(of: #"function\s*\*?\s+main\s*\("#, options: .regularExpression) != nil { return true }
        let assignment = try! NSRegularExpression(
            pattern: #"(?:\b(const|let|var)\s+)?(?<![\w$.])main\s*=\s*(?:async\s+)?(?:function\b|\(|[A-Za-z_$][\w$]*\s*=>)"#)
        let whole = NSRange(code.startIndex..., in: code)
        return assignment.matches(in: code, range: whole).contains { match in
            guard let keyword = Range(match.range(at: 1), in: code) else { return true }
            return code[keyword] == "var"
        }
    }
}
