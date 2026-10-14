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

    @Test func shiftEnterWritesANewLineInNoteAndEnterDoesNothingYet() async throws {
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

    private func returnKey(shift: Bool) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: shift ? .shift : [],
                                      timestamp: ProcessInfo.processInfo.systemUptime,
                                      windowNumber: NSApp.keyWindow?.windowNumber ?? 0, context: nil,
                                      characters: "\r", charactersIgnoringModifiers: "\r",
                                      isARepeat: false, keyCode: 36))
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
        let interaction = MacInteraction(search: Search(source: { feed.stream() }, debounce: .zero))
        let invocation = interaction.presentBar()
        try await eventually { NSApp.keyWindow?.firstResponder is NSTextView }
        let editor = try #require(NSApp.keyWindow?.firstResponder as? NSTextView)
        return (interaction, invocation, editor)
    }
}
