import AppKit
import Testing
@testable import Hana

@Suite(.serialized, .nativeWindowSlot)
@MainActor
struct NotePreviewTests {
    @Test func staleParsesCannotReplaceNewTextOrAReopenedPreview() async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        let note = try await store.perform(.createNote(operation: UUID(), body: "Old"), in: store.generation)
        let parser = DeferredPreviewParser()
        let interaction = MacInteraction(collection: Task { store }, previewParser: { text in await parser.parse(text) })
        defer { interaction.window(for: .note(note.id))?.close(); interaction.stop() }
        interaction.open(.main)
        interaction.open(.note(note.id))
        try await eventually { interaction.noteSession(note.id) != nil }
        interaction.toggleNotePreview(note.id)
        try await waitForParses(parser, count: 1)
        interaction.noteSession(note.id)?.edit("New")
        try await waitForParses(parser, count: 2)
        await parser.complete(1, text: "New preview")
        try await eventually { interaction.notePreview(note.id)?.document?.blocks == [.paragraph([.text("New preview")])] }
        await parser.complete(0, text: "Old preview")
        try await Task.sleep(for: .milliseconds(20))
        #expect(interaction.notePreview(note.id)?.document?.blocks == [.paragraph([.text("New preview")])])
        interaction.toggleNotePreview(note.id)
        #expect(interaction.notePreview(note.id)?.isVisible == false)
        interaction.toggleNotePreview(note.id)
        try await waitForParses(parser, count: 3)
        interaction.toggleNotePreview(note.id)
        interaction.toggleNotePreview(note.id)
        try await waitForParses(parser, count: 4)
        await parser.complete(3, text: "Latest visibility")
        try await eventually { interaction.notePreview(note.id)?.document?.blocks == [.paragraph([.text("Latest visibility")])] }
        await parser.complete(2, text: "Hidden session preview")
        try await Task.sleep(for: .milliseconds(20))
        #expect(interaction.notePreview(note.id)?.document?.blocks == [.paragraph([.text("Latest visibility")])])
        try await interaction.noteSession(note.id)?.flush()
        await store.close()
    }
    @Test func nativeToggleKeepsSavedBytesAndLinksOpenOnlyOnExplicitClick() async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        let source = "# ไทย🌸\r\n\r\nA **strong** [website](https://example.com).\r\n\r\n![remote](https://example.invalid/image.png)\r\n\r\n<div>literal</div>"
        let note = try await store.perform(.createNote(operation: UUID(), body: source), in: store.generation)
        var opened: [URL] = []
        let interaction = MacInteraction(collection: Task { store }, openPreviewLink: { url in opened.append(url); return true })
        defer { interaction.window(for: .note(note.id))?.close(); interaction.stop() }
        interaction.open(.main)
        interaction.open(.note(note.id))
        try await eventually { interaction.window(for: .note(note.id))?.firstResponder is NSTextView }
        let window = try #require(interaction.window(for: .note(note.id)))
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.setSelectedRange(NSRange(location: 3, length: 0))
        interaction.toggleNotePreview(note.id)
        try await eventually { interaction.notePreview(note.id)?.document != nil && interaction.notePreview(note.id)?.isParsing == false }
        let reader = try #require(previewReader(in: window.contentView))
        try await eventually { window.firstResponder === reader && reader.string.contains("website") }
        #expect(!reader.isEditable && reader.isSelectable)
        #expect(reader.string.contains("![remote](https://example.invalid/image.png)"))
        #expect(reader.string.contains("<div>literal</div>"))
        #expect(opened.isEmpty)
        let url = try #require(URL(string: "https://example.com"))
        let range = (reader.string as NSString).range(of: "website")
        try #require(range.location != NSNotFound)
        #expect(reader.textStorage?.attribute(.link, at: range.location, effectiveRange: nil) as? URL == url)
        #expect(reader.delegate?.textView?(reader, clickedOnLink: url, at: range.location) == true)
        #expect(opened == [url])
        interaction.toggleNotePreview(note.id)
        try await eventually { window.firstResponder === editor }
        #expect(editor.string.utf8.elementsEqual(source.utf8))
        #expect(editor.selectedRange() == NSRange(location: 3, length: 0))
        #expect(try await store.read(.note(note.id), in: store.generation) == note)
        await store.close()
    }

}

private actor DeferredPreviewParser {
    private var requests: [CheckedContinuation<MarkdownPreviewDocument, Never>?] = []
    var count: Int { requests.count }
    func parse(_ text: String) async -> MarkdownPreviewDocument {
        await withCheckedContinuation { requests.append($0) }
    }
    func complete(_ index: Int, text: String) {
        requests[index]?.resume(returning: MarkdownPreviewDocument(blocks: [.paragraph([.text(text)])]))
        requests[index] = nil
    }
}

private func waitForParses(_ parser: DeferredPreviewParser, count: Int) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while await parser.count < count, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(await parser.count >= count)
}

@MainActor
private func previewReader(in view: NSView?) -> NSTextView? {
    guard let view else { return nil }
    if let reader = view as? NSTextView, reader.identifier?.rawValue == "markdown-preview" { return reader }
    for child in view.subviews { if let reader = previewReader(in: child) { return reader } }
    return nil
}
