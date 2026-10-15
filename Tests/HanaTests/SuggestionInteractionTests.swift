import AppKit
import Testing
@testable import Hana

/// New note and New task suggestions in the real panel, with fixture sources.
@Suite(.serialized, .nativeWindowSlot)
@MainActor
struct SuggestionInteractionTests {
    private let suggestions: [SearchRow] = [.suggestion(.note), .suggestion(.task)]

    @Test func suggestionsFollowEveryMatchIncludingLateFileBatchesAndAreAbsentForEmptyText() async throws {
        _ = NSApplication.shared
        let apps = CatalogFeed(), files = CatalogFeed()
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, files: { _ in files.stream() }, typingGap: .zero))
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        #expect(interaction.rows.isEmpty)
        let notes = app("Notes", "/fixture/Notes.app")
        let file = SearchResult(name: "Notes draft", url: URL(fileURLWithPath: "/fixture/Notes draft.txt"), kind: .file)
        interaction.updateQuery("Notes")
        #expect(interaction.rows == suggestions)
        await apps.send([notes])
        try await eventually { interaction.results == [notes] }
        #expect(interaction.rows == [.result(notes)] + suggestions)
        await files.send([file])
        try await eventually { interaction.results == [notes, file] }
        #expect(interaction.rows == [.result(notes), .result(file)] + suggestions)
        #expect(interaction.selectedResult?.id == notes.id)
        interaction.updateQuery("")
        #expect(interaction.rows.isEmpty && interaction.selectedRow == nil)
        interaction.updateQuery("   ")
        #expect(interaction.rows.isEmpty && interaction.selectedRow == nil)
    }

    @Test func withNoMatchesTheFirstSuggestionIsSelected() async throws {
        _ = NSApplication.shared
        let apps = CatalogFeed(), files = CatalogFeed()
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, files: { _ in files.stream() }, typingGap: .zero))
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        interaction.updateQuery("buy milk")
        #expect(interaction.selectedRow == .suggestion(.note))
        await apps.send([]); await files.send([])
        try await eventually { !interaction.isLoading }
        #expect(interaction.rows == suggestions)
        #expect(interaction.selectedRow == .suggestion(.note))
        #expect(interaction.selectedResult == nil)
    }

    @Test(arguments: [CaptureSession.Suggestion.note, .task])
    func enterOnASuggestionSwitchesModeWithTheExactTextAndSelectionAndSavesOnlyOnTheNextEnter(
        suggestion: CaptureSession.Suggestion
    ) async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        let apps = CatalogFeed()
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, typingGap: .zero),
                                         collection: Task { store }, confirmationDuration: .zero)
        let invocation = interaction.presentBar()
        let editor = try await firstResponderEditor()
        let text = "buy milk บ้าน"
        editor.insertText(text, replacementRange: none)
        await apps.send([])
        try await eventually { !interaction.isLoading }
        if suggestion == .task { interaction.moveSelection(by: 1) }
        #expect(interaction.selectedRow == .suggestion(suggestion))
        let selection = NSRange(location: 4, length: 4)
        editor.setSelectedRange(selection)
        editor.keyDown(with: try returnKey())

        #expect(interaction.mode == suggestion.mode)
        #expect(interaction.modeLabelText == (suggestion == .note ? "Note" : "Task"))
        #expect(editor.string == text && editor.selectedRange() == selection)
        #expect(!interaction.resultsVisible && interaction.rows.isEmpty)
        try await Task.sleep(for: .milliseconds(50))
        #expect(interaction.currentInvocation == invocation)
        let records = try await store.read(.allRecords, in: store.generation)
        #expect(records.notes.isEmpty && records.tasks.isEmpty)

        editor.keyDown(with: try returnKey())
        try await eventually { interaction.currentInvocation == nil }
        if suggestion == .note {
            #expect(try await store.read(.notes, in: store.generation).map(\.body) == [text])
        } else {
            #expect(try await store.read(.tasks(in: .inbox), in: store.generation).map(\.title) == [text])
        }
        await store.close()
    }

    @Test(arguments: [true, false])
    func anUnnavigatedEnterOnASuggestionWhileLoadingWaitsSoALateMatchIsNotSkipped(lateMatch: Bool) async throws {
        _ = NSApplication.shared
        let apps = CatalogFeed(), files = CatalogFeed()
        var opened: [URL] = []
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, files: { _ in files.stream() }, typingGap: .zero),
            launchApplication: { url in opened.append(url); return .init(activate: { true }) })
        let invocation = interaction.presentBar()
        defer { if let current = interaction.currentInvocation { interaction.dismiss(current, reason: .outsideClick) } }
        let safari = app("Safari", "/fixture/Safari.app")
        interaction.updateQuery("Safari")
        #expect(interaction.selectedRow == .suggestion(.note))
        #expect(interaction.requestSelectedOpen() == nil)
        #expect(interaction.mode == .search)
        #expect(interaction.statusMessage == "Opening selected destination…")
        // One source finishing empty is not enough: the other may still match.
        await apps.send([])
        try await Task.sleep(for: .milliseconds(20))
        #expect(interaction.mode == .search && interaction.isLoading)
        await files.send(lateMatch ? [SearchResult(name: "Safari", url: URL(fileURLWithPath: "/fixture/Safari.app"))] : [])
        if lateMatch {
            try await eventually { interaction.currentInvocation == nil }
            #expect(opened == [safari.url])
        } else {
            try await eventually { interaction.mode == .note }
            #expect(interaction.query == "Safari" && opened.isEmpty)
            #expect(interaction.currentInvocation == invocation)
        }
    }

    @Test func enterOnANavigatedSuggestionChoosesItAtOnceWhileLoading() async throws {
        _ = NSApplication.shared
        let apps = CatalogFeed()
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, typingGap: .zero))
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        interaction.updateQuery("call mum")
        #expect(interaction.isLoading)
        interaction.moveSelection(by: 1)
        #expect(interaction.selectedRow == .suggestion(.task))
        interaction.requestSelectedOpen()
        #expect(interaction.mode == .task && interaction.query == "call mum")
        // A late batch for the abandoned query changes nothing.
        await apps.send([app("Call", "/fixture/Call.app")])
        try await Task.sleep(for: .milliseconds(20))
        #expect(interaction.mode == .task && interaction.rows.isEmpty)
    }

    @Test func newTaskWithMultilineTextExplainsTheRuleAndKeepsSearchAndTheText() async throws {
        _ = NSApplication.shared
        let apps = CatalogFeed()
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, typingGap: .zero))
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await firstResponderEditor()
        editor.insertText("one\ntwo", replacementRange: none)
        await apps.send([])
        try await eventually { !interaction.isLoading }
        interaction.moveSelection(by: 1)
        editor.keyDown(with: try returnKey())
        #expect(interaction.mode == .search && editor.string == "one\ntwo")
        #expect(interaction.statusMessage == "Tasks are one line. Remove the line breaks to make this a task.")
        #expect(interaction.rows == suggestions && interaction.selectedRow == .suggestion(.task))
        // New note keeps every line.
        interaction.moveSelection(by: -1)
        editor.keyDown(with: try returnKey())
        #expect(interaction.mode == .note && editor.string == "one\ntwo")
        #expect(interaction.captureMessage == nil)
    }

    private let none = NSRange(location: NSNotFound, length: 0)

    private func firstResponderEditor() async throws -> NSTextView {
        try await eventually { NSApp.keyWindow?.firstResponder is NSTextView }
        return try #require(NSApp.keyWindow?.firstResponder as? NSTextView)
    }
}
