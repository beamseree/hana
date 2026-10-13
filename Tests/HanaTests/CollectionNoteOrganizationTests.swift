import CryptoKit
import Foundation
import Testing
@testable import Hana

/// Issue #25: editing, pinning, archiving and restoring saved notes through
/// the production Store on real temporary SQLite.
@Suite(.timeLimit(.minutes(1)))
struct CollectionNoteOrganizationTests {
    @Test func editKeepsExactBytesAndCreationTimeAndAdvancesContentEditedTime() async throws {
        let fixture = try TemporaryFixture()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000))
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let created = try await store.perform(.createNote(operation: UUID(), body: "First draft"), in: store.generation)
        clock.advance(by: 5)
        let body = "\r\n \t\n  Thai บันทึก é (e\u{301}) 🌸 \n# Heading *kept*\u{2029}tail\0end  "
        let edited = try await store.perform(.editNote(created.id, expectedRevision: 1, body: body), in: store.generation)
        #expect(Array(edited.body.utf8) == Array(body.utf8))
        #expect(edited.title == "Thai บันทึก é (e\u{301}) 🌸")
        #expect(edited.revision == 2)
        #expect(edited.createdAt == created.createdAt)
        #expect(edited.contentEditedAt == Date(timeIntervalSince1970: 1_800_000_005))
        #expect(edited.updatedAt == edited.contentEditedAt)
        #expect(!edited.isPinned && edited.archivedAt == nil)

        // A canonically equal but byte-different body is a real edit.
        let composed = try await store.perform(.editNote(created.id, expectedRevision: 2, body: "Caf\u{E9}"), in: store.generation)
        clock.advance(by: 1)
        let decomposed = try await store.perform(.editNote(created.id, expectedRevision: 3, body: "Cafe\u{301}"), in: store.generation)
        #expect(decomposed.revision == composed.revision + 1)
        #expect(Array(decomposed.body.utf8) == Array("Cafe\u{301}".utf8))

        await #expect(throws: CollectionStoreError.blankNote) {
            try await store.perform(.editNote(created.id, expectedRevision: 4, body: " \n\t\u{2028}"), in: store.generation)
        }
        await #expect(throws: CollectionStoreError.notFound) {
            try await store.perform(.editNote(UUID(), expectedRevision: 1, body: "Nobody"), in: store.generation)
        }
        #expect(try await store.read(.note(created.id), in: store.generation) == decomposed)
        await store.close()

        let reopened = try await CollectionStore.open(fixture.location)
        let read = try #require(try await reopened.read(.note(created.id), in: reopened.generation))
        #expect(read == decomposed)
        await reopened.close()
    }

    @Test func pinsSortFirstWithoutPretendingTheWritingChanged() async throws {
        let fixture = try TemporaryFixture()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000))
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let g = store.generation
        var notes: [Note] = []
        for index in 0..<3 {
            notes.append(try await store.perform(.createNote(operation: UUID(), body: "Note \(index)"), in: g))
            clock.advance(by: 1)
        }
        // Newest content edit first.
        #expect(try await store.read(.notes, in: g).map(\.id) == notes.reversed().map(\.id))

        let pinned = try await store.perform(.setNotePinned(notes[0].id, true, expectedRevision: 1), in: g)
        #expect(pinned.isPinned && pinned.revision == 2)
        #expect(pinned.contentEditedAt == notes[0].contentEditedAt)
        #expect(pinned.updatedAt == clock.now())
        #expect(try await store.read(.notes, in: g).map(\.id) == [notes[0].id, notes[2].id, notes[1].id])

        // Editing the oldest unpinned note brings it to the top of the unpinned notes.
        clock.advance(by: 1)
        _ = try await store.perform(.editNote(notes[1].id, expectedRevision: 1, body: "Note 1, edited"), in: g)
        #expect(try await store.read(.notes, in: g).map(\.id) == [notes[0].id, notes[1].id, notes[2].id])

        let unpinned = try await store.perform(.setNotePinned(notes[0].id, false, expectedRevision: 2), in: g)
        #expect(!unpinned.isPinned && unpinned.revision == 3 && unpinned.contentEditedAt == notes[0].contentEditedAt)
        #expect(try await store.read(.notes, in: g).map(\.id) == [notes[1].id, notes[2].id, notes[0].id])
        await store.close()
    }

    @Test func equalContentEditedTimesSortByStableID() async throws {
        let fixture = try TemporaryFixture()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000))
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        var ids: [UUID] = []
        for index in 0..<6 {
            ids.append(try await store.perform(.createNote(operation: UUID(), body: "Same time \(index)"), in: store.generation).id)
        }
        let byID = ids.sorted { $0.uuidString < $1.uuidString }
        #expect(try await store.read(.notes, in: store.generation).map(\.id) == byID)
        let second = try await store.perform(.setNotePinned(byID[4], true, expectedRevision: 1), in: store.generation)
        let first = try await store.perform(.setNotePinned(byID[2], true, expectedRevision: 1), in: store.generation)
        let expected = [first.id, second.id] + byID.filter { $0 != first.id && $0 != second.id }
        #expect(try await store.read(.notes, in: store.generation).map(\.id) == expected)
        await store.close()
    }

    @Test func archiveAndRestorePreserveBodyPinAndContentEditedTime() async throws {
        let fixture = try TemporaryFixture()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000))
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let g = store.generation
        let body = "Archive me\n- [ ] Markdown"
        let note = try await store.perform(.createNote(operation: UUID(), body: body), in: g)
        let other = try await store.perform(.createNote(operation: UUID(), body: "Stay"), in: g)
        clock.advance(by: 1)
        let pinned = try await store.perform(.setNotePinned(note.id, true, expectedRevision: 1), in: g)
        clock.advance(by: 1)
        let archived = try await store.perform(.archiveNote(note.id, expectedRevision: 2), in: g)
        #expect(archived.archivedAt == clock.now() && archived.updatedAt == clock.now())
        #expect(archived.revision == 3 && archived.isPinned)
        #expect(Array(archived.body.utf8) == Array(body.utf8))
        #expect(archived.contentEditedAt == note.contentEditedAt && archived.createdAt == note.createdAt)

        // Hidden from Notes, readable by ID, listed in Archive and all records.
        #expect(try await store.read(.notes, in: g) == [other])
        #expect(try await store.read(.note(note.id), in: g) == archived)
        #expect(try await store.read(.archivedNotes, in: g) == [archived])
        let all = try await store.read(.allNotes, in: g)
        #expect(Set(all.map(\.id)) == [note.id, other.id])

        // Restore before editing the body or the pin.
        await #expect(throws: CollectionStoreError.archived) {
            try await store.perform(.editNote(note.id, expectedRevision: 3, body: "Hidden edit"), in: g)
        }
        await #expect(throws: CollectionStoreError.archived) {
            try await store.perform(.setNotePinned(note.id, false, expectedRevision: 3), in: g)
        }
        #expect(try await store.read(.note(note.id), in: g) == archived)

        clock.advance(by: 1)
        let restored = try await store.perform(.restoreNote(note.id, expectedRevision: 3), in: g)
        #expect(restored.archivedAt == nil && restored.revision == 4 && restored.isPinned)
        #expect(restored.updatedAt == clock.now())
        #expect(restored.contentEditedAt == pinned.contentEditedAt)
        #expect(Array(restored.body.utf8) == Array(body.utf8))
        #expect(try await store.read(.notes, in: g) == [restored, other])
        #expect(try await store.read(.archivedNotes, in: g).isEmpty)
        await store.close()

        let reopened = try await CollectionStore.open(fixture.location)
        #expect(try await reopened.read(.notes, in: reopened.generation) == [restored, other])
        await reopened.close()
    }

    @Test func archiveListsMostRecentlyArchivedFirst() async throws {
        let fixture = try TemporaryFixture()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000))
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let g = store.generation
        let a = try await store.perform(.createNote(operation: UUID(), body: "A"), in: g)
        let b = try await store.perform(.createNote(operation: UUID(), body: "B"), in: g)
        clock.advance(by: 1)
        let archivedB = try await store.perform(.archiveNote(b.id, expectedRevision: 1), in: g)
        clock.advance(by: 1)
        let archivedA = try await store.perform(.archiveNote(a.id, expectedRevision: 1), in: g)
        #expect(try await store.read(.archivedNotes, in: g) == [archivedA, archivedB])
        #expect(try await store.read(.notes, in: g).isEmpty)
        await store.close()
    }

    @Test func satisfiedCommandsAreNoOpsButStalePreconditionsStillFail() async throws {
        let fixture = try TemporaryFixture()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000))
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let g = store.generation
        let note = try await store.perform(.createNote(operation: UUID(), body: "Unchanged"), in: g)
        clock.advance(by: 1)

        #expect(try await store.perform(.editNote(note.id, expectedRevision: 1, body: "Unchanged"), in: g) == note)
        #expect(try await store.perform(.setNotePinned(note.id, false, expectedRevision: 1), in: g) == note)
        #expect(try await store.perform(.restoreNote(note.id, expectedRevision: 1), in: g) == note)
        let archived = try await store.perform(.archiveNote(note.id, expectedRevision: 1), in: g)
        clock.advance(by: 1)
        #expect(try await store.perform(.archiveNote(note.id, expectedRevision: 2), in: g) == archived)

        // Already satisfied, but at an obsolete revision: refused.
        await #expect(throws: CollectionStoreError.staleRevision) {
            try await store.perform(.archiveNote(note.id, expectedRevision: 1), in: g)
        }
        await #expect(throws: CollectionStoreError.staleRevision) {
            try await store.perform(.restoreNote(note.id, expectedRevision: 1), in: g)
        }
        let restored = try await store.perform(.restoreNote(note.id, expectedRevision: 2), in: g)
        await #expect(throws: CollectionStoreError.staleRevision) {
            try await store.perform(.editNote(note.id, expectedRevision: 1, body: "Unchanged"), in: g)
        }
        await #expect(throws: CollectionStoreError.staleRevision) {
            try await store.perform(.setNotePinned(note.id, false, expectedRevision: 2), in: g)
        }
        #expect(try await store.read(.note(note.id), in: g) == restored)
        await store.close()
    }

    @Test func competingEditAndArchiveCannotOverwriteEachOther() async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        let g = store.generation
        for round in 0..<10 {
            let note = try await store.perform(.createNote(operation: UUID(), body: "Round \(round)"), in: g)
            async let edit = outcome { try await store.perform(.editNote(note.id, expectedRevision: 1, body: "Edited \(round)"), in: g) }
            async let archive = outcome { try await store.perform(.archiveNote(note.id, expectedRevision: 1), in: g) }
            let outcomes = await [edit, archive]
            let winners = outcomes.compactMap { try? $0.get() }
            #expect(winners.count == 1, "exactly one competing command commits")
            for case .failure(let error) in outcomes {
                #expect(error as? CollectionStoreError == .staleRevision)
            }
            let winner = try #require(winners.first)
            #expect(try await store.read(.note(note.id), in: g) == winner)
            #expect(winner.revision == 2)
            // The loser's effect is absent: either edited and active, or archived with the original body.
            if winner.archivedAt == nil {
                #expect(winner.body == "Edited \(round)")
            } else {
                #expect(winner.body == "Round \(round)")
            }
        }
        await store.close()
    }

    @Test func failedCommandsRollBackAndStaleGenerationsAreRejected() async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        let note = try await store.perform(.createNote(operation: UUID(), body: "Original"), in: store.generation)
        let staleGeneration = store.generation
        await store.close()

        let failNext = Switch()
        let failing = try await CollectionStore.open(fixture.location, faults: .init(beforeCommit: { _ in
            if failNext.take() { throw InjectedFailure() }
        }))
        let commands: [CollectionCommand<Note>] = [
            .editNote(note.id, expectedRevision: 1, body: "Never committed"),
            .setNotePinned(note.id, true, expectedRevision: 1),
            .archiveNote(note.id, expectedRevision: 1),
        ]
        for command in commands {
            failNext.set()
            await #expect(throws: InjectedFailure.self) { try await failing.perform(command, in: failing.generation) }
            #expect(try await failing.read(.note(note.id), in: failing.generation) == note)
        }
        await #expect(throws: CollectionStoreError.staleGeneration) {
            try await failing.perform(.editNote(note.id, expectedRevision: 1, body: "Stale"), in: staleGeneration)
        }
        #expect(try await failing.read(.allNotes, in: failing.generation) == [note])
        await failing.close()
    }

    @Test func observationsFollowEditsPinsAndArchive() async throws {
        let fixture = try TemporaryFixture()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000))
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let g = store.generation
        let a = try await store.perform(.createNote(operation: UUID(), body: "A"), in: g)
        clock.advance(by: 1)
        let b = try await store.perform(.createNote(operation: UUID(), body: "B"), in: g)
        var notes = store.observe(.notes, in: g).makeAsyncIterator()
        var archive = store.observe(.archivedNotes, in: g).makeAsyncIterator()
        #expect(try await notes.next() == [b, a])
        #expect(try await archive.next() == [])

        clock.advance(by: 1)
        let edited = try await store.perform(.editNote(a.id, expectedRevision: 1, body: "A, edited"), in: g)
        let pinned = try await store.perform(.setNotePinned(b.id, true, expectedRevision: 1), in: g)
        let archived = try await store.perform(.archiveNote(edited.id, expectedRevision: 2), in: g)

        let committed: [[Note]] = [[b, a], [edited, b], [pinned, edited], [pinned]]
        while let value = try await notes.next() {
            #expect(committed.contains(value))
            if value == [pinned] { break }
        }
        while let value = try await archive.next() {
            #expect(value == [] || value == [archived])
            if value == [archived] { break }
        }
        await store.close()
    }

    @Test func searchTextProjectsCommittedNotesAndExcludesArchiveByDefault() async throws {
        let fixture = try TemporaryFixture()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000))
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let g = store.generation
        let kept = try await store.perform(.createNote(operation: UUID(), body: "\n  Groceries  \nmilk"), in: g)
        clock.advance(by: 1)
        let hidden = try await store.perform(.createNote(operation: UUID(), body: "Old plans"), in: g)
        let archived = try await store.perform(.archiveNote(hidden.id, expectedRevision: 1), in: g)

        let defaults = try await store.read(.searchText(), in: g)
        #expect(defaults == [OwnedItemText(kind: .note, id: kept.id, title: "Groceries", text: kept.body,
                                           isArchived: false, isCompleted: false, contentEditedAt: kept.contentEditedAt)])
        let everything = try await store.read(.searchText(SearchEligibility(includesArchived: true)), in: g)
        #expect(everything.map(\.id) == [archived.id, kept.id])
        #expect(everything.first?.isArchived == true && everything.first?.title == "Old plans")
        await store.close()
    }
}

