import Foundation
import Testing
@testable import Hana

@MainActor
struct NoteEditingLifetimeReviewTests {
    @Test(arguments: ["close", "discard", "abandon"])
    func releasesUnownedBodiesAndPreservesOneSharedActiveSession(ending: String) async throws {
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        let note = try await store.perform(.createNote(operation: UUID(), body: String(repeating: "Long note\n", count: 120_000)), in: store.generation)
        let editing = NoteEditing(store: store)
        var first: NoteEditingSession? = try await editing.open(note.id)
        var second: NoteEditingSession? = try await editing.open(note.id)
        weak var released = first
        #expect(first === second)
        first = nil
        #expect(released != nil)
        #expect(editing.existingSession(note.id) === second)
        if ending != "abandon" { second?.edit(note.body + "\nEdited") }
        if ending == "close" { try await second?.close() }
        if ending == "discard" { second?.discardChanges() }
        second = nil
        for _ in 0..<20 { await Task.yield() }
        #expect(released == nil)
        let reopened = try await editing.open(note.id)
        #expect(!reopened.isClosed && reopened.text == (ending == "close" ? note.body + "\nEdited" : note.body))
        try await reopened.close()
        await store.close()
    }
    @Test func ownerFlushKeepsAnUnclosedDraftAfterCallerRelease() async throws {
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        let note = try await store.perform(.createNote(operation: UUID(), body: "Original"), in: store.generation)
        let editing = NoteEditing(store: store, clock: TestClock())
        var session: NoteEditingSession? = try await editing.open(note.id)
        weak var retained = session
        session?.edit("Owned draft after caller release")
        session = nil
        for _ in 0..<20 { await Task.yield() }
        #expect(retained != nil)
        try await editing.flush()
        #expect(try await store.read(.note(note.id), in: store.generation)?.body == "Owned draft after caller release")
        try await retained?.close()
        for _ in 0..<20 { await Task.yield() }
        #expect(retained == nil)
        await store.close()
    }

}
