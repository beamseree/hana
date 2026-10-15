import AppKit
import Testing
@testable import Hana

/// Capturing a task through the real editor into a real temporary Store.
/// Fixture roots only: nothing here can reach the live collection.
@Suite(.serialized, .nativeWindowSlot, .timeLimit(.minutes(1)))
@MainActor
struct TaskSaveTests {
    private let none = NSRange(location: NSNotFound, length: 0)

    @Test(arguments: [TaskPlacement.inbox, .today])
    func enterCommitsExactlyOneTaskAtTheTopOfTheChosenList(destination: TaskPlacement) async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        let existing = try await store.perform(.createTask(operation: UUID(), title: "older", placement: destination),
                                               in: store.generation)
        let interaction = MacInteraction(search: Search(source: { CatalogFeed().stream() }, typingGap: .zero),
                                         collection: Task { store }, confirmationDuration: .milliseconds(300))
        let invocation = interaction.presentBar()
        let editor = try await firstResponderEditor()
        editor.insertText("[", replacementRange: none)
        #expect(interaction.mode == .task && interaction.modeLabelText == "Task" && interaction.modeIconShowsTask)
        #expect(interaction.taskDestination == .inbox)
        let title = "call mum บ้าน"
        editor.insertText(title, replacementRange: none)
        if destination == .today { editor.keyDown(with: try tabKey()) }
        #expect(editor.string == title && interaction.taskDestination == destination)
        editor.keyDown(with: try returnKey())

        let confirmation = destination == .today ? "Saved to Today" : "Saved to Inbox"
        try await eventually { interaction.modeLabelText == confirmation }
        #expect(interaction.currentInvocation == invocation)
        try await eventually { interaction.currentInvocation == nil }

