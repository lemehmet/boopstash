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
        // A reply cut off inside its only block: take what follows the fence.
        if blocks.isEmpty, let open = reply.range(of: "```") {
            let rest = reply[open.upperBound...]
            let body = rest.drop { $0 != "\n" }.dropFirst()
            let code = String(body).trimmingCharacters(in: .whitespacesAndNewlines)
            return definesMain(code) ? code : nil
        }
        let bare = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        return blocks.isEmpty && definesMain(bare) ? bare : nil
    }

    /// The bodies of the reply's ``` blocks, without the fences and the
    /// language tag.
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
        return blocks
    }

    /// Whether the code declares `main` as a function, or assigns one to it.
    public static func definesMain(_ code: String) -> Bool {
        code.range(of: #"function\s+main\s*\("#, options: .regularExpression) != nil
            || code.range(of: #"\bmain\s*=\s*(async\s+)?(function\b|\(|[A-Za-z_$][\w$]*\s*=>)"#, options: .regularExpression) != nil
    }
}
