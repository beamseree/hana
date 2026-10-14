import Foundation
import Testing
@testable import Hana

/// Editing, pinning, archiving and restoring saved notes through the
/// Collection Store, against real temporary SQLite stores.
@Suite(.timeLimit(.minutes(1)))
struct NoteOrganizationTests {
    private static let start = Date(timeIntervalSince1970: 1_800_000_000.250)

    @Test func contentEditReplacesTheExactBodyAndAdvancesContentEditedTimeAndRevision() async throws {
        let fixture = try TemporaryFixture()
        let clock = FixedClock(Self.start)
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let created = try await store.perform(.createNote(operation: UUID(), body: "First draft"), in: store.generation)
        clock.advance(by: 90)
        let body = "\n \t\n  ## ร่าง Thai é (e\u{301}) 🌸 \r\n- [x] *kept*\u{2028}tail  \n"
        let edited = try await store.perform(.editNote(created.id, expectedRevision: 1, body: body), in: store.generation)

        #expect(Array(edited.body.utf8) == Array(body.utf8))
        #expect(edited.title == "## ร่าง Thai é (e\u{301}) 🌸")
        #expect(edited.id == created.id)
        #expect(edited.revision == 2)
        #expect(edited.createdAt == Self.start)
        #expect(edited.contentEditedAt == Self.start + 90)
        #expect(edited.updatedAt == Self.start + 90)
        #expect(!edited.isPinned && edited.archivedAt == nil)
        await store.close()

        let reopened = try await CollectionStore.open(fixture.location)
        #expect(try await reopened.read(.note(created.id), in: reopened.generation) == edited)
        await reopened.close()
    }

    @Test func pinsComeFirstThenMostRecentlyContentEditedThenStableIDAndPinningKeepsContentEditedTime() async throws {
        let fixture = try TemporaryFixture()
        let clock = FixedClock(Self.start)
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let g = store.generation
        let a = try await store.perform(.createNote(operation: UUID(), body: "A"), in: g)
        clock.advance(by: 1)
        let b = try await store.perform(.createNote(operation: UUID(), body: "B"), in: g)
        clock.advance(by: 1)
        // Two notes written at the same instant tie on ID.
        let c = try await store.perform(.createNote(operation: UUID(), body: "C"), in: g)
        let d = try await store.perform(.createNote(operation: UUID(), body: "D"), in: g)
        let (c1, d1) = c.id.uuidString < d.id.uuidString ? (c, d) : (d, c)
        #expect(try await store.read(.notes, in: g).map(\.id) == [c1.id, d1.id, b.id, a.id])

        clock.advance(by: 1)
        let pinned = try await store.perform(.setNotePinned(a.id, true, expectedRevision: 1), in: g)
        #expect(pinned.isPinned && pinned.revision == 2)
        #expect(pinned.contentEditedAt == a.contentEditedAt)
        #expect(pinned.updatedAt == Self.start + 3)
        #expect(pinned.createdAt == a.createdAt && pinned.body == "A")
        #expect(try await store.read(.notes, in: g).map(\.id) == [a.id, c1.id, d1.id, b.id])

        clock.advance(by: 1)
        _ = try await store.perform(.editNote(b.id, expectedRevision: 1, body: "B, rewritten"), in: g)
        #expect(try await store.read(.notes, in: g).map(\.id) == [a.id, b.id, c1.id, d1.id])

        clock.advance(by: 1)
        let unpinned = try await store.perform(.setNotePinned(a.id, false, expectedRevision: 2), in: g)
        #expect(!unpinned.isPinned && unpinned.revision == 3 && unpinned.contentEditedAt == a.contentEditedAt)
        #expect(try await store.read(.notes, in: g).map(\.id) == [b.id, c1.id, d1.id, a.id])
        await store.close()

        let reopened = try await CollectionStore.open(fixture.location)
        #expect(try await reopened.read(.notes, in: reopened.generation).map(\.id) == [b.id, c1.id, d1.id, a.id])
        await reopened.close()
    }

