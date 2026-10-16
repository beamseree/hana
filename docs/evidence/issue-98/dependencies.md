# Resolved Markdown preview dependencies

2026-10-15. Actual `Package.resolved`, checked-out Git HEADs, and `swift package show-dependencies --format json` agree on this graph:

| Package | Version | Revision |
| --- | --- | --- |
| grdb.swift | 7.11.1 | `b83108d10f42680d78f23fe4d4d80fc88dab3212` |
| swift-cmark | 0.9.0 | `08ddb528923cc1a6527e02b7a1aee9e516ca749a` |
| swift-markdown | 0.9.0 | `25cb61d3482054b09ae76ca4f281b1bfe7fe5a43` |

`Package.swift` exact-pins Swift Markdown 0.9.0. Its runtime transitive cmark dependency resolves to 0.9.0, and the committed lockfile pins the full revision. The existing GRDB pin is unchanged. The observed graph has no DocC plugin or SymbolKit package; although the upstream manifest declares a command-plugin dependency, neither appears in this resolved graph. No `SWIFTCI_USE_LOCAL_DEPS` override was used (its environment value was absent).

## Licenses and distribution

- GRDB.swift: MIT License, copied from the resolved checkout's `LICENSE`.
- Swift Markdown: Apache License 2.0 with the Swift Runtime Library Exception, copied in full from the resolved checkout's `LICENSE.txt`.
- swift-cmark: the complete upstream `COPYING`, including its BSD-style two-clause and bundled MIT-style notices and separately identified test/spec notices. It is not relabeled as one blanket MIT license.

The complete, unmodified license texts are concatenated with component headings in `App/Resources/ThirdPartyNotices.txt`. `scripts/build` copies that file into the signed app's Resources alongside the other resource files. The app does not ship the upstream test suites or documentation command plugins.

Primary source references: [tagged Swift Markdown manifest](https://github.com/swiftlang/swift-markdown/blob/0.9.0/Package.swift), [Markdown license](https://github.com/swiftlang/swift-markdown/blob/0.9.0/LICENSE.txt), [cmark COPYING](https://github.com/swiftlang/swift-cmark/blob/0.9.0/COPYING). These facts were verified against the actual resolved checkouts, rather than inferred from upstream latest-release metadata.
