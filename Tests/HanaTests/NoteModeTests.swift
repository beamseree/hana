import AppKit
import Testing
@testable import Hana

/// Note mode's presentation in the real panel, entered through the real editor.
@Suite(.serialized)
@MainActor
struct NoteModeTests {
    private let none = NSRange(location: NSNotFound, length: 0)

    @Test func typedPrefixShowsTheNoteLabelAndIconAndHidesSearchResults() async throws {
        _ = NSApplication.shared
        let feed = CatalogFeed()
        let interaction = MacInteraction(search: Search(source: { feed.stream() }, debounce: .zero))
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await firstResponderEditor()
        editor.insertText("milk", replacementRange: none)
        await feed.send([app("Milk", "/fixture/Milk.app")])
        try await eventually { interaction.resultsVisible }
        #expect(interaction.modeLabelText == nil && !interaction.modeIconShowsNote)

        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText("-", replacementRange: none)
        #expect(interaction.modeLabelText == "Note")
        #expect(interaction.modeIconShowsNote)
        #expect(!interaction.resultsVisible && interaction.results.isEmpty)
        #expect(interaction.statusMessage == nil && !interaction.isLoading)
        // A late batch for the abandoned query cannot bring results back.
        await feed.send([app("Milk", "/fixture/Milk.app")])
        try await Task.sleep(for: .milliseconds(50))
        #expect(!interaction.resultsVisible && interaction.results.isEmpty)
        #expect(editor.string == "milk")
    }

    @Test func noteGrowsDownwardToAMaximumHeightAndThenScrolls() async throws {
        _ = NSApplication.shared
        let interaction = MacInteraction(search: Search(source: { CatalogFeed().stream() }, debounce: .zero))
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await firstResponderEditor()
        let window = try #require(editor.window)
        let collapsed = interaction.contentHeight
        let inputTop = window.frame.maxY
        editor.insertText("-", replacementRange: none)
        editor.insertText("one", replacementRange: none)
        #expect(interaction.contentHeight == collapsed)

        // The new, still empty line already has room for the insertion point.
        editor.insertText("\n", replacementRange: none)
        try await eventually { interaction.contentHeight > collapsed }
        let twoLines = interaction.contentHeight
        editor.insertText("two", replacementRange: none)
        #expect(interaction.contentHeight == twoLines)
        #expect(window.frame.maxY == inputTop)

        for line in 3...30 { editor.insertText("\n\(line)", replacementRange: none) }
        try await eventually { interaction.contentHeight == collapsed + BarStyle.noteMaxTextHeight - 40 }
        #expect(twoLines < interaction.contentHeight)
        #expect(window.frame.maxY == inputTop)
        let scroll = try #require(editor.enclosingScrollView)
        #expect(scroll.documentVisibleRect.height < editor.frame.height)
        // The insertion point at the end stays in view.
        #expect(scroll.documentVisibleRect.maxY >= editor.frame.height - 1)
        #expect(window.firstResponder === editor)
    }

    @Test(arguments: [MacInteraction.DismissalReason.escape, .outsideClick])
    func dismissingNoteDiscardsItAndTheNextInvocationOpensAnEmptySearch(reason: MacInteraction.DismissalReason) async throws {
        _ = NSApplication.shared
        let interaction = MacInteraction(search: Search(source: { CatalogFeed().stream() }, debounce: .zero))
        let invocation = interaction.presentBar()
        let editor = try await firstResponderEditor()
        let collapsed = interaction.contentHeight
        editor.insertText("-", replacementRange: none)
        editor.insertText("unsaved\nthought", replacementRange: none)
        try await eventually { interaction.contentHeight > collapsed }
        if reason == .escape {
            editor.keyDown(with: try #require(NSEvent.keyEvent(
                with: .keyDown, location: .zero, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: editor.window?.windowNumber ?? 0, context: nil, characters: "\u{1b}",
                charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53)))
        } else {
            interaction.dismiss(invocation, reason: reason)
        }
        #expect(interaction.currentInvocation == nil)

        let next = interaction.presentBar()
        defer { interaction.dismiss(next, reason: .outsideClick) }
        #expect(next != invocation)
        #expect(interaction.mode == .search)
        #expect(interaction.query == "")
        #expect(interaction.modeLabelText == nil && !interaction.modeIconShowsNote && !interaction.modeIconShowsQuery)
        #expect(interaction.contentHeight == collapsed)
        #expect(editor.undoManager?.canUndo == false)
        // Prefixes are armed again.
        editor.insertText("-", replacementRange: none)
        #expect(interaction.mode == .note && editor.string == "")
    }

    private func firstResponderEditor() async throws -> NSTextView {
        try await eventually { NSApp.keyWindow?.firstResponder is NSTextView }
        return try #require(NSApp.keyWindow?.firstResponder as? NSTextView)
    }
}
