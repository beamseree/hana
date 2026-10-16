import AppKit
import Testing
@testable import Hana

/// Note mode's presentation in the real panel, entered through the New note suggestion.
@Suite(.serialized, .nativeWindowSlot)
@MainActor
struct NoteModeTests {
    private let none = NSRange(location: NSNotFound, length: 0)

    @Test func newNoteShowsTheNoteLabelAndIconAndHidesSearchResults() async throws {
        _ = NSApplication.shared
        let feed = CatalogFeed()
        let interaction = MacInteraction(search: Search(source: { feed.stream() }, typingGap: .zero))
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await firstResponderEditor()
        editor.insertText("milk", replacementRange: none)
        await feed.send([app("Milk", "/fixture/Milk.app")])
        try await eventually { interaction.resultsVisible }
        #expect(interaction.modeLabelText == nil && !interaction.modeIconShowsNote)

        editor.setSelectedRange(NSRange(location: 0, length: 0))
        try enterNoteCaptureForValidation(interaction, editor: editor)
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
        let interaction = MacInteraction(search: Search(source: { CatalogFeed().stream() }, typingGap: .zero))
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await firstResponderEditor()
        let window = try #require(editor.window)
        let collapsed = interaction.contentHeight
        let inputTop = window.frame.maxY
        try enterNoteCaptureForValidation(interaction, editor: editor)
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
        try await eventually { interaction.contentHeight == collapsed + BarStyle.noteMaxTextHeight - BarStyle.editorHeight }
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
        let interaction = MacInteraction(search: Search(source: { CatalogFeed().stream() }, typingGap: .zero))
        let invocation = interaction.presentBar()
        let editor = try await firstResponderEditor()
        let collapsed = interaction.contentHeight
        try enterNoteCaptureForValidation(interaction, editor: editor)
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
        // The Task prefix is armed again.
        editor.insertText("[", replacementRange: none)
        #expect(interaction.mode == .task && editor.string == "")
    }

    @Test func returningFromAMultilineNoteKeepsTheTextAndSearchesItsNormalisedQuery() async throws {
        _ = NSApplication.shared
        let apps = CatalogFeed(), files = CatalogFeed()
        var queries: [String] = []
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, files: { text in
            queries.append(text)
            return files.stream()
        }, typingGap: .zero))
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await firstResponderEditor()
        let window = try #require(editor.window)
        let inputTop = window.frame.maxY
        let text = "  milk\n\tand  eggs\n\nบันทึก \n"
        try enterNoteCaptureForValidation(interaction, editor: editor)
        // Let the setup Search request reach its source before observing Note.
        try await eventually { queries.count == 1 }
        queries.removeAll()
        editor.insertText(text, replacementRange: none)
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        try await eventually { interaction.contentHeight > BarStyle.collapsedHeight }
        #expect(queries.isEmpty)

        editor.keyDown(with: try backspaceKey())
        #expect(interaction.mode == .search)
        #expect(editor.string == text)
        #expect(editor.selectedRange() == NSRange(location: 0, length: 0))
        #expect(interaction.modeLabelText == nil && interaction.modeIconShowsQuery)
        try await eventually { queries == ["milk and eggs บันทึก"] }
        let milk = app("Milk and Eggs บันทึก", "/fixture/Milk.app")
        await apps.send([milk])
        await files.send([])
        try await eventually { interaction.resultsVisible && interaction.results == [milk] }
        #expect(interaction.selectedResult == milk)
        // Every line stays visible above the results, and the input never moved.
        let scroll = try #require(editor.enclosingScrollView)
        #expect(scroll.documentVisibleRect.height >= editor.frame.height)
        #expect(scroll.frame.height > BarStyle.editorHeight)
        #expect(window.frame.maxY == inputTop)
        #expect(window.firstResponder === editor)

        // Nothing about the tall return outlives the invocation.
        interaction.dismiss(invocation, reason: .escape)
        let next = interaction.presentBar()
        defer { interaction.dismiss(next, reason: .outsideClick) }
        #expect(interaction.contentHeight == BarStyle.collapsedHeight)
        #expect(scroll.frame.height == BarStyle.editorHeight)
    }

    private func firstResponderEditor() async throws -> NSTextView {
        try await eventually { NSApp.keyWindow?.firstResponder is NSTextView }
        return try #require(NSApp.keyWindow?.firstResponder as? NSTextView)
    }
}
