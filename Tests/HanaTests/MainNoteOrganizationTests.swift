import AppKit
import Testing
@testable import Hana

@Suite(.serialized, .nativeWindowSlot)
@MainActor
struct MainNoteOrganizationTests {
    @Test func pinAndUnpinFollowCommittedOrderWithoutChangingContentEditedTime() async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000))
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let g = store.generation
        let older = try await store.perform(.createNote(operation: UUID(), body: "Older"), in: g)
        clock.advance(by: 1)
        let recent = try await store.perform(.createNote(operation: UUID(), body: "Recent"), in: g)
        let interaction = MacInteraction(collection: Task { store })
        defer { interaction.stop() }
        interaction.open(.main)
        try await eventually { interaction.mainWindowPresentation?.rows.map(\.id) == [recent.id, older.id] }
        let row = try #require(interaction.mainWindowPresentation?.rows.last)
        clock.advance(by: 10)
        await interaction.organizeNote(row, action: .setPinned(true))
        try await eventually { interaction.mainWindowPresentation?.rows.first?.id == older.id }
        let pinned = try #require(try await store.read(.note(older.id), in: g))
        #expect(pinned.isPinned)
        #expect(pinned.contentEditedAt == older.contentEditedAt)
        let pinnedRow = try #require(interaction.mainWindowPresentation?.rows.first)
        await interaction.organizeNote(pinnedRow, action: .setPinned(false))
        try await eventually { interaction.mainWindowPresentation?.rows.map(\.id) == [recent.id, older.id] }
        let unpinned = try #require(try await store.read(.note(older.id), in: g))
        #expect(!unpinned.isPinned)
        #expect(unpinned.contentEditedAt == older.contentEditedAt)
        await store.close()
    }

    @Test func archiveRemovesTheRowAndPreservesWritingAndPin() async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        let g = store.generation
        let note = try await store.perform(.createNote(operation: UUID(), body: "# งาน\nExact *Markdown*  \n"), in: g)
        let pinned = try await store.perform(.setNotePinned(note.id, true, expectedRevision: note.revision), in: g)
        let interaction = MacInteraction(collection: Task { store })
        defer { interaction.stop() }
        interaction.open(.main)
        try await eventually { interaction.mainWindowPresentation?.rows.first?.id == note.id }
        let row = try #require(interaction.mainWindowPresentation?.rows.first)
        await interaction.organizeNote(row, action: .archive)
        try await eventually { interaction.mainWindowPresentation?.rows.isEmpty == true }
        let archived = try #require(try await store.read(.note(note.id), in: g))
        #expect(archived.archivedAt != nil)
        #expect(archived.body == note.body)
        #expect(archived.isPinned)
        #expect(archived.contentEditedAt == pinned.contentEditedAt)
        await store.close()
    }


    @Test(arguments: [MainNoteAction.setPinned(true), .archive])
    func staleActionsKeepTheCommittedNoteAndExplainTheRefusal(action: MainNoteAction) async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        let g = store.generation
        let note = try await store.perform(.createNote(operation: UUID(), body: "Original"), in: g)
        let interaction = MacInteraction(collection: Task { store })
        defer { interaction.stop() }
        interaction.open(.main)
        try await eventually { interaction.mainWindowPresentation?.rows.first?.id == note.id }
        let staleRow = try #require(interaction.mainWindowPresentation?.rows.first)
        let edited = try await store.perform(.editNote(note.id, expectedRevision: note.revision, body: "Committed elsewhere"), in: g)
        await interaction.organizeNote(staleRow, action: action)
        #expect(interaction.mainWindowPresentation?.noteNotice == .refused(.staleRevision))
        try await eventually { interaction.mainWindowPresentation?.rows.first?.title == "Committed elsewhere" }
        #expect(try await store.read(.note(note.id), in: g) == edited)
        await store.close()
    }


    @Test func noteMenusActOnSelectionAndHaveKeyboardEquivalents() async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        let note = try await store.perform(.createNote(operation: UUID(), body: "Selected note"), in: store.generation)
        let interaction = MacInteraction(collection: Task { store })
        let previousMenu = NSApp.mainMenu
        let previousWindowsMenu = NSApp.windowsMenu
        interaction.start()
        defer {
            interaction.stop()
            NSApp.mainMenu = previousMenu
            NSApp.windowsMenu = previousWindowsMenu
        }
        interaction.open(.main)
        try await eventually { interaction.mainWindowPresentation?.rows.first?.id == note.id }
        let menu = try #require(NSApp.mainMenu?.item(withTitle: "Note")?.submenu)
        let pin = try #require(menu.item(withTitle: "Pin Note"))
        let archive = try #require(menu.item(withTitle: "Archive Note"))
        #expect(!interaction.validateMenuItem(pin))
        interaction.selectMainNote(note.id)
        #expect(interaction.validateMenuItem(pin))
        #expect(pin.keyEquivalent == "p")
        #expect(pin.keyEquivalentModifierMask == [.command, .control])
        #expect(archive.keyEquivalent == "a")
        #expect(archive.keyEquivalentModifierMask == [.command, .control])
        menu.performActionForItem(at: menu.index(of: pin))
        try await eventually { interaction.mainWindowPresentation?.rows.first?.isPinned == true }
        #expect(interaction.validateMenuItem(pin))
        #expect(pin.title == "Unpin Note")
        menu.performActionForItem(at: menu.index(of: pin))
        try await eventually { interaction.mainWindowPresentation?.rows.first?.isPinned == false }
        menu.performActionForItem(at: menu.index(of: archive))
        try await eventually { interaction.mainWindowPresentation?.rows.isEmpty == true }
        #expect(!interaction.validateMenuItem(archive))
        await store.close()
    }

}
