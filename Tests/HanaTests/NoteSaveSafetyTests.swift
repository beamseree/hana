import Foundation
import Synchronization
import Testing
@testable import Hana

@MainActor
struct NoteSaveSafetyTests {
    @Test func failureKeepsLatestTextAndRetryCommitsItOnce() async throws {
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let fail = Mutex(false)
        let store = try await CollectionStore.open(fixture.location, faults: .init(beforeCommit: { _ in
            if fail.withLock({ $0 }) { throw CollectionStoreError.storageFailure(code: 13) }
        }))
        let note = try await store.perform(.createNote(operation: UUID(), body: "Original"), in: store.generation)
        let session = try await NoteEditing(store: store, clock: TestClock()).open(note.id)
        #expect(session.status == "Saved")
        fail.withLock { $0 = true }
        session.edit("First edit")
        #expect(session.status == "Unsaved changes")
        await #expect(throws: CollectionStoreError.storageFailure(code: 13)) { try await session.flush() }
        #expect(session.state == .failed(.storageFailure(code: 13)))
        #expect(session.text == "First edit")
        #expect(session.canRetry)
        #expect(session.status.contains("disk is full"))
        session.edit("Latest ไทย")
        fail.withLock { $0 = false }
        try await session.retry()
        #expect(session.state == .saved)
        #expect(session.committed.body == "Latest ไทย")
        #expect(session.committed.revision == 2)
        #expect(try await store.read(.note(note.id), in: store.generation)?.body == "Latest ไทย")
        await store.close()
    }
    @Test func closingTheStoreInvalidatesAPausedSaveBeforeItCanCommit() async throws {
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let gate = CommitGate()
        let enabled = Mutex(false)
        let store = try await CollectionStore.open(fixture.location, faults: .init(beforeCommit: { _ in
            if enabled.withLock({ $0 }) { gate.pass() }
        }))
        let note = try await store.perform(.createNote(operation: UUID(), body: "Original"), in: store.generation)
        let session = try await NoteEditing(store: store, clock: TestClock()).open(note.id)
        enabled.withLock { $0 = true }
        session.edit("Must not commit after invalidation")
        let saving = Task { try await session.flush() }
        defer { gate.open() }
        try await eventually { gate.arrivals == 1 }
        let closing = Task { await store.close() }
        try await eventually { session.state == .invalidated }
        #expect(!session.isEditable)
        gate.open()
        await #expect(throws: CollectionStoreError.closed) { try await saving.value }
        await closing.value
        let reopened = try await CollectionStore.open(fixture.location)
        #expect(try await reopened.read(.note(note.id), in: reopened.generation)?.body == "Original")
        #expect(session.state == .invalidated)
        #expect(session.text == "Must not commit after invalidation")
        session.edit("Late typing")
        #expect(session.text == "Must not commit after invalidation")
        await #expect(throws: CollectionStoreError.closed) { try await session.flush() }
        await reopened.close()
    }

    @Test func aLostAcknowledgmentCanRetryWithoutASecondEditOrStaleRevision() async throws {
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let loseAcknowledgment = Mutex(false)
        let store = try await CollectionStore.open(fixture.location, faults: .init(afterCommit: {
            let fail = loseAcknowledgment.withLock { value in defer { value = false }; return value }
            if fail { throw CollectionStoreError.storageFailure(code: 10) }
        }))
        let note = try await store.perform(.createNote(operation: UUID(), body: "Original"), in: store.generation)
        let session = try await NoteEditing(store: store, clock: TestClock()).open(note.id)
        loseAcknowledgment.withLock { $0 = true }
        session.edit("Committed despite lost acknowledgment ไทย")
        await #expect(throws: CollectionStoreError.storageFailure(code: 10)) { try await session.flush() }
        #expect(session.canRetry)
        #expect(session.status.contains("input/output"))
        #expect(session.text == "Committed despite lost acknowledgment ไทย")
        try await session.retry()
        try await session.retry()
        #expect(session.state == .saved)
        #expect(session.committed.revision == 2)
        #expect(try await store.read(.note(note.id), in: store.generation)?.revision == 2)
        await store.close()
    }

    @Test func explicitDiscardRollsBackAPausedUncommittedSave() async throws {
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let gate = CommitGate()
        let enabled = Mutex(false)
        let store = try await CollectionStore.open(fixture.location, faults: .init(beforeCommit: { _ in
            if enabled.withLock({ $0 }) { gate.pass() }
        }))
        let note = try await store.perform(.createNote(operation: UUID(), body: "Original"), in: store.generation)
        let session = try await NoteEditing(store: store, clock: TestClock()).open(note.id)
        enabled.withLock { $0 = true }
        session.edit("Pending change")
        let saving = Task { try await session.flush() }
        defer { gate.open() }
        try await eventually { gate.arrivals == 1 }
        session.discardChanges()
        gate.open()
        do { try await saving.value; Issue.record("Discarded save unexpectedly succeeded") } catch { }
        #expect(session.isClosed)
        await store.close()
        let reopened = try await CollectionStore.open(fixture.location)
        #expect(try await reopened.read(.note(note.id), in: reopened.generation)?.body == "Original")
        await reopened.close()
    }

    @Test(arguments: [false, true]) func closingFreezesEditsBeforeSuspendingAndRestoresOnlyItsOwnFreeze(fails: Bool) async throws {
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let gate = CommitGate()
        let enabled = Mutex(false)
        let store = try await CollectionStore.open(fixture.location, faults: .init(beforeCommit: { _ in
            if enabled.withLock({ $0 }) {
                gate.pass()
                if fails { throw CollectionStoreError.storageFailure(code: 13) }
            }
        }))
        let note = try await store.perform(.createNote(operation: UUID(), body: "Original"), in: store.generation)
        let session = try await NoteEditing(store: store, clock: TestClock()).open(note.id)
        session.edit("Closing text")
        enabled.withLock { $0 = true }
        let closing = Task { try await session.close() }
        defer { gate.open() }
        try await eventually { gate.arrivals == 1 }
        #expect(!session.isEditable)
        session.edit("Late edit must be refused")
        #expect(session.text == "Closing text")
        // Another lifecycle owner can freeze the session during this close.
        if fails { session.suspendEditing(true) }
        gate.open()
        if fails {
            await #expect(throws: CollectionStoreError.storageFailure(code: 13)) { try await closing.value }
            #expect(!session.isClosed)
            #expect(!session.isEditable)
            session.suspendEditing(false)
            #expect(session.isEditable)
            #expect(session.text == "Closing text")
        } else {
            try await closing.value
            #expect(session.isClosed)
            #expect(session.committed.body == "Closing text")
        }
        await store.close()
    }

}