    @Test func pinnedNotesAndArchiveEachOrderByTheirTimeThenStableID() async throws {
        let fixture = try TemporaryFixture()
        let clock = FixedClock(Self.start)
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let g = store.generation
        func ordered(_ a: Note, _ b: Note) -> [UUID] { [a.id, b.id].sorted { $0.uuidString < $1.uuidString } }
        let tiedA = try await store.perform(.createNote(operation: UUID(), body: "Tied A"), in: g)
        let tiedB = try await store.perform(.createNote(operation: UUID(), body: "Tied B"), in: g)
        clock.advance(by: 1)
        let newer = try await store.perform(.createNote(operation: UUID(), body: "Newer"), in: g)
        clock.advance(by: 1)
        let unpinned = try await store.perform(.createNote(operation: UUID(), body: "Unpinned, newest"), in: g)
        // Pinning order does not matter inside the pinned group; writing time does.
        for note in [newer, tiedB, tiedA] {
            clock.advance(by: 1)
            _ = try await store.perform(.setNotePinned(note.id, true, expectedRevision: 1), in: g)
        }
        #expect(try await store.read(.notes, in: g).map(\.id) == [newer.id] + ordered(tiedA, tiedB) + [unpinned.id])

        clock.advance(by: 1)
        for note in [tiedA, tiedB] { _ = try await store.perform(.archiveNote(note.id, expectedRevision: 2), in: g) }
        clock.advance(by: 1)
        _ = try await store.perform(.archiveNote(unpinned.id, expectedRevision: 1), in: g)
        #expect(try await store.read(.archivedNotes, in: g).map(\.id) == [unpinned.id] + ordered(tiedA, tiedB))
        await store.close()
    }

