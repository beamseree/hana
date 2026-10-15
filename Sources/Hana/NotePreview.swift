import Foundation
import Markdown

/// Immutable values cross the parser boundary; the Markdown AST never does.
struct MarkdownPreviewDocument: Equatable, Sendable {
    let blocks: [MarkdownPreviewBlock]
}

indirect enum MarkdownPreviewBlock: Equatable, Sendable {
    case heading(Int, [MarkdownPreviewInline])
    case paragraph([MarkdownPreviewInline])
    case quote([MarkdownPreviewBlock])
    case list(start: Int?, items: [[MarkdownPreviewBlock]])
    case code(String)
    case literal(String)
}

indirect enum MarkdownPreviewInline: Equatable, Sendable {
    case text(String), literal(String), code(String)
    case emphasis([MarkdownPreviewInline]), strong([MarkdownPreviewInline])
    case link(String, [MarkdownPreviewInline])
    case lineBreak
}

enum MarkdownPreview {
    /// Parsing and AST traversal are CPU work explicitly kept off the UI actor.
    @concurrent static func parse(_ text: String) async -> MarkdownPreviewDocument {
        let document = Document(parsing: text, options: [.disableSmartOpts])
        let source = PreviewSource(text)
        do {
            var blocks: [MarkdownPreviewBlock] = []
            var end = 0
            for child in document.children {
                let range = try source.byteRange(child)
                if range.lowerBound > end, let gap = source.string(end..<range.lowerBound), Note.isNonblank(gap) {
                    blocks.append(.literal(gap))
                }
                blocks.append(try block(child, source: source))
                end = range.upperBound
            }
            if end < source.bytes.count, let gap = source.string(end..<source.bytes.count), Note.isNonblank(gap) {
                blocks.append(.literal(gap))
            }
            return MarkdownPreviewDocument(blocks: blocks)
        } catch {
            // An uncertain source range must never silently lose syntax.
            return MarkdownPreviewDocument(blocks: [.literal(text)])
        }
    }

    private static func block(_ node: any Markup, source: PreviewSource) throws -> MarkdownPreviewBlock {
        do {
            switch node {
            case let heading as Heading: return .heading(heading.level, try inlines(heading, source: source))
            case let paragraph as Paragraph:
                let children = Array(paragraph.children)
                if let first = children.first, let last = children.last,
                   let firstRange = try? source.byteRange(first), let lastRange = try? source.byteRange(last) {
                    let range = try source.byteRange(paragraph)
                    guard firstRange.lowerBound >= range.lowerBound, lastRange.upperBound <= range.upperBound else {
                        return .literal(try source.literal(paragraph))
                    }
                    let leading = source.string(range.lowerBound..<firstRange.lowerBound) ?? ""
                    let trailing = source.string(lastRange.upperBound..<range.upperBound) ?? ""
                    // Cmark can absorb reference definitions into a paragraph's
                    // range without exposing nodes for them. Keep that source.
                    if Note.isNonblank(leading) || Note.isNonblank(trailing) {
                        return .literal(try source.literal(paragraph))
                    }
                }
                return .paragraph(try inlines(paragraph, source: source))
            case let quote as BlockQuote: return .quote(try quote.children.map { try block($0, source: source) })
            case let code as CodeBlock: return .code(code.code)
            case let list as UnorderedList:
                guard !list.children.contains(where: { ($0 as? ListItem)?.checkbox != nil }) else {
                    return .literal(try source.literal(node))
                }
                return .list(start: nil, items: try list.children.map { item in
                    try item.children.map { try block($0, source: source) }
                })
            case let list as OrderedList:
                guard !list.children.contains(where: { ($0 as? ListItem)?.checkbox != nil }) else {
                    return .literal(try source.literal(node))
                }
                return .list(start: Int(list.startIndex), items: try list.children.map { item in
                    try item.children.map { try block($0, source: source) }
                })
            default: return .literal(try source.literal(node))
            }
        } catch {
            // If an unsupported inline has an invalid range, preserve its whole
            // containing block. If that range is bad too, the root stays literal.
            return .literal(try source.literal(node))
        }
    }

    private static func inlines(_ node: any Markup, source: PreviewSource) throws -> [MarkdownPreviewInline] {
        try node.children.map { child in
            switch child {
            case let text as Markdown.Text: return .text(text.string)
            case let emphasis as Emphasis: return .emphasis(try inlines(emphasis, source: source))
            case let strong as Strong: return .strong(try inlines(strong, source: source))
            case let code as InlineCode: return .code(code.code)
            case let link as Markdown.Link:
                guard let destination = link.destination else { return .literal(try source.literal(child)) }
                return .link(destination, try inlines(link, source: source))
            case is SoftBreak: return .text(" ")
            case is LineBreak: return .lineBreak
            default: return .literal(try source.literal(child))
            }
        }
    }
}

/// Swift Markdown source columns count UTF-8 bytes, not Characters or UTF-16.
/// Keep the original line endings, including CRLF and CR, for literal slices.
private struct PreviewSource {
    let bytes: [UInt8]
    let lineStarts: [Int]
    let lineEnds: [Int]
    enum InvalidRange: Error { case unavailable }

    init(_ text: String) {
        bytes = Array(text.utf8)
        var starts = [0], ends: [Int] = []
        var offset = 0
        while offset < bytes.count {
            if bytes[offset] == 10 || bytes[offset] == 13 {
                ends.append(offset)
                if bytes[offset] == 13, offset + 1 < bytes.count, bytes[offset + 1] == 10 { offset += 1 }
                starts.append(offset + 1)
            }
            offset += 1
        }
        ends.append(bytes.count)
        lineStarts = starts
        lineEnds = ends
    }

    func byteRange(_ node: any Markup) throws -> Range<Int> {
        guard let range = node.range,
              let start = offset(range.lowerBound), let end = offset(range.upperBound), start <= end else {
            throw InvalidRange.unavailable
        }
        return start..<end
    }

    func literal(_ node: any Markup) throws -> String {
        guard let value = string(try byteRange(node)) else { throw InvalidRange.unavailable }
        return value
    }

    func string(_ range: Range<Int>) -> String? {
        guard range.lowerBound >= 0, range.upperBound <= bytes.count else { return nil }
        return String(bytes: bytes[range], encoding: .utf8)
    }

    private func offset(_ location: SourceLocation) -> Int? {
        guard location.line > 0, location.line <= lineStarts.count, location.column > 0 else { return nil }
        let result = lineStarts[location.line - 1] + location.column - 1
        guard result <= lineEnds[location.line - 1] else { return nil }
        return result
    }
}

// Parser substitution is one asynchronous value boundary, not a second editor.
typealias MarkdownPreviewParser = @Sendable (String) async -> MarkdownPreviewDocument
