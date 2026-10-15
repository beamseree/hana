import AppKit

/// A native read-only surface. It accepts value blocks, never HTML, images or
/// source URLs to load. Only an explicit native link click calls the opener.
@MainActor
final class MarkdownPreviewSurface: NSObject, NSTextViewDelegate {
    let scroll = NSScrollView()
    let reader = NSTextView(frame: NSRect(x: 0, y: 0, width: 660, height: 480))
    private let openLink: @MainActor (URL) -> Bool
    private var rendered: MarkdownPreviewDocument?

    init(openLink: @escaping @MainActor (URL) -> Bool) {
        self.openLink = openLink
        super.init()
        scroll.hasVerticalScroller = true
        scroll.borderType = .noBorder
        scroll.isHidden = true
        reader.isEditable = false
        reader.isSelectable = true
        reader.isRichText = true
        reader.importsGraphics = false
        reader.allowsUndo = false
        reader.isAutomaticLinkDetectionEnabled = false
        reader.isVerticallyResizable = true
        reader.isHorizontallyResizable = false
        reader.autoresizingMask = [.width]
        reader.textContainer?.widthTracksTextView = true
        reader.textContainer?.containerSize = NSSize(width: 660, height: CGFloat.greatestFiniteMagnitude)
        reader.textContainerInset = NSSize(width: 20, height: 20)
        reader.font = HanaFont.Note.body.nsFont
        reader.textColor = HanaColor.Text.primary
        reader.backgroundColor = HanaColor.Surface.window
        reader.linkTextAttributes = [.foregroundColor: HanaColor.Text.primary, .underlineStyle: NSUnderlineStyle.single.rawValue]
        reader.identifier = NSUserInterfaceItemIdentifier("markdown-preview")
        reader.setAccessibilityLabel("Markdown preview")
        reader.delegate = self
        scroll.documentView = reader
    }

    func show(_ document: MarkdownPreviewDocument?, isParsing: Bool) {
        guard rendered != document || document == nil else { return }
        rendered = document
        if let document { reader.textStorage?.setAttributedString(NativeMarkdownRenderer.render(document)) }
        else { reader.textStorage?.setAttributedString(NSAttributedString(string: isParsing ? "Rendering preview…" : "", attributes: HanaFont.detail.attributes(color: HanaColor.Text.secondary))) }
    }

    func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
        guard let url = link as? URL ?? (link as? String).flatMap(URL.init(string:)) else { return true }
        _ = openLink(url)
        return true // Suppress a second default AppKit open, even when refused.
    }
}

@MainActor
private enum NativeMarkdownRenderer {
    struct Style {
        var role = HanaFont.Note.body
        var overrideFont: NSFont?
        var font: NSFont {
            get { overrideFont ?? role.nsFont }
            set { overrideFont = newValue }
        }
        var color = HanaColor.Text.primary
        var indent: CGFloat = 0
        var link: URL?
        var code = false
    }

    static func render(_ document: MarkdownPreviewDocument) -> NSAttributedString {
        let output = NSMutableAttributedString()
        blocks(document.blocks, style: Style(), output: output)
        return output
    }

    private static func append(_ text: String, style: Style, output: NSMutableAttributedString) {
        let paragraph = style.role.wrappedParagraphStyle
        paragraph.firstLineHeadIndent = style.indent
        paragraph.headIndent = style.indent
        paragraph.paragraphSpacing = 6
        var attributes: [NSAttributedString.Key: Any] = [.font: style.font, .kern: style.role.kern, .foregroundColor: style.color, .paragraphStyle: paragraph]
        if style.code { attributes[.backgroundColor] = HanaColor.Control.fill }
        if let link = style.link { attributes[.link] = link }
        output.append(NSAttributedString(string: text, attributes: attributes))
    }

    private static func blocks(_ blocks: [MarkdownPreviewBlock], style: Style, output: NSMutableAttributedString) {
        for block in blocks {
            switch block {
            case .heading(let level, let children):
                var heading = style
                heading.role = level == 1 ? HanaFont.Heading.window : HanaFont.Note.previewHeading
                inlines(children, style: heading, output: output)
                append("\n", style: heading, output: output)
            case .paragraph(let children):
                inlines(children, style: style, output: output)
                append("\n", style: style, output: output)
            case .literal(let text):
                append(text, style: style, output: output)
                append("\n", style: style, output: output)
            case .code(let text):
                var code = style
                code.role = HanaFont.Note.code
                code.overrideFont = nil
                code.code = true
                append(text, style: code, output: output)
                append("\n", style: style, output: output)
            case .quote(let children):
                var quote = style
                quote.indent += 18
                quote.color = HanaColor.Text.secondary
                self.blocks(children, style: quote, output: output)
            case .list(let start, let items):
                for (index, item) in items.enumerated() {
                    var nested = style
                    nested.indent += 18
                    let marker = start.map { "\($0 + index). " } ?? "• "
                    append(marker, style: nested, output: output)
                    self.blocks(item, style: nested, output: output)
                }
            }
        }
    }

    private static func inlines(_ children: [MarkdownPreviewInline], style: Style, output: NSMutableAttributedString) {
        for child in children {
            switch child {
            case .text(let text), .literal(let text): append(text, style: style, output: output)
            case .code(let text):
                var code = style
                code.role = HanaFont.Note.code
                code.overrideFont = nil
                code.code = true
                append(text, style: code, output: output)
            case .emphasis(let nested):
                var emphasis = style
                emphasis.font = NSFontManager.shared.convert(style.font, toHaveTrait: .italicFontMask)
                inlines(nested, style: emphasis, output: output)
            case .strong(let nested):
                var strong = style
                strong.font = NSFont.systemFont(ofSize: style.font.pointSize, weight: .medium)
                if NSFontManager.shared.traits(of: style.font).contains(.italicFontMask) {
                    strong.font = NSFontManager.shared.convert(strong.font, toHaveTrait: .italicFontMask)
                }
                inlines(nested, style: strong, output: output)
            case .link(let destination, let nested):
                var link = style
                link.link = URL(string: destination)
                inlines(nested, style: link, output: output)
            case .lineBreak: append("\n", style: style, output: output)
            }
        }
    }
}
