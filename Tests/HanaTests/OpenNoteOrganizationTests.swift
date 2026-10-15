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

    @Test func metadataOnlyObservationAdoptsRevisionAndPeerRestoreReturnsToSaved() async throws {
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        let note = try await store.perform(.createNote(operation: UUID(), body: "Original"), in: store.generation)
        let clock = TestClock()
        let session = try await NoteEditing(store: store, clock: clock).open(note.id)
        session.edit("Pending after peer pin")
        let pinned = try await store.perform(.setNotePinned(note.id, true, expectedRevision: 1), in: store.generation)
        try await eventually { session.committed.revision == pinned.revision }
        clock.advance(by: .milliseconds(300))
        try await eventually { session.state == .saved && session.committed.body == "Pending after peer pin" }
        let archived = try await store.perform(.archiveNote(note.id, expectedRevision: session.committed.revision), in: store.generation)
        try await eventually { session.state == .readOnly }
        let restored = try await store.perform(.restoreNote(note.id, expectedRevision: archived.revision), in: store.generation)
        try await eventually { session.committed.revision == restored.revision }
        #expect(session.state == .saved && session.isEditable)
        #expect(session.committed.isPinned && session.text == "Pending after peer pin")
        await store.close()
    }


    @Test func aPausedArchiveFreezesWritingWithoutReleasingQuitSuspension() async throws {
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let gate = CommitGate()
        defer { gate.open() }
        let armed = Mutex(false)
        let store = try await CollectionStore.open(fixture.location, faults: .init(beforeCommit: { _ in
            if armed.withLock({ $0 }) { gate.pass() }
        }))
        let note = try await store.perform(.createNote(operation: UUID(), body: "Original"), in: store.generation)
        let session = try await NoteEditing(store: store, clock: TestClock()).open(note.id)
        armed.withLock { $0 = true }
        let archiving = Task { try await session.organize(.archive) }
        try await eventually { gate.arrivals == 1 }
        #expect(!session.isEditable && session.isOrganizing)
        #expect(session.status == "Organizing…")
        session.edit("Too late")
        #expect(session.text == "Original")
        session.suspendEditing(true)
        gate.open()
        try await archiving.value
        #expect(session.state == .readOnly && !session.isOrganizing)
        #expect(session.isEditingSuspended && !session.isEditable)
        await #expect(throws: NoteOrganizationError.unavailable) { try await session.organize(.restore) }
        session.suspendEditing(false)
        try await session.organize(.restore)
        #expect(session.isEditable && session.text == "Original")
        await store.close()
    }

    @Test func lateMetadataAcknowledgmentCannotReviveAnInvalidatedSession() async throws {
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let gate = CommitGate()
        defer { gate.open() }
        let armed = Mutex(false)
        let store = try await CollectionStore.open(fixture.location, faults: .init(afterCommit: {
            if armed.withLock({ $0 }) { gate.pass() }
        }))
        let note = try await store.perform(.createNote(operation: UUID(), body: "Original"), in: store.generation)
        let session = try await NoteEditing(store: store, clock: TestClock()).open(note.id)
        armed.withLock { $0 = true }
        let pinning = Task { try await session.organize(.setPinned(true)) }
        try await eventually { gate.arrivals == 1 }
        let closing = Task { await store.close() }
        try await eventually { session.state == .invalidated }
        #expect(session.status.contains("no longer available"))
        gate.open()
        await #expect(throws: CollectionStoreError.closed) { try await pinning.value }
        await closing.value
        #expect(session.state == .invalidated && !session.isEditable && !session.canOrganize)
        let reopened = try await CollectionStore.open(fixture.location)
        #expect(try await reopened.read(.note(note.id), in: reopened.generation)?.isPinned == true)
        #expect(session.state == .invalidated)
        await reopened.close()
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
        let gate = CommitGate()
        defer { gate.open() }
        let remaining = Mutex(0)
        let store = try await CollectionStore.open(fixture.location, faults: .init(beforeCommit: { _ in
            let pause = remaining.withLock { count in
                guard count > 0 else { return false }
                count -= 1
                return count == 0
            }
            if pause { gate.pass() }
        }))
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
        remaining.withLock { $0 = 2 } // Body flush, then metadata transaction.
        let archiving = Task { await interaction.organizeNote(row, action: .archive) }
        try await eventually { gate.arrivals == 1 }
        try await eventually { !editor.isEditable }
        #expect(interaction.noteSession(note.id)?.isOrganizing == true)
        #expect(!interaction.canRestoreNote(note.id))
        editor.insertText("Late writing", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.string == "Draft kept before archive ไทย")
        gate.open()
        await archiving.value
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

    @Test func failedFlushStopsArchiveAndKeepsTheNativeFailureVisible() async throws {
        _ = NSApplication.shared
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let fail = Mutex(false)
        let store = try await CollectionStore.open(fixture.location, faults: .init(beforeCommit: { _ in
            if fail.withLock({ $0 }) { throw CollectionStoreError.storageFailure(code: 13) }
        }))
        let note = try await store.perform(.createNote(operation: UUID(), body: "Original"), in: store.generation)
        let interaction = MacInteraction(collection: Task { store })
        defer { interaction.window(for: .note(note.id))?.close(); interaction.stop() }
        interaction.open(.main)
        try await eventually { interaction.mainWindowPresentation?.rows.first?.id == note.id }
        interaction.open(.note(note.id))
        try await eventually { interaction.window(for: .note(note.id))?.firstResponder is NSTextView }
        let editor = try #require(interaction.window(for: .note(note.id))?.firstResponder as? NSTextView)
        let row = try #require(interaction.mainWindowPresentation?.rows.first)
        fail.withLock { $0 = true }
        editor.selectAll(nil)
        editor.insertText("Retained writing ไทย", replacementRange: NSRange(location: NSNotFound, length: 0))
        await interaction.organizeNote(row, action: .archive)
        try await eventually { interaction.noteSaveStatus(note.id)?.contains("disk is full") == true }
        let saved = try #require(try await store.read(.note(note.id), in: store.generation))
        #expect(saved.body == "Original" && saved.archivedAt == nil && saved.revision == 1)
        #expect(editor.string == "Retained writing ไทย" && editor.isEditable)
        #expect(interaction.noteActions(note.id) == [.retry, .copyText])
        #expect(!interaction.canRestoreNote(note.id))
        fail.withLock { $0 = false }
        await interaction.performNoteAction(.retry, id: note.id)
        #expect(try await store.read(.note(note.id), in: store.generation)?.body == "Retained writing ไทย")
        await store.close()
    }

    @Test func organizingRefusesNativeMarkedTextUntilCompositionFinishes() async throws {
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
        let editor = try #require(interaction.window(for: .note(note.id))?.firstResponder as? NSTextView)
        let row = try #require(interaction.mainWindowPresentation?.rows.first)
        editor.setMarkedText(" ไทย", selectedRange: NSRange(location: 4, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(editor.hasMarkedText() && interaction.noteSession(note.id)?.isComposing == true)
        await interaction.organizeNote(row, action: .archive)
        #expect(interaction.mainWindowPresentation?.noteNotice == .compositionActive)
        let saved = try #require(try await store.read(.note(note.id), in: store.generation))
        #expect(saved.body == "Original" && saved.archivedAt == nil && saved.revision == 1)
        #expect(editor.hasMarkedText() && editor.string.contains("ไทย"))
        editor.unmarkText()
        await interaction.organizeNote(row, action: .setPinned(true))
        #expect(interaction.noteSession(note.id)?.state == .saved)
        #expect(try await store.read(.note(note.id), in: store.generation)?.body == editor.string)
        await store.close()
    }

}
