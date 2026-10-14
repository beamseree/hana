import AppKit
import Testing
@testable import Hana

// Requires the coordinated native testing slot. Uses the real first responder
// and editor commands, never a replacement editor or private view hierarchy.
@Suite(.serialized)
@MainActor
struct NativeEditingTests {
    @Test func lateResultsPreserveEditorSelectionUndoAndInputPosition() async throws {
        _ = NSApplication.shared
        let feed = CatalogFeed()
        let interaction = MacInteraction(search: Search(source: { feed.stream() }, typingGap: .zero))
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        try await eventually { NSApp.keyWindow?.firstResponder is NSTextView }
        let window = try #require(NSApp.keyWindow)
        let editor = try #require(window.firstResponder as? NSTextView)
        let text = "- [ 'hello' *? บันทึก"
        editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.breakUndoCoalescing()
        editor.setSelectedRange(NSRange(location: 5, length: 5))
        let inputTop = window.frame.maxY
        let responder = window.firstResponder
        await feed.send((1...12).map { app("\(text) \($0)", "/fixture/\($0).app") })
        try await eventually { interaction.results.count == 12 }
        #expect(window.firstResponder === responder)
        #expect(editor.string == text)
        #expect(editor.selectedRange() == NSRange(location: 5, length: 5))
        #expect(window.frame.maxY == inputTop)
        #expect(interaction.presentBar() == invocation)
        #expect(editor.selectedRange() == NSRange(location: 5, length: 5))
        editor.insertText("ไทย", replacementRange: editor.selectedRange())
        editor.breakUndoCoalescing()
        let edited = editor.string
        editor.undoManager?.undo()
        #expect(editor.string == text)
        editor.undoManager?.redo()
        #expect(editor.string == edited)
        #expect(window.firstResponder === responder)
    }
}
