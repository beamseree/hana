import AppKit
import Synchronization
import Testing
@testable import Hana

@Suite(.serialized, .nativeWindowSlot)
@MainActor
struct WorkingWindowReviewTests {
    @Test(arguments: [false, true]) func quitDrainsTaskRenameOrKeepsRefusedDraft(blank: Bool) async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let gate = CommitGate()
        let held = Mutex(false)
        let store = try await CollectionStore.open(fixture.location, faults: .init(beforeCommit: { _ in
            if held.withLock({ $0 }) { gate.pass() }
        }))
        let task = try await store.perform(.createTask(operation: UUID(), title: "Original"), in: store.generation)
        let interaction = MacInteraction(collection: Task { store })
        interaction.open(.main, section: .inbox)
        let window = try #require(interaction.window(for: .main))
        defer { window.close(); interaction.stop() }
        try await eventually { interaction.taskWorkspacePresentation?.inbox.count == 1 }
        interaction.selectTask(task.id)
        #expect(await interaction.performTaskAction(.rename))
        interaction.editTaskTitle(blank ? "  " : "Renamed before quit")
        if blank {
            #expect(await interaction.prepareForQuit() == false)
            #expect(interaction.taskWorkspacePresentation?.editing?.text == "  ")
            #expect(interaction.taskWorkspacePresentation?.notice != nil)
            interaction.editTaskTitle("Retry after refused quit")
            #expect(interaction.taskWorkspacePresentation?.editing?.text == "Retry after refused quit")
            #expect(await interaction.prepareForQuit())
        } else {
            held.withLock { $0 = true }
            let rename = Task { await interaction.commitTaskRename() }
            defer { gate.open() }
            try await eventually { gate.arrivals == 1 }
            let quitting = Task { await interaction.prepareForQuit() }
            for _ in 0..<20 { await Task.yield() }
            gate.open()
            #expect(await rename.value)
            #expect(await quitting.value)
        }
        let reopened = try await CollectionStore.open(fixture.location)
        #expect(try await reopened.read(.task(task.id), in: reopened.generation)?.title == (blank ? "Retry after refused quit" : "Renamed before quit"))
        await reopened.close()
    }
    @Test(arguments: [false, true]) func independentDelayedNoteOpeningSurvivesNewerDestination(raiseMain: Bool) async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        let first = try await store.perform(.createNote(operation: UUID(), body: "First"), in: store.generation)
        let second = try await store.perform(.createNote(operation: UUID(), body: "Second"), in: store.generation)
        var completion: CheckedContinuation<CollectionStore, any Error>?
        let collection = Task<CollectionStore, any Error> { try await withCheckedThrowingContinuation { completion = $0 } }
        let interaction = MacInteraction(collection: collection, frontmostApplication: { .current })
        interaction.open(.main)
        defer {
            interaction.window(for: .note(first.id))?.close()
            interaction.window(for: .note(second.id))?.close()
            interaction.window(for: .main)?.close()
            interaction.stop()
        }
        interaction.open(.note(first.id))
        if raiseMain { interaction.open(.main) } else { interaction.open(.note(second.id)) }
        try await eventually { completion != nil }
        completion?.resume(returning: store)
        try await eventually { interaction.window(for: .note(first.id))?.isVisible == true }
        if !raiseMain { try await eventually { interaction.window(for: .note(second.id))?.isVisible == true } }
        #expect(interaction.window(for: .note(first.id)) !== NSApp.keyWindow)
        await store.close()
    }

    @Test func taskMenuKeepsTheClickedTargetAcrossSelectionChanges() async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        let first = try await store.perform(.createTask(operation: UUID(), title: "Clicked"), in: store.generation)
        let second = try await store.perform(.createTask(operation: UUID(), title: "New selection"), in: store.generation)
        let interaction = MacInteraction(collection: Task { store })
        interaction.start()
        interaction.open(.main, section: .inbox)
        defer { interaction.window(for: .main)?.close(); interaction.stop() }
        try await eventually { interaction.taskWorkspacePresentation?.inbox.count == 2 }
        interaction.selectTask(first.id)
        let menu = try #require(NSApp.mainMenu?.item(withTitle: "Tasks")?.submenu)
        menu.performActionForItem(at: menu.indexOfItem(withTitle: "Complete Task"))
        interaction.selectTask(second.id)
        try await eventually { interaction.taskWorkspacePresentation?.inbox.count == 1 }
        #expect(try await store.read(.task(first.id), in: store.generation)?.completedAt != nil)
        #expect(try await store.read(.task(second.id), in: store.generation)?.completedAt == nil)
        await store.close()
    }

    @Test func noteMenuNeverChangesTheBackgroundOrganizerSelection() async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        let background = try await store.perform(.createNote(operation: UUID(), body: "Selected in main"), in: store.generation)
        let front = try await store.perform(.createNote(operation: UUID(), body: "Front note"), in: store.generation)
        let interaction = MacInteraction(collection: Task { store })
        interaction.start()
        interaction.open(.main)
        defer { interaction.window(for: .note(front.id))?.close(); interaction.window(for: .main)?.close(); interaction.stop() }
        try await eventually { interaction.mainWindowPresentation?.rows.count == 2 }
        interaction.selectMainNote(background.id)
        interaction.open(.note(front.id))
        try await eventually { interaction.window(for: .note(front.id))?.firstResponder is NSTextView }
        let menu = try #require(NSApp.mainMenu?.item(withTitle: "Note")?.submenu)
        let pin = try #require(menu.item(withTitle: "Pin Note"))
        #expect(!interaction.validateMenuItem(pin))
        menu.performActionForItem(at: menu.index(of: pin))
        for _ in 0..<20 { await Task.yield() }
        #expect(try await store.read(.note(background.id), in: store.generation)?.isPinned == false)
        await store.close()
    }

    @Test func menusExposeUniqueScopedCommandsAndNavigateSections() async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        let note = try await store.perform(.createNote(operation: UUID(), body: "# Preview"), in: store.generation)
        let interaction = MacInteraction(collection: Task { store })
        interaction.start()
        interaction.open(.main)
        defer { interaction.window(for: .note(note.id))?.close(); interaction.window(for: .main)?.close(); interaction.stop() }
        try await eventually { interaction.mainWindowPresentation?.rows.count == 1 }
        let view = try #require(NSApp.mainMenu?.item(withTitle: "View")?.submenu)
        for section in MainSection.allCases {
            view.performActionForItem(at: view.indexOfItem(withTitle: "Show " + section.rawValue))
            try await eventually { interaction.mainWindowPresentation?.selectedSection == section }
        }
        view.performActionForItem(at: view.indexOfItem(withTitle: "Show Notes"))
        interaction.selectMainNote(note.id)
        let notes = try #require(NSApp.mainMenu?.item(withTitle: "Note")?.submenu)
        #expect(notes.item(withTitle: "Open Note")?.keyEquivalent == "o")
        #expect(view.item(withTitle: "Markdown Preview")?.keyEquivalentModifierMask == [.command, .option])
        let keys = (NSApp.mainMenu?.items.flatMap { $0.submenu?.items ?? [] } ?? []).filter { !$0.keyEquivalent.isEmpty }
            .map { "\($0.keyEquivalent.lowercased()):\($0.keyEquivalentModifierMask.rawValue):\($0.keyEquivalent == $0.keyEquivalent.uppercased())" }
        #expect(Set(keys).count == keys.count)
        await store.close()
    }

    @Test func staleTaskRequestsRefuseRevisionAndSectionChanges() async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        let first = try await store.perform(.createTask(operation: UUID(), title: "Observed"), in: store.generation)
        let second = try await store.perform(.createTask(operation: UUID(), title: "Other"), in: store.generation)
        let interaction = MacInteraction(collection: Task { store })
        interaction.open(.main, section: .inbox)
        defer { interaction.window(for: .main)?.close(); interaction.stop() }
        try await eventually { interaction.taskWorkspacePresentation?.inbox.count == 2 }
        interaction.selectTask(first.id)
        let rename = try #require(interaction.requestTaskAction(.rename))
        _ = try await store.perform(.editTaskTitle(first.id, expectedRevision: first.revision, title: "Changed elsewhere"), in: store.generation)
        try await eventually { interaction.taskWorkspacePresentation?.inbox.first(where: { $0.id == first.id })?.revision == 2 }
        interaction.selectTask(second.id)
        #expect(await interaction.performTaskAction(rename) == false)
        #expect(interaction.taskWorkspacePresentation?.editing == nil)
        #expect(interaction.taskWorkspacePresentation?.notice != nil)
        let complete = try #require(interaction.requestTaskAction(.complete))
        interaction.open(.main, section: .today)
        #expect(await interaction.performTaskAction(complete) == false)
        #expect(try await store.read(.task(second.id), in: store.generation)?.completedAt == nil)
        await store.close()
    }

    @Test func stoppingCancelsADelayedOrdinaryOpening() async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        let note = try await store.perform(.createNote(operation: UUID(), body: "Never open after stop"), in: store.generation)
        var completion: CheckedContinuation<CollectionStore, any Error>?
        let collection = Task<CollectionStore, any Error> { try await withCheckedThrowingContinuation { completion = $0 } }
        let interaction = MacInteraction(collection: collection)
        interaction.open(.main)
        interaction.open(.note(note.id))
        try await eventually { completion != nil }
        interaction.window(for: .main)?.close()
        interaction.stop()
        completion?.resume(returning: store)
        for _ in 0..<50 { await Task.yield() }
        #expect(interaction.window(for: .note(note.id)) == nil)
        await store.close()
    }

    @Test func quitFreezesNativeTaskAndNoteInputBeforeWaitingForRename() async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let gate = CommitGate()
        let held = Mutex(false)
        let store = try await CollectionStore.open(fixture.location, faults: .init(beforeCommit: { _ in if held.withLock({ $0 }) { gate.pass() } }))
        let task = try await store.perform(.createTask(operation: UUID(), title: "Original task"), in: store.generation)
        let note = try await store.perform(.createNote(operation: UUID(), body: "Original note"), in: store.generation)
        let interaction = MacInteraction(collection: Task { store })
        interaction.open(.main, section: .inbox)
        defer { interaction.window(for: .note(note.id))?.close(); interaction.window(for: .main)?.close(); interaction.stop() }
        interaction.open(.note(note.id))
        try await eventually { interaction.window(for: .note(note.id))?.firstResponder is NSTextView }
        let noteEditor = try #require(interaction.window(for: .note(note.id))?.firstResponder as? NSTextView)
        interaction.open(.main, section: .inbox)
        try await eventually { interaction.taskWorkspacePresentation?.inbox.count == 1 }
        interaction.selectTask(task.id)
        #expect(await interaction.performTaskAction(.rename))
        try await eventually { nativeTaskTitleEditor(in: interaction.window(for: .main)?.contentView) != nil }
        let taskEditor = try #require(nativeTaskTitleEditor(in: interaction.window(for: .main)?.contentView))
        interaction.editTaskTitle("Saved task draft")
        interaction.noteSession(note.id)?.edit("Saved note draft")
        held.withLock { $0 = true }
        let quitting = Task { await interaction.prepareForQuit() }
        defer { gate.open() }
        try await eventually { gate.arrivals == 1 }
        #expect(!taskEditor.isEditable && !noteEditor.isEditable)
        taskEditor.insertText("late", replacementRange: NSRange(location: NSNotFound, length: 0))
        interaction.editTaskTitle("late direct draft")
        #expect(interaction.taskWorkspacePresentation?.editing?.text == "Saved task draft")
        #expect(!interaction.canPerformTaskAction(.rename))
        gate.open()
        #expect(await quitting.value)
        let reopened = try await CollectionStore.open(fixture.location)
        #expect(try await reopened.read(.task(task.id), in: reopened.generation)?.title == "Saved task draft")
        #expect(try await reopened.read(.note(note.id), in: reopened.generation)?.body == "Saved note draft")
        await reopened.close()
    }

    @Test func openingDuringClosedNoteArchiveSharesTheOrganizationFreeze() async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let gate = CommitGate()
        let held = Mutex(false)
        let store = try await CollectionStore.open(fixture.location, faults: .init(beforeCommit: { _ in if held.withLock({ $0 }) { gate.pass() } }))
        let note = try await store.perform(.createNote(operation: UUID(), body: "Original"), in: store.generation)
        let interaction = MacInteraction(collection: Task { store })
        interaction.open(.main)
        defer { interaction.window(for: .note(note.id))?.close(); interaction.window(for: .main)?.close(); interaction.stop() }
        try await eventually { interaction.mainWindowPresentation?.rows.count == 1 }
        let row = try #require(interaction.mainWindowPresentation?.rows.first)
        held.withLock { $0 = true }
        let archiving = Task { await interaction.organizeNote(row, action: .archive) }
        defer { gate.open() }
        try await eventually { gate.arrivals == 1 }
        interaction.open(.note(note.id))
        try await eventually { interaction.window(for: .note(note.id))?.firstResponder is NSTextView }
        let editor = try #require(interaction.window(for: .note(note.id))?.firstResponder as? NSTextView)
        #expect(!editor.isEditable)
        editor.insertText("Late unsaved text", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(interaction.noteSession(note.id)?.text == "Original")
        gate.open()
        await archiving.value
        try await eventually { interaction.noteSession(note.id)?.committed.archivedAt != nil }
        #expect(interaction.noteSession(note.id)?.text == "Original")
        #expect(try await store.read(.note(note.id), in: store.generation)?.body == "Original")
        await store.close()
    }

}
