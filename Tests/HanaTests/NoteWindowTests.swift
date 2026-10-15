import AppKit
import Testing
@testable import Hana

@Suite(.serialized, .nativeWindowSlot, .timeLimit(.minutes(1)))
@MainActor
struct NoteWindowTests {
    @Test func oneNativeWindowKeepsTextKitTwoUndoCompositionAndNewlines() async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        let note = try await store.perform(.createNote(operation: UUID(), body: "Original"), in: store.generation)
        let interaction = MacInteraction(collection: Task { store })
        defer { interaction.window(for: .note(note.id))?.close(); interaction.stop() }
        _ = interaction.open(.main)
        #expect(interaction.open(.note(note.id)))
        try await eventually { interaction.window(for: .note(note.id))?.firstResponder is NSTextView }
        let window = try #require(interaction.window(for: .note(note.id)))
        let editor = try #require(window.firstResponder as? NSTextView)
        #expect(editor.textLayoutManager != nil)
        #expect(NSApp.activationPolicy() == .regular)
        #expect(interaction.open(.note(note.id)))
        #expect(interaction.window(for: .note(note.id)) === window)
        #expect(window.firstResponder === editor)
        editor.selectAll(nil)
        let body = "# ไทย e\u{301} -- 'quote' **bold**"
        editor.insertText(body, replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.breakUndoCoalescing()
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        editor.breakUndoCoalescing()
        #expect(editor.string == body + "\n")
        editor.undoManager?.undo()
        #expect(editor.string == "Original")
        editor.undoManager?.redo()
        #expect(editor.string == body + "\n")
        editor.setMarkedText("ไท", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText())
        #expect(interaction.noteSession(note.id)?.isComposing == true)
        editor.insertText("ไทย", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!editor.hasMarkedText())
        try withPasteboardString("\n- [ ] pasted") { editor.paste(nil) }
        let expected = body + "\nไทย\n- [ ] pasted"
        #expect(editor.string == expected)
        try await interaction.noteSession(note.id)?.flush()
        #expect(try await store.read(.note(note.id), in: store.generation)?.body == expected)
        await store.close()
    }

    @Test func aOneMegabyteFixtureCanOpenEditAndFlush() async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        let body = String(repeating: "# Markdown ไทย\n- [ ] A line with **bold** and e\u{301}.\n", count: 20_000)
        #expect(body.utf8.count >= 1_000_000)
        let note = try await store.perform(.createNote(operation: UUID(), body: body), in: store.generation)
        let interaction = MacInteraction(collection: Task { store })
        defer { interaction.window(for: .note(note.id))?.close(); interaction.stop() }
        let clock = ContinuousClock()
        let openStart = clock.now
        _ = interaction.open(.main)
        _ = interaction.open(.note(note.id))
        try await eventually { interaction.window(for: .note(note.id))?.firstResponder is NSTextView }
        let opened = openStart.duration(to: clock.now)
        let window = try #require(interaction.window(for: .note(note.id)))
        let editor = try #require(window.firstResponder as? NSTextView)
        editor.setSelectedRange(NSRange(location: editor.string.utf16.count, length: 0))
        let editStart = clock.now
        editor.insertText("End", replacementRange: NSRange(location: NSNotFound, length: 0))
        let edited = editStart.duration(to: clock.now)
        let flushStart = clock.now
        try await interaction.noteSession(note.id)?.flush()
        let flushed = flushStart.duration(to: clock.now)
        #expect(interaction.noteSession(note.id)?.committed.body.hasSuffix("End") == true)
        print("NOTE_PROFILE bytes=\(body.utf8.count) open=\(opened) insert=\(edited) flush=\(flushed)")
        await store.close()
    }
}

@MainActor
private func withPasteboardString(_ text: String, body: () -> Void) throws {
    let pasteboard = NSPasteboard.general
    let previous = pasteboard.pasteboardItems?.map { item -> [(NSPasteboard.PasteboardType, Data)] in
        item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
    } ?? []
    defer {
        pasteboard.clearContents()
        let items = previous.map { values in
            let item = NSPasteboardItem()
            for (type, data) in values { item.setData(data, forType: type) }
            return item
        }
        pasteboard.writeObjects(items)
    }
    pasteboard.clearContents()
    pasteboard.setString(text, forType: .string)
    body()
}
