import AppKit
import Synchronization
import Testing
@testable import Hana

@MainActor
struct NoteSessionOrganizationTests {
    @Test func pinFlushesWritingAndTheNextAutosaveUsesTheAdoptedRevision() async throws {
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        let note = try await store.perform(.createNote(operation: UUID(), body: "Original"), in: store.generation)
        let clock = TestClock()
        let session = try await NoteEditing(store: store, clock: clock).open(note.id)
        session.edit("Writing ไทย\n**kept**")
        try await session.organize(.setPinned(true))
        #expect(session.committed.body == "Writing ไทย\n**kept**" && session.committed.isPinned)
        #expect(session.committed.revision == 3 && session.state == .saved)
        session.edit("Next writing")
        clock.advance(by: .milliseconds(300))
        try await eventually { session.state == .saved && session.committed.body == "Next writing" }
        #expect(session.committed.revision == 4 && session.committed.isPinned)
        #expect(try await store.read(.note(note.id), in: store.generation) == session.committed)
        await store.close()
    }
}

@Suite(.serialized, .nativeWindowSlot, .timeLimit(.minutes(1)))
@MainActor
struct OpenNoteOrganizationTests {
    @Test func mainWindowPinFlushesItsOpenNativeEditorBeforeChangingMetadata() async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        let note = try await store.perform(.createNote(operation: UUID(), body: "Original"), in: store.generation)
        let interaction = MacInteraction(collection: Task { store })
        defer { interaction.window(for: .note(note.id))?.close(); interaction.stop() }
        interaction.open(.main)
        try await eventually { interaction.mainWindowPresentation?.rows.first?.id == note.id }
        interaction.open(.note(note.id))
        try await eventually { interaction.window(for: .note(note.id))?.firstResponder is NSTextView }
        let window = try #require(interaction.window(for: .note(note.id)))
        let editor = try #require(window.firstResponder as? NSTextView)
        let row = try #require(interaction.mainWindowPresentation?.rows.first)
        editor.selectAll(nil)
        editor.insertText("Pending native writing ไทย", replacementRange: NSRange(location: NSNotFound, length: 0))
        await interaction.organizeNote(row, action: .setPinned(true))
        let pinned = try #require(try await store.read(.note(note.id), in: store.generation))
        #expect(pinned.body == "Pending native writing ไทย" && pinned.isPinned)
        #expect(interaction.noteSession(note.id)?.state == .saved)
        await store.close()
    }

    @Test func archiveFlushesAndLocksTheNativeNoteUntilWindowRestore() async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        let note = try await store.perform(.createNote(operation: UUID(), body: "Original"), in: store.generation)
        _ = try await store.perform(.setNotePinned(note.id, true, expectedRevision: 1), in: store.generation)
        let interaction = MacInteraction(collection: Task { store })
        defer { interaction.window(for: .note(note.id))?.close(); interaction.stop() }
        interaction.open(.main)
        try await eventually { interaction.mainWindowPresentation?.rows.first?.isPinned == true }
        interaction.open(.note(note.id))
        try await eventually { interaction.window(for: .note(note.id))?.firstResponder is NSTextView }
        let editor = try #require(interaction.window(for: .note(note.id))?.firstResponder as? NSTextView)
        let row = try #require(interaction.mainWindowPresentation?.rows.first)
        editor.selectAll(nil)
        editor.insertText("Draft kept before archive ไทย", replacementRange: NSRange(location: NSNotFound, length: 0))
        await interaction.organizeNote(row, action: .archive)
        try await eventually { !editor.isEditable && interaction.canRestoreNote(note.id) }
        let archived = try #require(try await store.read(.note(note.id), in: store.generation))
        #expect(archived.body == "Draft kept before archive ไทย" && archived.archivedAt != nil && archived.isPinned)
        editor.insertText("lost", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.string == "Draft kept before archive ไทย")
        #expect(await interaction.restoreNote(note.id))
        try await eventually { editor.isEditable && interaction.mainWindowPresentation?.rows.first?.id == note.id }
        let restored = try #require(try await store.read(.note(note.id), in: store.generation))
        #expect(restored.body == archived.body && restored.isPinned && restored.archivedAt == nil)
        #expect(restored.contentEditedAt == archived.contentEditedAt)
        #expect(interaction.noteSession(note.id)?.state == .saved)
        await store.close()
    }

}
