import Foundation
import GRDB
import Testing
@testable import Hana

@Suite(.timeLimit(.minutes(1)))
struct CollectionStoreTests {
    @Test func savedNoteSurvivesReopenWithExactBodyAndDerivedTitle() async throws {
        let fixture = try TemporaryFixture()
        let body = "\n  \r\n  Thai บันทึก é (e\u{301}) 🌸  \r\n# Markdown *kept*\u{2028}tail\0end  \n"
        let operation = UUID()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_760_000_000.123))
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let created = try await store.perform(.createNote(operation: operation, body: body), in: store.generation)
        #expect(Array(created.body.utf8) == Array(body.utf8))
        #expect(created.title == "Thai บันทึก é (e\u{301}) 🌸")
        #expect(created.revision == 1)
        #expect(created.createdAt == Date(timeIntervalSince1970: 1_760_000_000.123))
        #expect(created.contentEditedAt == created.createdAt)
        #expect(created.updatedAt == created.createdAt)
        #expect(!created.isPinned && created.archivedAt == nil)
        await store.close()

        let reopened = try await CollectionStore.open(fixture.location)
        let read = try #require(try await reopened.read(.note(created.id), in: reopened.generation))
        #expect(read == created)
        #expect(Array(read.body.utf8) == Array(body.utf8))
        #expect(try await reopened.read(.notes, in: reopened.generation) == [created])
        await reopened.close()
    }

    @Test func identicalCreationRetriesReturnOneNoteAndMismatchedReuseFails() async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        let generation = store.generation
        let operation = UUID()
        let ids = try await withThrowingTaskGroup(of: UUID.self) { group in
            for _ in 0..<20 {
                group.addTask { try await store.perform(.createNote(operation: operation, body: "Same\n"), in: generation).id }
            }
            return try await group.reduce(into: Set<UUID>()) { $0.insert($1) }
        }
        #expect(ids.count == 1)
        await #expect(throws: CollectionStoreError.operationReused) {
            try await store.perform(.createNote(operation: operation, body: "Different\n"), in: generation)
        }
        // A changed-normalization body is a different payload, not the same text.
        let decomposed = UUID()
        _ = try await store.perform(.createNote(operation: decomposed, body: "Cafe\u{301}"), in: generation)
        await #expect(throws: CollectionStoreError.operationReused) {
            try await store.perform(.createNote(operation: decomposed, body: "Café"), in: generation)
        }
        await #expect(throws: CollectionStoreError.blankNote) {
            try await store.perform(.createNote(operation: UUID(), body: " \n\t\u{2028}"), in: generation)
        }
        #expect(try await store.read(.notes, in: generation).count == 2)
        await store.close()
    }

    @Test func lostAcknowledgementRetryAfterRestartReturnsTheCommittedNote() async throws {
        let fixture = try TemporaryFixture()
        let operation = UUID()
        let lossy = try await CollectionStore.open(fixture.location, faults: .init(afterCommit: { throw InjectedFailure() }))
        await #expect(throws: InjectedFailure.self) {
            try await lossy.perform(.createNote(operation: operation, body: "Lost ack"), in: lossy.generation)
        }
        let staleGeneration = lossy.generation
        await lossy.close()

        let store = try await CollectionStore.open(fixture.location)
        #expect(store.generation != staleGeneration)
        // Stale work is rejected before the persisted receipt is consulted.
        await #expect(throws: CollectionStoreError.staleGeneration) {
            try await store.perform(.createNote(operation: operation, body: "Lost ack"), in: staleGeneration)
        }
        let retried = try await store.perform(.createNote(operation: operation, body: "Lost ack"), in: store.generation)
        #expect(try await store.read(.notes, in: store.generation) == [retried])
        #expect(retried.body == "Lost ack")
        await store.close()
    }

    @Test func failedWritesRollBackCompletelyAndTheOperationCanBeRetried() async throws {
        let fixture = try TemporaryFixture()
        let failing = try await CollectionStore.open(fixture.location, faults: .init(beforeCommit: { _ in throw InjectedFailure() }))
        let operation = UUID()
        await #expect(throws: InjectedFailure.self) {
            try await failing.perform(.createNote(operation: operation, body: "Rolled back"), in: failing.generation)
        }
        #expect(try await failing.read(.notes, in: failing.generation).isEmpty)
        await failing.close()

        // A bounded real SQLite failure: a CHECK violation inside the same transaction.
        let constrained = try await CollectionStore.open(fixture.location, faults: .init(beforeCommit: { db in
            try db.execute(sql: "INSERT INTO note (id, body, created_at, content_edited_at, updated_at, revision, pinned) VALUES ('short', '', 0, 0, 0, 0, 2)")
        }))
        await #expect(throws: CollectionStoreError.storageFailure(code: 19)) {
            try await constrained.perform(.createNote(operation: operation, body: "Rolled back"), in: constrained.generation)
        }
        #expect(try await constrained.read(.notes, in: constrained.generation).isEmpty)
        await constrained.close()

        let store = try await CollectionStore.open(fixture.location)
        let created = try await store.perform(.createNote(operation: operation, body: "Rolled back"), in: store.generation)
        #expect(try await store.read(.notes, in: store.generation) == [created])
        await store.close()
        await #expect(throws: CollectionStoreError.closed) { try await store.read(.notes, in: store.generation) }
        await #expect(throws: CollectionStoreError.closed) {
            try await store.perform(.createNote(operation: UUID(), body: "After close"), in: store.generation)
        }
    }
}