        let tasks = try await store.read(.tasks(in: destination), in: store.generation)
        #expect(tasks.map(\.title) == [title, "older"])
        #expect(tasks.last == existing)
        let other: TaskPlacement = destination == .today ? .inbox : .today
        #expect(try await store.read(.tasks(in: other), in: store.generation).isEmpty)
        await store.close()
    }

    @Test func repeatedEnterWhileTheSaveIsPausedCommitsExactlyOneTask() async throws {
        let fixture = try TemporaryFixture()
        let gate = CommitGate()
        let store = try await CollectionStore.open(fixture.location, faults: .init(beforeCommit: { _ in gate.pass() }))
        let interaction = MacInteraction(search: Search(source: { CatalogFeed().stream() }, typingGap: .zero),
                                         collection: Task { store }, confirmationDuration: .zero)
        _ = interaction.presentBar()
        let editor = try await firstResponderEditor()
        editor.insertText("[", replacementRange: none)
        editor.insertText("once", replacementRange: none)
        editor.keyDown(with: try returnKey())
        try await eventually { gate.arrivals == 1 }
        for _ in 0..<3 { editor.keyDown(with: try returnKey()) }
        // Neither the text nor the destination changes while saving.
        editor.keyDown(with: try tabKey())
        editor.insertText(" more", replacementRange: none)
        #expect(editor.string == "once" && interaction.taskDestination == .inbox)
        gate.open()
        try await eventually { interaction.currentInvocation == nil }
        #expect(gate.arrivals == 1)
        #expect(try await store.read(.tasks(in: .inbox), in: store.generation).map(\.title) == ["once"])
        #expect(try await store.read(.tasks(in: .today), in: store.generation).isEmpty)
        await store.close()
    }

    @Test(arguments: [MacInteraction.DismissalReason.escape, .outsideClick])
    func dismissingBeforeASaveWritesNothingAndTheNextInvocationStartsInInbox(
        reason: MacInteraction.DismissalReason
    ) async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        let before = try await store.read(.allRecords, in: store.generation)
        let interaction = MacInteraction(search: Search(source: { CatalogFeed().stream() }, typingGap: .zero),
                                         collection: Task { store })
        let invocation = interaction.presentBar()
        let editor = try await firstResponderEditor()
        editor.insertText("[", replacementRange: none)
        editor.insertText("unsaved task", replacementRange: none)
        editor.keyDown(with: try tabKey())
        #expect(interaction.taskDestination == .today)
        if reason == .escape { editor.keyDown(with: try escapeKey()) } else { interaction.dismiss(invocation, reason: reason) }
        #expect(interaction.currentInvocation == nil)
        try await Task.sleep(for: .milliseconds(50))
        #expect(try await store.read(.allRecords, in: store.generation) == before)

        let next = interaction.presentBar()
        defer { interaction.dismiss(next, reason: .outsideClick) }
        #expect(interaction.mode == .search && interaction.query == "")
        #expect(interaction.modeLabelText == nil && interaction.destinationSelectorTitle == nil)
        editor.insertText("[", replacementRange: none)
        #expect(interaction.mode == .task && editor.string == "" && interaction.taskDestination == .inbox)
        await store.close()
    }

    @Test(arguments: ["", " \t "])
    func aWhitespaceOnlyTitleIsRefusedWithoutReachingTheStore(title: String) async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        let interaction = MacInteraction(search: Search(source: { CatalogFeed().stream() }, typingGap: .zero),
                                         collection: Task { store })
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await firstResponderEditor()
        editor.insertText("[", replacementRange: none)
        if !title.isEmpty { editor.insertText(title, replacementRange: none) }
        editor.keyDown(with: try returnKey())
        try await eventually { interaction.captureMessage != nil }
        #expect(interaction.captureMessage == "Write something to save this task.")
        #expect(interaction.mode == .task && editor.string == title && interaction.currentInvocation == invocation)
        try await Task.sleep(for: .milliseconds(50))
        #expect(try await store.read(.allRecords, in: store.generation).tasks.isEmpty)
        await store.close()
    }

    @Test func shiftEnterInTaskDoesNothing() async throws {
        let interaction = MacInteraction(search: Search(source: { CatalogFeed().stream() }, typingGap: .zero))
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await firstResponderEditor()
        editor.insertText("[", replacementRange: none)
        editor.insertText("one", replacementRange: none)
        editor.keyDown(with: try returnKey(shift: true))
        #expect(editor.string == "one" && interaction.mode == .task)
        #expect(interaction.captureMessage == nil && interaction.currentInvocation == invocation)
    }

    @Test func clickingTheSelectorChoosesTheDestinationAndKeepsTypingFocus() async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        let interaction = MacInteraction(search: Search(source: { CatalogFeed().stream() }, typingGap: .zero),
                                         collection: Task { store }, confirmationDuration: .zero)
        _ = interaction.presentBar()
        let editor = try await firstResponderEditor()
        editor.insertText("[", replacementRange: none)
        #expect(interaction.destinationSelectorTitle == "Inbox")
        let selector = interaction.destinationSelector
        selector.selectedSegment = 1
        #expect(selector.sendAction(selector.action, to: selector.target))
        #expect(interaction.taskDestination == .today && interaction.destinationSelectorTitle == "Today")
        #expect(editor.window?.firstResponder === editor)
        editor.insertText("picked", replacementRange: none)
        editor.keyDown(with: try returnKey())
        try await eventually { interaction.currentInvocation == nil }
        #expect(try await store.read(.tasks(in: .today), in: store.generation).map(\.title) == ["picked"])
        await store.close()
    }

    @Test func switchingToTaskWithMultilineSearchTextIsRefusedWithAnExplanation() async throws {
        let interaction = MacInteraction(search: Search(source: { CatalogFeed().stream() }, typingGap: .zero))
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await firstResponderEditor()
        editor.insertText("one\ntwo", replacementRange: NSRange(location: 0, length: 0))
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText("[", replacementRange: none)
        #expect(interaction.mode == .search && editor.string == "one\ntwo")
        try await eventually { interaction.statusMessage != nil }
        #expect(interaction.statusMessage == "Tasks are one line. Remove the line breaks to make this a task.")
        // Editing clears the explanation.
        editor.setSelectedRange(NSRange(location: 7, length: 0))
        editor.insertText("!", replacementRange: none)
        #expect(interaction.statusMessage != "Tasks are one line. Remove the line breaks to make this a task.")
    }

    @Test func anOpenInProgressOutranksTheRefusedSwitchExplanation() async throws {
        let feed = CatalogFeed()
        let interaction = MacInteraction(search: Search(source: { feed.stream() }, typingGap: .zero),
                                         launchApplication: { _ in try await Task.sleep(for: .seconds(10)); throw CancellationError() })
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await firstResponderEditor()
        editor.insertText("milk\nand", replacementRange: NSRange(location: 0, length: 0))
        let milk = app("Milk and Honey", "/fixture/Milk.app")
        await feed.send([milk])
        try await eventually { interaction.results == [milk] }
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText("[", replacementRange: none)
        #expect(interaction.statusMessage == "Tasks are one line. Remove the line breaks to make this a task.")
        editor.keyDown(with: try returnKey())
        #expect(interaction.statusMessage == "Opening selected destination…")
    }

    @Test func aFailureKeepsTheTitleModeAndDestinationWithAnExplanation() async throws {
        struct Injected: Error {}
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location, faults: .init(beforeCommit: { _ in throw Injected() }))
        let interaction = MacInteraction(search: Search(source: { CatalogFeed().stream() }, typingGap: .zero),
                                         collection: Task { store })
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await firstResponderEditor()
        editor.insertText("[", replacementRange: none)
        editor.insertText("keep me", replacementRange: none)
        editor.keyDown(with: try tabKey())
        editor.keyDown(with: try returnKey())
        try await eventually { interaction.captureMessage != nil }
        #expect(interaction.captureMessage == "Save not confirmed. Your text is kept. Press Enter to retry.")
        #expect(interaction.mode == .task && interaction.modeLabelText == "Task" && interaction.taskDestination == .today)
        #expect(editor.string == "keep me" && interaction.currentInvocation == invocation)
        #expect(try await store.read(.allRecords, in: store.generation).tasks.isEmpty)
        await store.close()
    }

    private func firstResponderEditor() async throws -> NSTextView {
        try await eventually { NSApp.keyWindow?.firstResponder is NSTextView }
        return try #require(NSApp.keyWindow?.firstResponder as? NSTextView)
    }
}

@MainActor
func tabKey() throws -> NSEvent {
    try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                  timestamp: ProcessInfo.processInfo.systemUptime,
                                  windowNumber: NSApp.keyWindow?.windowNumber ?? 0, context: nil,
                                  characters: "\t", charactersIgnoringModifiers: "\t",
                                  isARepeat: false, keyCode: 48))
}