    @Test func archiveHidesAndRestoreReturnsTheNoteWithBodyPinAndContentEditedTimeIntact() async throws {
        let fixture = try TemporaryFixture()
        let clock = FixedClock(Self.start)
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let g = store.generation
        let older = try await store.perform(.createNote(operation: UUID(), body: "Older\n"), in: g)
        clock.advance(by: 1)
        let created = try await store.perform(.createNote(operation: UUID(), body: "Keep *me*\n"), in: g)
        clock.advance(by: 1)
        let pinned = try await store.perform(.setNotePinned(created.id, true, expectedRevision: 1), in: g)

        clock.advance(by: 10)
        let archived = try await store.perform(.archiveNote(created.id, expectedRevision: 2), in: g)
        #expect(archived.archivedAt == Self.start + 12)
        #expect(archived.updatedAt == Self.start + 12 && archived.revision == 3)
        #expect(archived.body == "Keep *me*\n" && archived.isPinned)
        #expect(archived.contentEditedAt == created.contentEditedAt && archived.createdAt == created.createdAt)
        #expect(try await store.read(.notes, in: g) == [older])
        #expect(try await store.read(.note(created.id), in: g) == archived)

        clock.advance(by: 1)
        let archivedOlder = try await store.perform(.archiveNote(older.id, expectedRevision: 1), in: g)
        // Archive: most recently archived first.
        #expect(try await store.read(.archivedNotes, in: g) == [archivedOlder, archived])

        // Restore before editing body or pin; refusals change nothing.
        await #expect(throws: CollectionStoreError.archivedNote) {
            try await store.perform(.editNote(created.id, expectedRevision: 3, body: "Changed"), in: g)
        }
        for pinned in [false, true] {
            await #expect(throws: CollectionStoreError.archivedNote) {
                try await store.perform(.setNotePinned(created.id, pinned, expectedRevision: 3), in: g)
            }
        }
        await #expect(throws: CollectionStoreError.archivedNote) {
            try await store.perform(.editNote(created.id, expectedRevision: 3, body: "Keep *me*\n"), in: g)
        }
        #expect(try await store.read(.note(created.id), in: g) == archived)

        clock.advance(by: 1)
        let restored = try await store.perform(.restoreNote(created.id, expectedRevision: 3), in: g)
        #expect(restored.archivedAt == nil && restored.revision == 4 && restored.updatedAt == Self.start + 14)
        #expect(restored.body == pinned.body && restored.isPinned && restored.contentEditedAt == created.contentEditedAt)
        #expect(restored.createdAt == created.createdAt)
        #expect(try await store.read(.notes, in: g) == [restored])
        #expect(try await store.read(.archivedNotes, in: g) == [archivedOlder])
        await store.close()

        let reopened = try await CollectionStore.open(fixture.location)
        #expect(try await reopened.read(.notes, in: reopened.generation) == [restored])
        #expect(try await reopened.read(.archivedNotes, in: reopened.generation) == [archivedOlder])
        await reopened.close()
    }

    @Test func alreadySatisfiedCommandsAreNoOpsButStaleOrInvalidOnesFailWithoutChange() async throws {
        let fixture = try TemporaryFixture()
        let clock = FixedClock(Self.start)
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let g = store.generation
        let body = "Cafe\u{301}\n"
        let note = try await store.perform(.createNote(operation: UUID(), body: body), in: g)
        clock.advance(by: 5)

        // Current and already satisfied: nothing changes, not even updated time.
        #expect(try await store.perform(.editNote(note.id, expectedRevision: 1, body: body), in: g) == note)
        #expect(try await store.perform(.setNotePinned(note.id, false, expectedRevision: 1), in: g) == note)
        #expect(try await store.perform(.restoreNote(note.id, expectedRevision: 1), in: g) == note)
        let archived = try await store.perform(.archiveNote(note.id, expectedRevision: 1), in: g)
        clock.advance(by: 5)
        #expect(try await store.perform(.archiveNote(note.id, expectedRevision: 2), in: g) == archived)
        let restored = try await store.perform(.restoreNote(note.id, expectedRevision: 2), in: g)
        #expect(restored.revision == 3)

        // A stale precondition fails even when the requested state already holds.
        for command: CollectionCommand<Note> in [
            .editNote(note.id, expectedRevision: 1, body: body), .editNote(note.id, expectedRevision: 4, body: "Ahead"),
            .setNotePinned(note.id, false, expectedRevision: 2), .restoreNote(note.id, expectedRevision: 1),
            .archiveNote(note.id, expectedRevision: 2),
        ] {
            await #expect(throws: CollectionStoreError.staleRevision) { try await store.perform(command, in: g) }
        }
        await #expect(throws: CollectionStoreError.blankNote) {
            try await store.perform(.editNote(note.id, expectedRevision: 3, body: " \r\n\t\u{2029}"), in: g)
        }
        let missing = UUID()
        for command: CollectionCommand<Note> in [
            .editNote(missing, expectedRevision: 1, body: "x"), .setNotePinned(missing, true, expectedRevision: 1),
            .archiveNote(missing, expectedRevision: 1), .restoreNote(missing, expectedRevision: 1),
        ] {
            await #expect(throws: CollectionStoreError.noteNotFound) { try await store.perform(command, in: g) }
        }
        #expect(try await store.read(.notes, in: g) == [restored])

        // A canonically equal but byte-different body is a real content edit.
        let recomposed = try await store.perform(.editNote(note.id, expectedRevision: 3, body: "Café\n"), in: g)
        #expect(recomposed.revision == 4 && recomposed.contentEditedAt == Self.start + 10)
        #expect(Array(recomposed.body.utf8) == Array("Café\n".utf8))
        await store.close()
    }

    @Test func competingCommandsOnOneRevisionLetExactlyOneWinAndNeverOverwriteIt() async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        let g = store.generation
        let note = try await store.perform(.createNote(operation: UUID(), body: "Base"), in: g)
        let commands: [CollectionCommand<Note>] = (0..<12).map { .editNote(note.id, expectedRevision: 1, body: "Edit \($0)") }
            + [.archiveNote(note.id, expectedRevision: 1), .setNotePinned(note.id, true, expectedRevision: 1)]
        let outcomes = await withTaskGroup(of: Result<Note, any Error>.self) { group in
            for command in commands {
                group.addTask { await Result { try await store.perform(command, in: g) } }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        let winners = outcomes.compactMap { try? $0.get() }
        #expect(winners.count == 1)
        let failures = outcomes.compactMap { $0.failure as? CollectionStoreError }
        #expect(failures == Array(repeating: .staleRevision, count: commands.count - 1))
        let winner = try #require(winners.first)
        #expect(winner.revision == 2)
        #expect(try await store.read(.note(note.id), in: g) == winner)

        // A late edit carrying a replaced revision cannot undo a later archive.
        let archived = try await store.perform(.archiveNote(note.id, expectedRevision: 2), in: g)
        for revision: Int64 in [1, 2] {
            await #expect(throws: CollectionStoreError.staleRevision) {
                try await store.perform(.editNote(note.id, expectedRevision: revision, body: "Late"), in: g)
            }
        }
        #expect(try await store.read(.note(note.id), in: g) == archived)
        await store.close()
    }
}

