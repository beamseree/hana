import Foundation
import Testing
@testable import Hana

@MainActor
@Suite(.timeLimit(.minutes(1)))
struct CollectionTitleSourceTests {
    @Test func committedTitlesBlockAndCompletedOrArchivedItemsStopBlocking() async throws {
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        let source = CollectionTitleSource(store: store)
        #expect(source.snapshot.status == .loading)
        var updates = source.snapshots().makeAsyncIterator()
        _ = try await nextSnapshot(&updates) { $0.status == .ready }

        let note = try await store.perform(.createNote(operation: UUID(), body: "Budget plan"), in: store.generation)
        let withNote = try await nextSnapshot(&updates) { decision("Budget p", $0) == .blocked(.strongMatch(.note)) }
        #expect(withNote.status == .ready)
        _ = try await store.perform(.archiveNote(note.id, expectedRevision: note.revision), in: store.generation)
        _ = try await nextSnapshot(&updates) { decision("Budget p", $0) == .allowed }

        let task = try await store.perform(.createTask(operation: UUID(), title: "Call mom"), in: store.generation)
        _ = try await nextSnapshot(&updates) { decision("Call m", $0) == .blocked(.strongMatch(.task)) }
        _ = try await store.perform(.completeTask(task.id, expectedRevision: task.revision), in: store.generation)
        _ = try await nextSnapshot(&updates) { decision("Call m", $0) == .allowed }

        let archived = try await store.perform(.createTask(operation: UUID(), title: "Book flight"), in: store.generation)
        _ = try await nextSnapshot(&updates) { decision("Book f", $0) == .blocked(.strongMatch(.task)) }
        _ = try await store.perform(.archiveTask(archived.id, expectedRevision: archived.revision), in: store.generation)
        _ = try await nextSnapshot(&updates) { decision("Book f", $0) == .allowed }

        await store.close()
        _ = try await nextSnapshot(&updates) { $0.status == .unavailable }
        #expect(source.snapshot.status == .unavailable)
        #expect(decision("call mom", source.snapshot) == .blocked(.collectionUnavailable))
    }

    @Test func rapidCommittedEditsPublishLatestPreparedNamesBeforeStoreClosure() async throws {
        let fixture = try TemporaryFixture()
        defer { try? FileManager.default.removeItem(at: fixture.directory) }
        let store = try await CollectionStore.open(fixture.location)
        let source = CollectionTitleSource(store: store)
        var updates = source.snapshots().makeAsyncIterator()
        _ = try await nextSnapshot(&updates) { $0.status == .ready }
        let original = try await store.perform(.createNote(operation: UUID(), body: "Café old title"), in: store.generation)
        // Observation may coalesce commits, but an older prepared snapshot may never replace the final one.
        let edited = try await store.perform(.editNote(original.id, expectedRevision: original.revision,
            body: "Café final title"), in: store.generation)
        _ = try await store.perform(.createTask(operation: UUID(), title: "โทรหา แม่"), in: store.generation)
        let latest = try await nextSnapshot(&updates) {
            decision("cafe\u{301} final", $0) == .blocked(.strongMatch(.note)) &&
            decision("โทรหา แม่", $0) == .blocked(.strongMatch(.task))
        }
        #expect(decision("Café old", latest) == .allowed)
        #expect(latest.notes.count == 1 && latest.tasks.count == 1)
        _ = try await store.perform(.archiveNote(edited.id, expectedRevision: edited.revision), in: store.generation)
        _ = try await nextSnapshot(&updates) { $0.notes.isEmpty && $0.tasks.count == 1 }
        await store.close()
        _ = try await nextSnapshot(&updates) { $0.status == .unavailable }
        #expect(source.snapshot.status == .unavailable)
    }

    @Test func missingStoreIsUnavailableImmediately() {
        let source = CollectionTitleSource(store: nil)
        #expect(source.snapshot.status == .unavailable)
        #expect(decision("call mom", source.snapshot) == .blocked(.collectionUnavailable))
    }

    private func decision(_ text: String, _ titles: CollectionTitleSource.Snapshot) -> StrongMatchGate.Decision {
        StrongMatchGate.evaluate(rawBuffer: text, results: [], appStatus: .ready,
                                 fileStatus: .ready, titles: titles).decision
    }

    private func nextSnapshot(_ updates: inout AsyncStream<CollectionTitleSource.Snapshot>.Iterator,
                              where predicate: (CollectionTitleSource.Snapshot) -> Bool) async throws -> CollectionTitleSource.Snapshot {
        while let value = await updates.next(isolation: #isolation) {
            if predicate(value) { return value }
        }
        throw MissingSnapshot()
    }
    private struct MissingSnapshot: Error {}
}
