import Testing
@testable import Hana

struct MarkdownPreviewTests {
    @Test func supportedConstructsBecomeReadOnlyPresentationValues() async {
        let source = """
        # Title ไทย🌸

        A *soft* and **strong** with `code` and [link](https://example.com).

        > Quote

        - first
        - second

        3. third
        4. fourth

        ```swift
        let a = 1
        ```
        """
        let preview = await MarkdownPreview.parse(source)
        #expect(preview.blocks == [
            .heading(1, [.text("Title ไทย🌸")]),
            .paragraph([.text("A "), .emphasis([.text("soft")]), .text(" and "), .strong([.text("strong")]),
                        .text(" with "), .code("code"), .text(" and "),
                        .link("https://example.com", [.text("link")]), .text(".")]),
            .quote([.paragraph([.text("Quote")])]),
            .list(start: nil, items: [[.paragraph([.text("first")])], [.paragraph([.text("second")])]]),
            .list(start: 3, items: [[.paragraph([.text("third")])], [.paragraph([.text("fourth")])]]),
            .code("let a = 1\n")
        ])
    }
    struct Fixture: Sendable, CustomStringConvertible {
        var description: String { name }
        let name: String
        let source: String
        let blocks: [MarkdownPreviewBlock]
    }

    static let literalFixtures: [Fixture] = [
        .init(name: "table", source: "| A | B |\n| - | - |\n| ไทย🌸 | value |", blocks: [.literal("| A | B |\n| - | - |\n| ไทย🌸 | value |")]),
        .init(name: "strike after Unicode", source: "ไทย🌸 ~~strike~~", blocks: [.paragraph([.text("ไทย🌸 "), .literal("~~strike~~")])]),
        .init(name: "task list", source: "- [x] Done\n- [ ] Open", blocks: [.literal("- [x] Done\n- [ ] Open")]),
        .init(name: "remote image", source: "![ไทย🌸](https://example.invalid/image.png \"title\")", blocks: [.paragraph([.literal("![ไทย🌸](https://example.invalid/image.png \"title\")")])]),
        .init(name: "reference image", source: "![ไทย🌸][ref]\n\n[ref]: https://example.invalid/image.png", blocks: [.paragraph([.literal("![ไทย🌸][ref]")]), .literal("\n\n[ref]: https://example.invalid/image.png")]),
        .init(name: "block HTML", source: "<div>ไทย🌸</div>", blocks: [.literal("<div>ไทย🌸</div>")]),
        .init(name: "inline HTML", source: "ก่อน🌸 <b>หนา</b>", blocks: [.paragraph([.text("ก่อน🌸 "), .literal("<b>"), .text("หนา"), .literal("</b>")])]),
        .init(name: "thematic break", source: "---", blocks: [.literal("---")]),
        .init(name: "unused definition", source: "[unused]: https://example.com", blocks: [.literal("[unused]: https://example.com")]),
        .init(name: "footnote-like text", source: "[^a]: unrendered reference", blocks: [.paragraph([.text("[^a]: unrendered reference")])]),
        .init(name: "CRLF", source: "ไทย🌸 ~~strike~~\r\nnext", blocks: [.paragraph([.text("ไทย🌸 "), .literal("~~strike~~"), .text(" "), .text("next")])]),
        .init(name: "CR", source: "ไทย🌸 ~~strike~~\rnext", blocks: [.paragraph([.text("ไทย🌸 "), .literal("~~strike~~"), .text(" "), .text("next")])]),
        .init(name: "nested quote", source: "> ไทย🌸 ~~strike~~", blocks: [.quote([.paragraph([.text("ไทย🌸 "), .literal("~~strike~~")])])]),
        .init(name: "tabbed code", source: "\t~~strike~~", blocks: [.code("~~strike~~\n")]),
        .init(name: "nested list", source: "- ไทย🌸\n  - ~~strike~~", blocks: [.list(start: nil, items: [[.paragraph([.text("ไทย🌸")]), .list(start: nil, items: [[.paragraph([.literal("~~strike~~")])]])]])])
    ]

    @Test(arguments: literalFixtures)
    func unsupportedSyntaxStaysLiteralWithoutImageOrHTMLLoading(fixture: Fixture) async {
        let preview = await MarkdownPreview.parse(fixture.source)
        #expect(preview.blocks == fixture.blocks, Comment(rawValue: fixture.name))
    }

    @Test func aReferenceDefinitionBeforeAnUnsupportedImageIsNotDropped() async {
        let source = "[ref]: https://example.invalid/image.png\n![ไทย🌸][ref]"
        let preview = await MarkdownPreview.parse(source)
        let preservedDefinition = preview.blocks.contains { block in
            if case .literal(let text) = block { return text.contains("[ref]: https://example.invalid/image.png") }
            return false
        }
        #expect(preservedDefinition)
    }

}