extension CollectionStoreTests {
    @Test func observationsStartCoherentlyConvergeOnCommitsAndNeverShowRolledBackWork() async throws {
        let fixture = try TemporaryFixture()
        let failNext = Switch()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000))
        let store = try await CollectionStore.open(fixture.location, clock: clock.now, faults: .init(beforeCommit: { _ in
            if failNext.take() { throw InjectedFailure() }
        }))
        let first = try await store.perform(.createNote(operation: UUID(), body: "Already saved"), in: store.generation)
        var observed = store.observe(.notes, in: store.generation).makeAsyncIterator()
        #expect(try await observed.next() == [first])

        var committed = [first]
        for index in 0..<3 {
            clock.advance(by: 1)
            if index == 1 {
                failNext.set()
                await #expect(throws: InjectedFailure.self) {
                    try await store.perform(.createNote(operation: UUID(), body: "Never committed"), in: store.generation)
                }
            }
            committed.append(try await store.perform(.createNote(operation: UUID(), body: "Note \(index)"), in: store.generation))
        }
        // Intermediate commits may coalesce; every value is a committed state
        // and the latest state is eventually observed in Notes order.
        let latest = Array(committed.reversed())
        while let value = try await observed.next() {
            #expect(value.allSatisfy { note in committed.contains(note) })
            if value == latest { break }
        }

        await store.close()
        await #expect(throws: CollectionStoreError.closed) { while try await observed.next() != nil {} }
        let reopened = try await CollectionStore.open(fixture.location)
        var stale = reopened.observe(.notes, in: store.generation).makeAsyncIterator()
        await #expect(throws: CollectionStoreError.staleGeneration) { _ = try await stale.next() }
        await reopened.close()
    }
}

extension CollectionStoreTests {
    @Test func workInFlightOrQueuedBeforeCloseIsRejectedBeforeCommit() async throws {
        let fixture = try TemporaryFixture()
        let writerHeld = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let holdOnce = FailOnce()
        let store = try await CollectionStore.open(fixture.location, faults: .init(beforeCommit: { _ in
            if holdOnce.take() { writerHeld.signal(); release.wait() }
        }))
        let generation = store.generation
        let firstOperation = UUID()
        let first = Task { try await store.perform(.createNote(operation: firstOperation, body: "First"), in: generation) }
        await withCheckedContinuation { continuation in DispatchQueue.global().async { writerHeld.wait(); continuation.resume() } }
        // Accepted at submission, then queued behind the held writer.
        let queuedOperation = UUID()
        let queued = Task { try await store.perform(.createNote(operation: queuedOperation, body: "Queued"), in: generation) }
        try await Task.sleep(for: .milliseconds(100))
        let closing = Task { await store.close() }
        try await Task.sleep(for: .milliseconds(100))
        release.signal()
        await #expect(throws: CollectionStoreError.closed) { try await first.value }
        await #expect(throws: CollectionStoreError.closed) { try await queued.value }
        await closing.value

        let reopened = try await CollectionStore.open(fixture.location)
        #expect(try await reopened.read(.notes, in: reopened.generation).isEmpty)
        // No receipt was committed for the rejected work, so it can still run once.
        let retried = try await reopened.perform(.createNote(operation: queuedOperation, body: "Queued"), in: reopened.generation)
        #expect(try await reopened.read(.notes, in: reopened.generation).count == 1)
        #expect(retried.body == "Queued")
        let firstRetried = try await reopened.perform(.createNote(operation: firstOperation, body: "First"), in: reopened.generation)
        #expect(firstRetried.body == "First")
        #expect(try await reopened.read(.notes, in: reopened.generation).count == 2)
        await reopened.close()
    }
}

struct InjectedFailure: Error {}

/// Reports true once after each `set()`.
final class Switch: @unchecked Sendable {
    private let lock = NSLock()
    private var isOn = false
    func set() { lock.withLock { isOn = true } }
    func take() -> Bool { lock.withLock { defer { isOn = false }; return isOn } }
}

/// Reports true on the first `take()` only.
final class FailOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var pending = true
    func take() -> Bool { lock.withLock { defer { pending = false }; return pending } }
}

/// A new marked disposable root below a fresh temporary directory.
struct TemporaryFixture {
    let directory: URL
    let location: CollectionLocation
    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hana-collection-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        location = try CollectionLocation.createFixtureRoot(at: directory.appendingPathComponent("root"))
    }

    /// Sets task order keys directly while no Store owns the root: the only
    /// way to reach the edge of the key space without 2^63 insertions.
    func setOrderKeys(_ keys: [UUID: Int64]) throws {
        let queue = try DatabaseQueue(path: location.databaseURL.path)
        try queue.write { db in
            for (id, key) in keys { try db.execute(sql: "UPDATE task SET order_key = ? WHERE id = ?", arguments: [key, id.uuidString]) }
        }
        try queue.close()
    }
}

final class FixedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ value: Date) { self.value = value }
    var now: @Sendable () -> Date { { [self] in lock.withLock { value } } }
    func advance(by seconds: TimeInterval) { lock.withLock { value += seconds } }
}
