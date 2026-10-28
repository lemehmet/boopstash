import Foundation
import SwiftTreeSitter
import TreeSitterBash
import TreeSitterC
import TreeSitterCPP
import TreeSitterCSS
import TreeSitterDiff
import TreeSitterGo
import TreeSitterHTML
import TreeSitterJava
import TreeSitterJavaScript
import TreeSitterJSON
import TreeSitterMarkdown
import TreeSitterPython
import TreeSitterRuby
import TreeSitterRust
import TreeSitterSql
import TreeSitterSwift
import TreeSitterTOML
import TreeSitterTypeScript
import TreeSitterXML
import TreeSitterYAML

/// Where each language's parser and highlight query come from.
enum Grammars {
    static func language(for syntax: SyntaxLanguage) -> Language? {
        let pointer: OpaquePointer? = switch syntax {
        case .json: tree_sitter_json()
        case .yaml: tree_sitter_yaml()
        case .toml: tree_sitter_toml()
        case .xml: tree_sitter_xml()
        case .markdown: tree_sitter_markdown()
        case .html: tree_sitter_html()
        case .css: tree_sitter_css()
        case .javascript: tree_sitter_javascript()
        case .typescript: tree_sitter_typescript()
        case .python: tree_sitter_python()
        case .bash: tree_sitter_bash()
        case .go: tree_sitter_go()
        case .rust: tree_sitter_rust()
        case .c: tree_sitter_c()
        case .cpp: tree_sitter_cpp()
        case .ruby: tree_sitter_ruby()
        case .sql: tree_sitter_sql()
        case .java: tree_sitter_java()
        case .swift: tree_sitter_swift()
        case .diff: tree_sitter_diff()
        }
        return pointer.map { Language(language: $0) }
    }

    /// The resource bundles holding each language's queries, named
    /// `<Package>_<Target>.bundle` by SwiftPM. TypeScript's and C++'s own
    /// queries only add to JavaScript's and C's, so both are read, base first.
    static func queryBundles(for syntax: SyntaxLanguage) -> [String] {
        switch syntax {
        case .json: ["TreeSitterJSON_TreeSitterJSON"]
        case .yaml: ["TreeSitterYAML_TreeSitterYAML"]
        case .toml: ["TreeSitterTOML_TreeSitterTOML"]
        case .xml: ["TreeSitterXML_TreeSitterXML"]
        case .markdown: ["TreeSitterMarkdown_TreeSitterMarkdown"]
        case .html: ["TreeSitterHTML_TreeSitterHTML"]
        case .css: ["TreeSitterCSS_TreeSitterCSS"]
        case .javascript: ["TreeSitterJavaScript_TreeSitterJavaScript"]
        case .typescript: ["TreeSitterJavaScript_TreeSitterJavaScript", "TreeSitterTypeScript_TreeSitterTypeScript"]
        case .python: ["TreeSitterPython_TreeSitterPython"]
        case .bash: ["TreeSitterBash_TreeSitterBash"]
        case .go: ["TreeSitterGo_TreeSitterGo"]
        case .rust: ["TreeSitterRust_TreeSitterRust"]
        case .c: ["TreeSitterC_TreeSitterC"]
        case .cpp: ["TreeSitterC_TreeSitterC", "TreeSitterCPP_TreeSitterCPP"]
        case .ruby: ["TreeSitterRuby_TreeSitterRuby"]
        case .sql: ["TreeSitterSql_TreeSitterSql"]
        case .java: ["TreeSitterJava_TreeSitterJava"]
        case .swift: ["TreeSitterSwift_TreeSitterSwift"]
        case .diff: ["TreeSitterDiff_TreeSitterDiff"]
        }
    }

    /// The highlight query source. Bundles land in different places
    /// depending on what links the package (app, framework, test bundle), so
    /// every loaded bundle's resources are searched, and the query file is
    /// found anywhere inside the grammar's bundle.
    static func highlightsQuery(for syntax: SyntaxLanguage) -> Data? {
        let parts = queryBundles(for: syntax).compactMap { name -> Data? in
            guard let bundle = bundleURL(named: name + ".bundle") else { return nil }
            return firstFile(named: "highlights.scm", under: bundle).flatMap { try? Data(contentsOf: $0) }
        }
        guard parts.count == queryBundles(for: syntax).count else { return nil }
        return parts.reduce(Data()) { $0 + $1 + Data("\n".utf8) }
    }

    private static func bundleURL(named name: String) -> URL? {
        let roots = (Bundle.allFrameworks + Bundle.allBundles + [Bundle.main]).compactMap(\.resourceURL)
        for root in roots {
            let candidate = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return nil
    }

    private static func firstFile(named name: String, under root: URL) -> URL? {
        let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            if url.lastPathComponent == name { return url }
        }
        return nil
    }
}
