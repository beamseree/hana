import AppKit
import Synchronization
import Testing
@testable import Hana

@Suite(.serialized, .nativeWindowSlot, .timeLimit(.minutes(1)))
@MainActor
struct CompletedArchiveTests {
    @Test func completedUsesStoreOrderAndReopenReturnsToInboxTop() async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000.250))
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let built = try await OrganizedCollection.build(in: store, clock: clock)
        let interaction = MacInteraction(collection: Task { store })
        defer { interaction.stop() }
        interaction.open(.main, section: .completed)
        try await eventually { interaction.taskWorkspacePresentation?.completed == built.views.completed }
        let reopened = try #require(built.views.completed.first { $0.title == "Done A" })
        interaction.selectTask(reopened.id)
        #expect(!interaction.canPerformTaskAction(.complete))
        #expect(!interaction.canPerformTaskAction(.moveUp))
        #expect(!interaction.canPerformTaskAction(.moveToToday))
        #expect(await interaction.performTaskAction(.reopen))
        try await eventually { interaction.taskWorkspacePresentation?.inbox.first?.id == reopened.id }
        #expect(try await store.read(.task(reopened.id), in: store.generation)?.completedAt == nil)
        try await eventually { interaction.taskWorkspacePresentation?.completed.contains { $0.id == reopened.id } == false }
        await store.close()
    }
    @Test func completedNativeRenameAndArchiveKeepCompletion() async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        let original = try await store.perform(.createTask(operation: UUID(), title: "Finished"), in: store.generation)
        let done = try await store.perform(.completeTask(original.id, expectedRevision: 1), in: store.generation)
        let interaction = MacInteraction(collection: Task { store })
        defer { interaction.stop() }
        interaction.start()
        interaction.open(.main, section: .completed)
        try await eventually { interaction.taskWorkspacePresentation?.completed.first?.id == done.id }
        interaction.selectTask(done.id)
        #expect(await interaction.performTaskAction(.rename))
        let window = try #require(interaction.window(for: .main))
        try await eventually { nativeTaskTitleEditor(in: window.contentView) != nil }
        let editor = try #require(nativeTaskTitleEditor(in: window.contentView))
        editor.selectAll(nil)
        editor.insertText("Finished ไทย", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(await interaction.commitTaskRename())
        try await eventually { interaction.taskWorkspacePresentation?.completed.first?.title == "Finished ไทย" }
        #expect(await interaction.performTaskAction(.archive))
        try await eventually { interaction.taskWorkspacePresentation?.completed.isEmpty == true }
        let archived = try #require(try await store.read(.task(done.id), in: store.generation))
        #expect(archived.completedAt == done.completedAt && archived.archivedAt != nil)
        #expect(archived.title == "Finished ไทย")
        let menu = try #require(NSApp.mainMenu?.item(withTitle: "Tasks")?.submenu)
        let reopen = try #require(menu.item(withTitle: "Reopen Task"))
        #expect(reopen.keyEquivalent == "o" && reopen.keyEquivalentModifierMask == [.command, .shift])
        #expect(Set(menu.items.map(\.keyEquivalent)).count == menu.items.count)
        await store.close()
    }

    @Test func archiveInterleavesFixtureRecordsAndLabelsTheirKindAndCompletion() async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000.250))
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let built = try await OrganizedCollection.build(in: store, clock: clock)
        let interaction = MacInteraction(collection: Task { store })
        defer { interaction.stop() }
        interaction.open(.main, section: .archive)
        let expected = built.views.archivedTasks.map { ArchiveWorkspacePresentation.Row.ID.task($0.id) }
            + built.views.archivedNotes.map { ArchiveWorkspacePresentation.Row.ID.note($0.id) }
        try await eventually { interaction.archiveWorkspacePresentation?.rows.map(\.id) == expected }
        let rows = try #require(interaction.archiveWorkspacePresentation?.rows)
        #expect(rows.map(\.kindLabel) == ["Task", "Task", "Note", "Note"])
        #expect(Set(rows.compactMap(\.completionLabel)) == ["Unfinished", "Completed"])
        #expect(rows.map(\.title) == built.views.archivedTasks.map(\.title) + built.views.archivedNotes.map { $0.title ?? "Untitled" })
        await store.close()
    }

    @Test func everyFixtureRestorePreservesMetadataAndLandsInItsView() async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000.250))
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        _ = try await OrganizedCollection.build(in: store, clock: clock)
        let interaction = MacInteraction(collection: Task { store })
        defer { interaction.stop() }
        interaction.open(.main, section: .archive)
        try await eventually { interaction.archiveWorkspacePresentation?.rows.count == 4 }
        let rows = try #require(interaction.archiveWorkspacePresentation?.rows)
        for row in rows {
            #expect(await interaction.restoreArchived(row))
            switch row {
            case .note(let archived):
                let restored = try #require(try await store.read(.note(archived.id), in: store.generation))
                #expect(restored.body == archived.body && restored.isPinned == archived.isPinned)
                #expect(restored.contentEditedAt == archived.contentEditedAt && restored.archivedAt == nil)
                try await eventually { interaction.mainWindowPresentation?.rows.contains { $0.id == restored.id } == true }
            case .task(let archived):
                let restored = try #require(try await store.read(.task(archived.id), in: store.generation))
                #expect(restored.title == archived.title && restored.completedAt == archived.completedAt && restored.archivedAt == nil)
                if archived.completedAt == nil {
                    #expect(restored.placement == .inbox)
                    try await eventually { interaction.taskWorkspacePresentation?.inbox.first?.id == restored.id }
                } else {
                    #expect(restored.placement == nil)
                    try await eventually { interaction.taskWorkspacePresentation?.completed.contains { $0.id == restored.id } == true }
                }
            }
        }
        try await eventually { interaction.archiveWorkspacePresentation?.rows.isEmpty == true }
        await store.close()
    }

    @Test(arguments: [false, true]) func restoringAnOpenArchivedNoteUpdatesBothWindows(fromNoteWindow: Bool) async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        let original = try await store.perform(.createNote(operation: UUID(), body: "Archived ไทย\n**Markdown**"), in: store.generation)
        _ = try await store.perform(.archiveNote(original.id, expectedRevision: 1), in: store.generation)
        let interaction = MacInteraction(collection: Task { store })
        defer { interaction.window(for: .note(original.id))?.close(); interaction.stop() }
        interaction.open(.main, section: .archive)
        try await eventually { interaction.archiveWorkspacePresentation?.rows.count == 1 }
        let row = try #require(interaction.archiveWorkspacePresentation?.rows.first)
        #expect(interaction.openArchivedNote(row))
        try await eventually { interaction.window(for: .note(original.id))?.firstResponder is NSTextView }
        let editor = try #require(interaction.window(for: .note(original.id))?.firstResponder as? NSTextView)
        #expect(!editor.isEditable && interaction.canRestoreNote(original.id))
        editor.insertText("Refused", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.string == original.body)
        if fromNoteWindow { #expect(await interaction.restoreNote(original.id)) }
        else { #expect(await interaction.restoreArchived(row)) }
        try await eventually { editor.isEditable && interaction.archiveWorkspacePresentation?.rows.isEmpty == true }
        #expect(interaction.noteSession(original.id)?.state == .saved)
        #expect(interaction.noteSession(original.id)?.text == original.body)
        await store.close()
    }

    @Test func invalidRenameKeepsItsVisibleSectionUntilFixedOrCanceled() async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        let task = try await store.perform(.createTask(operation: UUID(), title: "Keep visible"), in: store.generation)
        let interaction = MacInteraction(collection: Task { store })
        defer { interaction.stop() }
        interaction.open(.main, section: .inbox)
        try await eventually { interaction.taskWorkspacePresentation?.inbox.first?.id == task.id }
        interaction.selectTask(task.id)
        #expect(await interaction.performTaskAction(.rename))
        interaction.editTaskTitle("  ")
        interaction.open(.main, section: .completed)
        try await eventually { interaction.taskWorkspacePresentation?.notice != nil }
        #expect(interaction.mainWindowPresentation?.selectedSection == .inbox)
        let window = try #require(interaction.window(for: .main))
        try await eventually { nativeTaskTitleEditor(in: window.contentView) != nil }
        #expect(interaction.taskWorkspacePresentation?.editing?.text == "  ")
        interaction.editTaskTitle("Fixed title")
        interaction.open(.main, section: .completed)
        try await eventually { interaction.taskWorkspacePresentation?.editing == nil && interaction.mainWindowPresentation?.selectedSection == .completed }
        #expect(try await store.read(.task(task.id), in: store.generation)?.title == "Fixed title")
        await store.close()
    }

    @Test(arguments: [false, true]) func navigationWaitsForAPausedRenameAndUsesTheLatestRequestedSection(returnToCurrent: Bool) async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let gate = CommitGate()
        defer { gate.open() }
        let armed = Mutex(false)
        let store = try await CollectionStore.open(fixture.location, faults: .init(beforeCommit: { _ in
            if armed.withLock({ $0 }) { gate.pass() }
        }))
        let task = try await store.perform(.createTask(operation: UUID(), title: "Original"), in: store.generation)
        let interaction = MacInteraction(collection: Task { store })
        defer { interaction.stop() }
        interaction.open(.main, section: .inbox)
        try await eventually { interaction.taskWorkspacePresentation?.inbox.first?.id == task.id }
        interaction.selectTask(task.id)
        #expect(await interaction.performTaskAction(.rename))
        interaction.editTaskTitle("Renamed before leaving")
        armed.withLock { $0 = true }
        let renaming = Task { await interaction.commitTaskRename() }
        try await eventually { gate.arrivals == 1 }
        interaction.open(.main, section: .completed)
        interaction.open(.main, section: returnToCurrent ? .inbox : .archive)
        #expect(interaction.mainWindowPresentation?.selectedSection == .inbox)
        gate.open()
        #expect(await renaming.value)
        try await eventually { interaction.mainWindowPresentation?.selectedSection == (returnToCurrent ? .inbox : .archive) }
        #expect(try await store.read(.task(task.id), in: store.generation)?.title == "Renamed before leaving")
        #expect(interaction.mainWindowPresentation?.selectedSection == (returnToCurrent ? .inbox : .archive))
        await store.close()
    }

    @Test func closingTheMainWindowDoesNotHideAnInvalidRename() async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        let task = try await store.perform(.createTask(operation: UUID(), title: "Keep visible"), in: store.generation)
        let interaction = MacInteraction(collection: Task { store })
        defer { interaction.stop() }
        interaction.open(.main, section: .inbox)
        try await eventually { interaction.taskWorkspacePresentation?.inbox.first?.id == task.id }
        interaction.selectTask(task.id)
        #expect(await interaction.performTaskAction(.rename))
        interaction.editTaskTitle("  ")
        let window = try #require(interaction.window(for: .main))
        // Drive the native delegate at the agreed seam. Actual performClose is
        // covered by the app-loop harness; CLT can drain its main runner there.
        #expect(interaction.windowShouldClose(window) == false)
        try await eventually { !interaction.mainCloseIsHeld && interaction.taskWorkspacePresentation?.notice != nil }
        #expect(interaction.window(for: .main) === window && window.isVisible)
        #expect(interaction.taskWorkspacePresentation?.editing?.text == "  ")
        #expect(try await store.read(.task(task.id), in: store.generation)?.title == "Keep visible")
        interaction.cancelTaskRename()
        await store.close()
    }

    @Test(arguments: [false, true]) func staleRestoreRefusesTheOldRevisionAndClosedArchiveClearsRows(isNote: Bool) async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        if isNote {
            let note = try await store.perform(.createNote(operation: UUID(), body: "Original"), in: store.generation)
            _ = try await store.perform(.archiveNote(note.id, expectedRevision: 1), in: store.generation)
        } else {
            let task = try await store.perform(.createTask(operation: UUID(), title: "Original"), in: store.generation)
            _ = try await store.perform(.archiveTask(task.id, expectedRevision: 1), in: store.generation)
        }
        let interaction = MacInteraction(collection: Task { store })
        defer { interaction.stop() }
        interaction.open(.main, section: .archive)
        try await eventually { interaction.archiveWorkspacePresentation?.rows.count == 1 }
        let row = try #require(interaction.archiveWorkspacePresentation?.rows.first)
        let current: ArchiveWorkspacePresentation.Row
        switch row {
        case .note(let note):
            let restored = try await store.perform(.restoreNote(note.id, expectedRevision: note.revision), in: store.generation)
            let changed = try await store.perform(.editNote(note.id, expectedRevision: restored.revision, body: "Concurrent writing"), in: store.generation)
            current = .note(try await store.perform(.archiveNote(note.id, expectedRevision: changed.revision), in: store.generation))
        case .task(let task):
            let restored = try await store.perform(.restoreTask(task.id, expectedRevision: task.revision), in: store.generation)
            let changed = try await store.perform(.editTaskTitle(task.id, expectedRevision: restored.revision, title: "Concurrent title"), in: store.generation)
            current = .task(try await store.perform(.archiveTask(task.id, expectedRevision: changed.revision), in: store.generation))
        }
        try await eventually { interaction.archiveWorkspacePresentation?.rows == [current] }
        #expect(await interaction.restoreArchived(row) == false)
        #expect(interaction.archiveWorkspacePresentation?.notice?.contains("changed") == true)
        #expect(interaction.archiveWorkspacePresentation?.rows == [current])
        switch current {
        case .note(let note): #expect(try await store.read(.note(note.id), in: store.generation) == note)
        case .task(let task): #expect(try await store.read(.task(task.id), in: store.generation) == task)
        }
        await store.close()
        try await eventually { interaction.archiveWorkspacePresentation?.availability == .unavailable }
        #expect(interaction.archiveWorkspacePresentation?.rows.isEmpty == true)
        #expect(await interaction.restoreArchived(current) == false)
        #expect(interaction.archiveWorkspacePresentation?.canRestore(current) == false)
    }

    @Test func tiedArchiveKindsAreStableAndAnUnfinishedTodayTaskRestoresToInbox() async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000.250))
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let note = try await store.perform(.createNote(operation: UUID(), body: "Tied note"), in: store.generation)
        let task = try await store.perform(.createTask(operation: UUID(), title: "From Today", placement: .today), in: store.generation)
        _ = try await store.perform(.createTask(operation: UUID(), title: "Existing Inbox"), in: store.generation)
        _ = try await store.perform(.archiveTask(task.id, expectedRevision: 1), in: store.generation)
        _ = try await store.perform(.archiveNote(note.id, expectedRevision: 1), in: store.generation)
        let interaction = MacInteraction(collection: Task { store })
        defer { interaction.stop() }
        interaction.start()
        interaction.open(.main, section: .archive)
        try await eventually { interaction.archiveWorkspacePresentation?.rows.map(\.id) == [.note(note.id), .task(task.id)] }
        let row = try #require(interaction.archiveWorkspacePresentation?.rows.last)
        #expect(await interaction.restoreArchived(row))
        try await eventually { interaction.taskWorkspacePresentation?.inbox.first?.id == task.id }
        #expect(interaction.taskWorkspacePresentation?.today.isEmpty == true)
        let menu = try #require(NSApp.mainMenu?.item(withTitle: "Archive")?.submenu)
        let restore = try #require(menu.item(withTitle: "Restore Selected Item"))
        let open = try #require(menu.item(withTitle: "Open Archived Note"))
        #expect(restore.keyEquivalent == "r")
        #expect(restore.keyEquivalentModifierMask == [.command, .shift])
        #expect(open.keyEquivalent == "\r" && open.keyEquivalentModifierMask.isEmpty)
        await store.close()
    }

    @Test func missingCollectionMakesArchiveUnavailableWithoutEditableRows() async throws {
        _ = NSApplication.shared
        let interaction = MacInteraction()
        defer { interaction.stop() }
        interaction.open(.main, section: .archive)
        #expect(interaction.archiveWorkspacePresentation?.availability == .unavailable)
        #expect(interaction.archiveWorkspacePresentation?.rows.isEmpty == true)
        #expect(interaction.archiveWorkspacePresentation?.selectedRow == nil)
    }

}
