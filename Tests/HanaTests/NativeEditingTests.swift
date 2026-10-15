import AppKit
import Testing
@testable import Hana

// Holds the coordinated native testing slot. Uses the real first responder
// and editor commands, never a replacement editor or private view hierarchy.
@Suite(.serialized, .nativeWindowSlot)
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
        // The key window must be this test's bar, not another test's.
        try #require(interaction.query == text)
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

    @Test func theBarsEditorUsesTextKit2() async throws {
        let (interaction, invocation, editor) = try await presentEditor()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        #expect(editor.textLayoutManager != nil)
    }

    @Test func placeholderShowsOnlyInEmptySearchAndHidesWhileComposing() async throws {
        let (interaction, invocation, editor) = try await presentEditor()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let none = NSRange(location: NSNotFound, length: 0)
        #expect(interaction.placeholderText == "Search")

        editor.setMarkedText("ก", selectedRange: NSRange(location: 1, length: 0), replacementRange: none)
        #expect(editor.hasMarkedText())
        #expect(interaction.placeholderText == nil)
        editor.unmarkText()
        editor.selectAll(nil)
        editor.delete(nil)
        #expect(interaction.placeholderText == "Search")

        editor.insertText("milk", replacementRange: none)
        #expect(interaction.placeholderText == nil)
        editor.selectAll(nil)
        editor.delete(nil)
        #expect(interaction.placeholderText == "Search")

        // An empty Note has no placeholder; returning to Search restores it.
        editor.insertText("-", replacementRange: none)
        #expect(interaction.mode == .note && editor.string.isEmpty)
        #expect(interaction.placeholderText == nil)
        editor.keyDown(with: try backspaceKey())
        #expect(interaction.mode == .search)
        #expect(interaction.placeholderText == "Search")
    }

    @Test func typedDashAtTheStartSwitchesToNoteAndKeepsTheText() async throws {
        let (interaction, invocation, editor) = try await presentEditor()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        editor.insertText("milk", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText("-", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(interaction.mode == .note)
        #expect(editor.string == "milk")
        #expect(editor.selectedRange() == NSRange(location: 0, length: 0))
        #expect(editor.window?.firstResponder === editor)
    }

    @Test func pastedDashStaysLiteralInSearch() async throws {
        let (interaction, invocation, editor) = try await presentEditor()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        try withPasteboardString("-hello") { editor.paste(nil) }
        #expect(interaction.mode == .search)
        #expect(editor.string == "-hello")
        #expect(interaction.query == "-hello")
    }

    @Test func undoAndRedoAfterAConsumedPrefixChangeOnlyTheText() async throws {
        let (interaction, invocation, editor) = try await presentEditor()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        editor.insertText("milk", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.breakUndoCoalescing()
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText("-", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(interaction.mode == .note)
        // The consumed prefix left no undo step: the first undo removes the text.
        editor.undoManager?.undo()
        #expect(editor.string == "")
        #expect(interaction.mode == .note)
        editor.undoManager?.redo()
        #expect(editor.string == "milk")
        #expect(interaction.mode == .note)
        #expect(editor.undoManager?.canRedo == false)
    }

    @Test(arguments: ["-", "a-", "-a"])
    func compositionContainingADashNeverSwitchesModes(composed: String) async throws {
        let (interaction, invocation, editor) = try await presentEditor()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let none = NSRange(location: NSNotFound, length: 0)
        for end in 1...composed.utf16.count {
            let marked = String(composed.utf16.prefix(end))!
            editor.setMarkedText(marked, selectedRange: NSRange(location: end, length: 0), replacementRange: none)
            #expect(interaction.mode == .search)
        }
        editor.insertText(composed, replacementRange: none)
        #expect(!editor.hasMarkedText())
        #expect(interaction.mode == .search)
        #expect(editor.string == composed)
    }

    @Test func thaiTextSurvivesTheSwitchToNote() async throws {
        let (interaction, invocation, editor) = try await presentEditor()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let none = NSRange(location: NSNotFound, length: 0)
        editor.insertText("บันทึก", replacementRange: none)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText("-", replacementRange: none)
        #expect(interaction.mode == .note)
        #expect(editor.string == "บันทึก")
        editor.setSelectedRange(NSRange(location: ("บันทึก" as NSString).length, length: 0))
        editor.insertText("ไทย", replacementRange: none)
        #expect(editor.string == "บันทึกไทย")
    }

    @Test func shiftEnterWritesANewLineInNoteAndEnterWithoutACollectionKeepsIt() async throws {
        let (interaction, invocation, editor) = try await presentEditor()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let none = NSRange(location: NSNotFound, length: 0)
        editor.insertText("-", replacementRange: none)
        editor.insertText("one", replacementRange: none)
        editor.keyDown(with: try returnKey(shift: true))
        editor.insertText("two", replacementRange: none)
        editor.keyDown(with: try returnKey(shift: false))
        #expect(interaction.mode == .note)
        #expect(editor.string == "one\ntwo")
        #expect(interaction.currentInvocation == invocation)
    }

    @Test func noteKeepsMarkdownPunctuationAsTyped() async throws {
        let (interaction, invocation, editor) = try await presentEditor()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        editor.insertText("-", replacementRange: NSRange(location: NSNotFound, length: 0))
        let markdown = "\"quote\" -- 'it's' ... (c) 1/2 -> *a*"
        for character in markdown {
            editor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        #expect(editor.string == markdown)
    }

    @Test func backspaceAtTheStartOfNoteReturnsToSearchAndATypedDashStaysLiteral() async throws {
        let (interaction, invocation, editor) = try await presentEditor()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let none = NSRange(location: NSNotFound, length: 0)
        editor.insertText("-", replacementRange: none)
        editor.insertText("milk", replacementRange: none)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.keyDown(with: try backspaceKey())
        #expect(interaction.mode == .search)
        #expect(editor.string == "milk")
        #expect(editor.selectedRange() == NSRange(location: 0, length: 0))
        #expect(interaction.modeLabelText == nil)
        #expect(editor.window?.firstResponder === editor)

        editor.insertText("-", replacementRange: none)
        #expect(interaction.mode == .search)
        #expect(editor.string == "-milk")
        #expect(interaction.query == "-milk")
    }

    @Test func backspaceAfterTheStartOfNoteDeletesNormally() async throws {
        let (interaction, invocation, editor) = try await presentEditor()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let none = NSRange(location: NSNotFound, length: 0)
        editor.insertText("-", replacementRange: none)
        editor.insertText("milk", replacementRange: none)
        editor.keyDown(with: try backspaceKey())
        #expect(interaction.mode == .note)
        #expect(editor.string == "mil")
        editor.setSelectedRange(NSRange(location: 0, length: 2))
        editor.keyDown(with: try backspaceKey())
        #expect(interaction.mode == .note)
        #expect(editor.string == "l")
    }

    @Test func undoAfterReturningToSearchChangesOnlyTheText() async throws {
        let (interaction, invocation, editor) = try await presentEditor()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let none = NSRange(location: NSNotFound, length: 0)
        editor.insertText("-", replacementRange: none)
        editor.insertText("milk", replacementRange: none)
        editor.breakUndoCoalescing()
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.keyDown(with: try backspaceKey())
        #expect(interaction.mode == .search)
        // Returning was not an edit: the first undo removes the text.
        editor.undoManager?.undo()
        #expect(editor.string == "")
        #expect(interaction.mode == .search)
        editor.undoManager?.redo()
        #expect(editor.string == "milk")
        #expect(interaction.mode == .search)
        #expect(interaction.query == "milk")
    }

    /// A real paste reads the general pasteboard; put back what was there.
    private func withPasteboardString(_ string: String, _ body: () -> Void) throws {
        let pasteboard = NSPasteboard.general
        let saved = (pasteboard.pasteboardItems ?? []).map { item in
            let copy = NSPasteboardItem()
            for type in item.types { if let data = item.data(forType: type) { copy.setData(data, forType: type) } }
            return copy
        }
        defer {
            pasteboard.clearContents()
            pasteboard.writeObjects(saved)
        }
        pasteboard.clearContents()
        try #require(pasteboard.setString(string, forType: .string))
        body()
    }

    private func presentEditor() async throws -> (MacInteraction, MacInteraction.Invocation, NSTextView) {
        _ = NSApplication.shared
        let feed = CatalogFeed()
        let interaction = MacInteraction(search: Search(source: { feed.stream() }, typingGap: .zero))
        let invocation = interaction.presentBar()
        try await eventually { NSApp.keyWindow?.firstResponder is NSTextView }
        let editor = try #require(NSApp.keyWindow?.firstResponder as? NSTextView)
        return (interaction, invocation, editor)
    }
}
