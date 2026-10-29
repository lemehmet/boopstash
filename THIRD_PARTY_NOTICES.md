# Third-party notices

BoopStash is Apache-2.0. It builds on the following work, each under its own
licence.

## Libraries

| Project | Licence | Used for |
|---|---|---|
| [GRDB.swift](https://github.com/groue/GRDB.swift) | MIT | The note store and its full-text index |
| [SwiftTreeSitter](https://github.com/tree-sitter/swift-tree-sitter) | BSD-3-Clause | Parsing for syntax highlighting |
| [tree-sitter](https://github.com/tree-sitter/tree-sitter) | MIT | The parsing runtime |
| [swift-markdown](https://github.com/swiftlang/swift-markdown) | Apache-2.0 | Parsing markdown for the preview |
| [swift-cmark](https://github.com/swiftlang/swift-cmark) (cmark-gfm) | BSD-2-Clause, with MIT-licensed parts | The CommonMark and GitHub-extension parser beneath it |

## Grammars

Syntax highlighting uses these tree-sitter grammars and their highlight
queries, each pinned in `Project.swift`: JSON, YAML, TOML, XML, Markdown,
HTML, CSS, JavaScript, TypeScript, Python, Ruby, Bash, Go, Rust, C, C++ and
Java from [tree-sitter](https://github.com/tree-sitter) and
[tree-sitter-grammars](https://github.com/tree-sitter-grammars) (MIT);
[tree-sitter-swift](https://github.com/alex-pinkus/tree-sitter-swift) (MIT);
[tree-sitter-sql](https://github.com/DerekStride/tree-sitter-sql) (MIT);
[tree-sitter-diff](https://github.com/the-mikedavis/tree-sitter-diff) (MIT).

## Formatters

Format Document runs these in the sandboxed script service (ADR 0007),
unmodified, pinned in `Vendor/`:

| Project | Version | Licence |
|---|---|---|
| [Prettier](https://prettier.io) (standalone and its babel, estree, typescript, postcss, html, yaml and markdown plugins) | 3.9.9 | MIT (`Vendor/Prettier/LICENSE`); the code Prettier bundles is listed with its licences in `Vendor/Prettier/THIRD-PARTY-NOTICES.md`, as Prettier ships it |
| [sql-formatter](https://github.com/sql-formatter-org/sql-formatter) | 15.9.0 | MIT (`Vendor/SQLFormatter/LICENSE`); its bundle includes [nearley](https://github.com/kach/nearley) (MIT) |
| [all-MiniLM-L6-v2](https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2) (sentence-transformers) | c9745ed | Apache-2.0 (`Vendor/MiniLM/LICENSE`); converted to Core ML by `scripts/models/convert-minilm.py`, for on-device semantic search |

## Boop scripts

The bundled scripts in `Vendor/Boop/scripts` come from
[Boop](https://github.com/IvanMathy/Boop) by Ivan Mathy (MIT; see
`Vendor/Boop/LICENSE`), pinned at commit `5cf6914`. The libraries they load
with `require('@boop/…')`, in `Vendor/Boop/lib`, are under their own licences:

| Library | Licence |
|---|---|
| base64.js | BSD-3-Clause |
| hashes.js ([jsHashes](https://github.com/h2non/jshashes)) | BSD-3-Clause |
| he.js ([he](https://github.com/mathiasbynens/he)) | MIT |
| js-yaml.js ([js-yaml](https://github.com/nodeca/js-yaml)) | MIT |
| lodash.boop.js ([Lodash](https://lodash.com), custom build) | MIT |
| papaparse.js ([Papa Parse](https://www.papaparse.com)) | MIT |
| vkBeautify.js ([vkBeautify](https://github.com/vkiryukhin/vkBeautify)) | MIT |

## Colour themes

The editor's themes reproduce the published colour values of these schemes.
No code or assets from them are included.

| Theme | Author | Licence |
|---|---|---|
| [Solarized](https://ethanschoonover.com/solarized/) | Ethan Schoonover | MIT |
| GitHub Light and Dark ([Primer primitives](https://github.com/primer/primitives)) | GitHub, Inc. | MIT |
| [One Light and One Dark](https://github.com/atom/atom/tree/master/packages) | GitHub, Inc. (Atom) | MIT |
| [Gruvbox](https://github.com/morhetz/gruvbox) | Pavel Pertsev | MIT |
| [Dracula](https://draculatheme.com) | Dracula Theme | MIT |
| [Nord](https://www.nordtheme.com) | Sven Greb, Arctic Ice Studio | MIT |
