import Foundation

/// A forgiving HTML tokenizer for pasteboard HTML. Not a browser parser: it
/// needs only to recover structure well enough to write markdown, from the
/// fragments browsers, Slack, Notion and mail clients put on the pasteboard.
/// It never resolves or fetches anything.
enum HTMLToken: Equatable {
    case start(name: String, attributes: [String: String], selfClosing: Bool)
    case end(name: String)
    case text(String)
}

enum HTMLTokenizer {
    /// Elements whose content is never shown.
    static let rawTextElements: Set<String> = ["script", "style", "title", "template", "noscript"]

    static func tokens(_ html: String) -> [HTMLToken] {
        var tokens: [HTMLToken] = []
        var text = ""
        var i = html.startIndex

        func flushText() {
            if !text.isEmpty { tokens.append(.text(decodeEntities(text))); text = "" }
        }

        while i < html.endIndex {
            let c = html[i]
            guard c == "<" else { text.append(c); i = html.index(after: i); continue }
            let rest = html[i...]
            if rest.hasPrefix("<!--") {
                flushText()
                i = rest.range(of: "-->")?.upperBound ?? html.endIndex
                continue
            }
            if rest.hasPrefix("<!") || rest.hasPrefix("<?") {
                flushText()
                i = rest.firstIndex(of: ">").map { html.index(after: $0) } ?? html.endIndex
                continue
            }
            let afterBracket = html.index(after: i)
            guard afterBracket < html.endIndex, html[afterBracket].isLetter || html[afterBracket] == "/" else {
                text.append(c); i = afterBracket; continue
            }
            guard let close = tagEnd(in: html, from: afterBracket) else {
                // No tag ever closes from here, and none will from any later
                // "<" either: the rest is text. Stopping here keeps
                // tokenizing linear on input like 100,000 "<a".
                text += html[i...]
                break
            }
            let inner = html[afterBracket..<close]
            let first = inner.first!
            flushText()
            i = html.index(after: close)
            if first == "/" {
                let name = inner.dropFirst().prefix(while: { $0.isLetter || $0.isNumber }).lowercased()
                tokens.append(.end(name: name))
                continue
            }
            let (name, attributes, selfClosing) = parseTag(String(inner))
            tokens.append(.start(name: name, attributes: attributes, selfClosing: selfClosing))
            if rawTextElements.contains(name), !selfClosing {
                // Skip to the matching close tag without tokenizing; scripts
                // contain "<" freely.
                if let end = html[i...].range(of: "</\(name)", options: .caseInsensitive) {
                    i = html[end.upperBound...].firstIndex(of: ">").map { html.index(after: $0) } ?? html.endIndex
                } else {
                    i = html.endIndex
                }
                tokens.append(.end(name: name))
            }
        }
        flushText()
        return tokens
    }

    /// The ">" that ends a tag, skipping any inside quoted attribute values
    /// (`<a href="?q=a>b">`).
    static func tagEnd(in html: String, from start: String.Index) -> String.Index? {
        var quote: Character?
        var i = start
        while i < html.endIndex {
            let c = html[i]
            if let open = quote {
                if c == open { quote = nil }
            } else if c == "\"" || c == "'" {
                quote = c
            } else if c == ">" {
                return i
            }
            i = html.index(after: i)
        }
        return nil
    }

    static func parseTag(_ inner: String) -> (String, [String: String], Bool) {
        var body = Substring(inner)
        let selfClosing = body.hasSuffix("/")
        if selfClosing { body = body.dropLast() }
        let name = body.prefix(while: { $0.isLetter || $0.isNumber || $0 == "-" }).lowercased()
        var rest = body.dropFirst(name.count)
        var attributes: [String: String] = [:]
        while true {
            rest = rest.drop(while: \.isWhitespace)
            let key = rest.prefix(while: { !$0.isWhitespace && $0 != "=" && $0 != ">" && $0 != "/" })
            guard !key.isEmpty else { break }
            rest = rest.dropFirst(key.count).drop(while: \.isWhitespace)
            var value = ""
            if rest.first == "=" {
                rest = rest.dropFirst().drop(while: \.isWhitespace)
                if let quote = rest.first, quote == "\"" || quote == "'" {
                    let content = rest.dropFirst().prefix(while: { $0 != quote })
                    value = String(content)
                    rest = rest.dropFirst(content.count + 2)
                } else {
                    let content = rest.prefix(while: { !$0.isWhitespace })
                    value = String(content)
                    rest = rest.dropFirst(content.count)
                }
            }
            attributes[key.lowercased()] = decodeEntities(value)
        }
        return (name, attributes, selfClosing)
    }

    static let namedEntities: [String: String] = [
        "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'", "nbsp": "\u{00A0}",
        "ndash": "–", "mdash": "—", "hellip": "…", "lsquo": "‘", "rsquo": "’", "ldquo": "“", "rdquo": "”",
        "copy": "©", "reg": "®", "trade": "™", "middot": "·", "bull": "•", "times": "×", "rarr": "→", "larr": "←",
    ]

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        var out = ""
        var i = text.startIndex
        while i < text.endIndex {
            guard text[i] == "&", let semi = text[i...].prefix(12).firstIndex(of: ";") else {
                out.append(text[i]); i = text.index(after: i); continue
            }
            let entity = text[text.index(after: i)..<semi]
            var decoded: String?
            if entity.hasPrefix("#x") || entity.hasPrefix("#X") {
                decoded = UInt32(entity.dropFirst(2), radix: 16).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else if entity.hasPrefix("#") {
                decoded = UInt32(entity.dropFirst()).flatMap(Unicode.Scalar.init).map { String(Character($0)) }
            } else {
                decoded = namedEntities[String(entity)]
            }
            if let decoded {
                out += decoded
                i = text.index(after: semi)
            } else {
                out.append(text[i]); i = text.index(after: i)
            }
        }
        return out
    }
}
