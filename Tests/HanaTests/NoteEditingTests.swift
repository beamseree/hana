import Foundation
import Testing
import Synchronization
@testable import Hana

@MainActor
struct NoteEditingTests {
    @Test func idleSaveWaitsThreeHundredMillisecondsAndKeepsExactBytes() async throws {
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        let note = try await store.perform(.createNote(operation: UUID(), body: "Original"), in: store.generation)
        let clock = TestClock()
        let editing = NoteEditing(store: store, clock: clock)
        let session = try await editing.open(note.id)
        #expect(try await editing.open(note.id) === session)
        let body = "  # ไทย e\u{301}\r\n- [ ] **item**\n"
        #expect(session.textRevision == 0)
        session.edit(body)
        #expect(session.textRevision == 1)
        clock.advance(by: .milliseconds(299))
        await Task.yield()
        #expect(session.state == .dirty)
        #expect(try await store.read(.note(note.id), in: store.generation)?.body == "Original")
        clock.advance(by: .milliseconds(1))
        try await eventually { session.state == .saved }
        #expect(Array(session.committed.body.utf8) == Array(body.utf8))
        await store.close()
        let reopened = try await CollectionStore.open(fixture.location)
        #expect(Array(try #require(try await reopened.read(.note(note.id), in: reopened.generation)).body.utf8) == Array(body.utf8))
        await reopened.close()
    }
    @Test func continuousTypingSavesByOneSecondAndCompositionDefersUntilCommitted() async throws {
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        let note = try await store.perform(.createNote(operation: UUID(), body: "Original"), in: store.generation)
        let clock = TestClock()
        let session = try await NoteEditing(store: store, clock: clock).open(note.id)
        session.edit("0")
        for n in 1...4 {
            clock.advance(by: .milliseconds(200))
            session.edit("\(n)")
        }
        clock.advance(by: .milliseconds(199))
        await Task.yield()
        #expect(session.state == .dirty)
        clock.advance(by: .milliseconds(1))
        try await eventually { session.committed.body == "4" }
        session.edit("ไทย", isComposing: true)
        clock.advance(by: .seconds(3))
        try await session.flush()
        #expect(session.committed.body == "4")
        session.edit("ไทย", isComposing: false)
        clock.advance(by: .milliseconds(300))
        try await eventually { session.state == .saved && session.committed.body == "ไทย" }
        await store.close()
    }

    @Test func blankCloseKeepsLastCommittedBody() async throws {
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        let note = try await store.perform(.createNote(operation: UUID(), body: "Keep me"), in: store.generation)
        let session = try await NoteEditing(store: store, clock: TestClock()).open(note.id)
        session.edit(" \t\n")
        #expect(session.state == .blank)
        #expect(session.explanation == "Empty notes aren't saved. Archive the note to remove it.")
        try await session.close()
        #expect(try await store.read(.note(note.id), in: store.generation)?.body == "Keep me")
        #expect(session.isClosed)
        await store.close()
    }

    @Test func aPausedCommitDrainsNewerTextInOrderWithoutMarkingItSavedEarly() async throws {
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let gate = CommitGate()
        let enabled = Synchronization.Mutex(false)
        let store = try await CollectionStore.open(fixture.location, faults: .init(beforeCommit: { _ in
            if enabled.withLock({ $0 }) { gate.pass() }
        }))
        let note = try await store.perform(.createNote(operation: UUID(), body: "Original"), in: store.generation)
        enabled.withLock { $0 = true }
        let session = try await NoteEditing(store: store, clock: TestClock()).open(note.id)
        session.edit("First")
        let flush = Task { try await session.flush() }
        defer { gate.open() }
        try await eventually { gate.arrivals == 1 }
        session.edit("Latest ไทย")
        #expect(session.state == .saving)
        #expect(session.committed.body == "Original")
        gate.open()
        try await flush.value
        #expect(session.state == .saved)
        #expect(session.committed.body == "Latest ไทย")
        #expect(session.committed.revision == 3)
        #expect(try await store.read(.note(note.id), in: store.generation)?.body == "Latest ไทย")
        await store.close()
    }

}