/// The result of `body`, success or failure, for racing commands.
func outcome<T: Sendable>(_ body: @Sendable () async throws -> T) async -> Result<T, any Error> {
    do { return .success(try await body()) } catch { return .failure(error) }
}

/// The note organization commands in fresh `Hana --collection-fixture` processes.
@Suite(.timeLimit(.minutes(1)))
struct CollectionNoteHarnessTests {
    @Test func organizeANoteAcrossFreshProcesses() throws {
        let root = try HarnessRoot()
        let created = try Harness.run(["create-note", root.path, "--operation", UUID().uuidString], stdin: "Draft").event("note.created")
        let id = try #require(created["id"] as? String)
        let body = "บันทึก edited\r\n- [x] kept  \n"
        let edited = try Harness.run(["edit-note", root.path, "--id", id, "--revision", "1"], stdin: body).event("note.updated")
        #expect(edited["revision"] as? Int == 2)
        #expect(edited["bodySHA256"] as? String == digest(body))
        #expect(edited["createdAt"] as? Int == created["createdAt"] as? Int)

        let pinned = try Harness.run(["pin-note", root.path, "--id", id, "--revision", "2", "--pinned", "true"]).event("note.updated")
        #expect(pinned["pinned"] as? Bool == true && pinned["revision"] as? Int == 3)
        #expect(pinned["contentEditedAt"] as? Int == edited["contentEditedAt"] as? Int)

        let archived = try Harness.run(["archive-note", root.path, "--id", id, "--revision", "3"]).event("note.updated")
        #expect(archived["archived"] as? Bool == true && archived["revision"] as? Int == 4)
        #expect(try Harness.run(["read", root.path]).event("notes")["count"] as? Int == 0)
        let archive = try Harness.run(["read", root.path, "--view", "archive"]).event("notes")
        #expect((archive["notes"] as? [[String: Any]])?.first?["id"] as? String == id)
        #expect((archive["notes"] as? [[String: Any]])?.first?["bodySHA256"] as? String == digest(body))

        let refused = try Harness.run(["edit-note", root.path, "--id", id, "--revision", "4"], stdin: "While archived")
        #expect(refused.status == 1 && refused.event("error")["error"] as? String == "archived")
        let stale = try Harness.run(["restore-note", root.path, "--id", id, "--revision", "3"])
        #expect(stale.status == 1 && stale.event("error")["error"] as? String == "staleRevision")

        let restored = try Harness.run(["restore-note", root.path, "--id", id, "--revision", "4"]).event("note.updated")
        #expect(restored["archived"] as? Bool == false && restored["pinned"] as? Bool == true)
        let notes = try Harness.run(["read", root.path]).event("notes")
        #expect(notes["count"] as? Int == 1)
        #expect((notes["notes"] as? [[String: Any]])?.first?["revision"] as? Int == 5)
        #expect(try Harness.run(["read", root.path, "--view", "all"]).event("notes")["count"] as? Int == 1)
    }

    @Test(arguments: ["before-commit", "after-commit"])
    func killedEditIsAllOrNone(_ point: String) throws {
        let root = try HarnessRoot()
        let created = try Harness.run(["create-note", root.path, "--operation", UUID().uuidString], stdin: "Original").event("note.created")
        let id = try #require(created["id"] as? String)
        let paused = try Harness.start(["edit-note", root.path, "--id", id, "--revision", "1", "--pause", point], stdin: "Replacement")
        try paused.waitForPause()
        paused.kill()

        let read = try Harness.run(["read", root.path]).event("notes")
        let note = try #require((read["notes"] as? [[String: Any]])?.first)
        #expect(note["bodySHA256"] as? String == digest(point == "after-commit" ? "Replacement" : "Original"))
        #expect(note["revision"] as? Int == (point == "after-commit" ? 2 : 1))

        let failed = try Harness.run(["archive-note", root.path, "--id", id, "--revision", "\(note["revision"] as? Int ?? 0)",
                                      "--fail", "before-commit"])
        #expect(failed.status == 1 && failed.event("error")["error"] as? String == "injectedFailure")
        #expect(try Harness.run(["read", root.path]).event("notes")["count"] as? Int == 1)
    }
}

private func digest(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}