extension NoteOrganizationTests {
    @Test func failedTransitionsRollBackAndOldGenerationsCannotChangeNotes() async throws {
        let fixture = try TemporaryFixture()
        let clock = FixedClock(Self.start)
        let inject = Switch(), violate = Switch()
        let store = try await CollectionStore.open(fixture.location, clock: clock.now, faults: .init(beforeCommit: { db in
            if inject.take() { throw InjectedFailure() }
            // A real SQLite CHECK failure after the command's own statements.
            if violate.take() { try db.execute(sql: "UPDATE note SET revision = 0") }
        }))
        let g = store.generation
        let pinned = try await store.perform(.setNotePinned(
            try await store.perform(.createNote(operation: UUID(), body: "Stable"), in: g).id, true, expectedRevision: 1), in: g)
        let archived = try await store.perform(.archiveNote(
            try await store.perform(.createNote(operation: UUID(), body: "Hidden"), in: g).id, expectedRevision: 1), in: g)
        clock.advance(by: 60)
        let attempts: [CollectionCommand<Note>] = [
            .editNote(pinned.id, expectedRevision: 2, body: "Lost edit"), .setNotePinned(pinned.id, false, expectedRevision: 2),
            .archiveNote(pinned.id, expectedRevision: 2), .restoreNote(archived.id, expectedRevision: 2),
        ]
        for command in attempts {
            inject.set()
            await #expect(throws: InjectedFailure.self) { try await store.perform(command, in: g) }
            violate.set()
            await #expect(throws: CollectionStoreError.storageFailure(code: 19)) { try await store.perform(command, in: g) }
            #expect(try await store.read(.notes, in: g) == [pinned])
            #expect(try await store.read(.archivedNotes, in: g) == [archived])
        }
        await store.close()

        let reopened = try await CollectionStore.open(fixture.location)
        for command in attempts {
            await #expect(throws: CollectionStoreError.staleGeneration) { try await reopened.perform(command, in: g) }
        }
        #expect(try await reopened.read(.notes, in: reopened.generation) == [pinned])
        #expect(try await reopened.read(.archivedNotes, in: reopened.generation) == [archived])
        // Nothing was consumed: the edit and the restore still apply once, now.
        let edited = try await reopened.perform(attempts[0], in: reopened.generation)
        let restored = try await reopened.perform(attempts[3], in: reopened.generation)
        #expect(edited.body == "Lost edit" && edited.revision == 3 && restored.archivedAt == nil)
        await #expect(throws: CollectionStoreError.staleRevision) {
            try await reopened.perform(attempts[0], in: reopened.generation)
        }
        await reopened.close()
    }
}

extension NoteOrganizationTests {
    @Test func allRecordsAndTheSearchProjectionCoverArchivedNotesOnlyWhenEligible() async throws {
        let fixture = try TemporaryFixture()
        let clock = FixedClock(Self.start)
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let g = store.generation
        let empty = try await store.read(.allRecords, in: g)
        #expect(empty.notes.isEmpty)

        let plain = try await store.perform(.createNote(operation: UUID(), body: "\n  Groceries  \nmilk\n"), in: g)
        let pinned = try await store.perform(.setNotePinned(
            try await store.perform(.createNote(operation: UUID(), body: "บันทึก Thai"), in: g).id, true, expectedRevision: 1), in: g)
        let hidden = try await store.perform(.archiveNote(
            try await store.perform(.createNote(operation: UUID(), body: "Old idea\n- detail"), in: g).id, expectedRevision: 1), in: g)

        let records = try await store.read(.allRecords, in: g)
        #expect(records.collectionID == empty.collectionID)
        #expect(records.notes == [plain, pinned, hidden].sorted { $0.id.uuidString < $1.id.uuidString })

        let active = try await store.read(.noteSearchEntries(), in: g)
        #expect(active == [
            NoteSearchEntry(id: plain.id, title: "Groceries", text: "\n  Groceries  \nmilk\n", isArchived: false),
            NoteSearchEntry(id: pinned.id, title: "บันทึก Thai", text: "บันทึก Thai", isArchived: false),
        ].sorted { $0.id.uuidString < $1.id.uuidString })
        let eligible = try await store.read(.noteSearchEntries(includingArchived: true), in: g)
        #expect(eligible.count == 3)
        #expect(eligible.first { $0.id == hidden.id } == NoteSearchEntry(id: hidden.id, title: "Old idea", text: "Old idea\n- detail",
                                                                          isArchived: true))
        await store.close()

        let reopened = try await CollectionStore.open(fixture.location)
        #expect(try await reopened.read(.allRecords, in: reopened.generation) == records)
        await reopened.close()
        let other = try TemporaryFixture()
        let otherStore = try await CollectionStore.open(other.location)
        #expect(try await otherStore.read(.allRecords, in: otherStore.generation).collectionID != records.collectionID)
        await otherStore.close()
    }
}

extension NoteOrganizationTests {
    @Test func observationsFollowCommittedTransitionsAndNeverShowRolledBackOnes() async throws {
        let fixture = try TemporaryFixture()
        let clock = FixedClock(Self.start)
        let failNext = Switch()
        let store = try await CollectionStore.open(fixture.location, clock: clock.now, faults: .init(beforeCommit: { _ in
            if failNext.take() { throw InjectedFailure() }
        }))
        let g = store.generation
        let other = try await store.perform(.createNote(operation: UUID(), body: "Other"), in: g)
        clock.advance(by: 1)
        let note = try await store.perform(.createNote(operation: UUID(), body: "Watched"), in: g)
        var notes = store.observe(.notes, in: g).makeAsyncIterator()
        var archive = store.observe(.archivedNotes, in: g).makeAsyncIterator()
        var search = store.observe(.noteSearchEntries(), in: g).makeAsyncIterator()

        var committedNotes = [try await store.read(.notes, in: g)]
        var committedArchives = [try await store.read(.archivedNotes, in: g)]
        var committedSearch = [try await store.read(.noteSearchEntries(), in: g)]
        #expect(try await notes.next() == committedNotes[0])
        #expect(try await archive.next() == [])
        #expect(try await search.next() == committedSearch[0])
        // Each command first fails before commit, then commits.
        for command: CollectionCommand<Note> in [
            .editNote(note.id, expectedRevision: 1, body: "Watched, edited"), .setNotePinned(note.id, true, expectedRevision: 2),
            .archiveNote(note.id, expectedRevision: 3), .restoreNote(note.id, expectedRevision: 4),
            .archiveNote(other.id, expectedRevision: 1),
        ] {
            clock.advance(by: 1)
            failNext.set()
            await #expect(throws: InjectedFailure.self) { try await store.perform(command, in: g) }
            _ = try await store.perform(command, in: g)
            committedNotes.append(try await store.read(.notes, in: g))
            committedArchives.append(try await store.read(.archivedNotes, in: g))
            committedSearch.append(try await store.read(.noteSearchEntries(), in: g))
        }
        let latest = try #require(committedNotes.last?.first)
        #expect(committedNotes.last == [latest] && latest.body == "Watched, edited" && latest.isPinned && latest.revision == 5)
        #expect(committedArchives.last?.map(\.id) == [other.id])
        #expect(committedSearch.last == [NoteSearchEntry(id: note.id, title: "Watched, edited", text: "Watched, edited", isArchived: false)])

        // Intermediate commits may coalesce; every value is committed and the
        // latest is eventually observed.
        while let value = try await notes.next() {
            #expect(committedNotes.contains(value))
            if value == committedNotes.last { break }
        }
        while let value = try await archive.next() {
            #expect(committedArchives.contains(value))
            if value == committedArchives.last { break }
        }
        while let value = try await search.next() {
            #expect(committedSearch.contains(value))
            if value == committedSearch.last { break }
        }
        await store.close()
    }
}

private extension Result {
    init(catching body: () async throws(Failure) -> Success) async {
        do { self = .success(try await body()) } catch { self = .failure(error) }
    }
    var failure: Failure? { if case .failure(let error) = self { error } else { nil } }
}
