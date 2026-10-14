import Foundation
import Testing
@testable import Hana

/// A collection built through the Store that covers every organization fact:
/// pins, note archive, manual Inbox/Today order (including a renumbered list),
/// and every completion/archive combination with reopen and restore. Later
/// export and snapshot tests compare against `views` and `records`.
struct OrganizedCollection {
    /// Every committed query result a comparison needs, from one store state.
    struct Views: Equatable {
        let records: CollectionRecords
        let notes: [Note]
        let archivedNotes: [Note]
        let inbox: [TaskItem]
        let today: [TaskItem]
        let completed: [TaskItem]
        let archivedTasks: [TaskItem]
    }

    let views: Views

    static func views(of store: CollectionStore) async throws -> Views {
        let g = store.generation
        return Views(records: try await store.read(.allRecords, in: g), notes: try await store.read(.notes, in: g),
                     archivedNotes: try await store.read(.archivedNotes, in: g), inbox: try await store.read(.inbox, in: g),
                     today: try await store.read(.today, in: g), completed: try await store.read(.completedTasks, in: g),
                     archivedTasks: try await store.read(.archivedTasks, in: g))
    }

    /// Builds the collection in `store`, advancing `clock` between steps so
    /// every timestamp-ordered view has distinct and tied times.
    static func build(in store: CollectionStore, clock: FixedClock) async throws -> OrganizedCollection {
        let g = store.generation
        func tick() { clock.advance(by: 1) }
        func note(_ body: String) async throws -> Note {
            tick()
            return try await store.perform(.createNote(operation: UUID(), body: body), in: g)
        }
        func task(_ title: String, _ placement: TaskPlacement = .inbox) async throws -> TaskItem {
            tick()
            return try await store.perform(.createTask(operation: UUID(), title: title, placement: placement), in: g)
        }

        // Notes: exact Unicode/Markdown, repeated and path-like titles, pinned and archived combinations.
        _ = try await note("# ซื้อของ Thai\r\n- [ ] นม é (e\u{301}) 🌸  \n")
        let repeatedA = try await note("Same title\nfirst body")
        _ = try await note("Same title\nsecond body")
        _ = try await note("\n\n  ../../etc/passwd: \"quoted\" <tag> \\back\n")
        let pinned = try await note("Pinned note")
        let archivedPinned = try await note("Archived but pinned")
        let archivedPlain = try await note("Archived plain")
        tick()
        _ = try await store.perform(.setNotePinned(pinned.id, true, expectedRevision: pinned.revision), in: g)
        let pinnedBeforeArchive = try await store.perform(.setNotePinned(archivedPinned.id, true, expectedRevision: 1), in: g)
        tick()
        _ = try await store.perform(.editNote(repeatedA.id, expectedRevision: 1, body: "Same title\nfirst body, edited"), in: g)
        tick()
        _ = try await store.perform(.archiveNote(archivedPinned.id, expectedRevision: pinnedBeforeArchive.revision), in: g)
        _ = try await store.perform(.archiveNote(archivedPlain.id, expectedRevision: 1), in: g)

        // Inbox: manual order, then a list renumbered by a move between neighbours.
        var inbox: [TaskItem] = []
        for title in ["Inbox ก", "Inbox ข", "Inbox ค", "Inbox ง"] { inbox.append(try await task(title)) }
        tick()
        var order = try await store.read(.inbox, in: g).map(\.id)
        _ = try await store.perform(.reorderTask(inbox[0].id, in: .inbox, after: inbox[2].id, expectedOrder: order), in: g)
        order = try await store.read(.inbox, in: g).map(\.id)
        _ = try await store.perform(.reorderTask(inbox[3].id, in: .inbox, after: inbox[0].id, expectedOrder: order), in: g)

        // Today: manual order independent of Inbox, plus a task moved in.
        let today = [try await task("Today 1", .today), try await task("Today 2", .today)]
        tick()
        _ = try await store.perform(.reorderTask(today[1].id, in: .today, after: today[0].id,
                                                 expectedOrder: try await store.read(.today, in: g).map(\.id)), in: g)
        let movedIn = try await task("Moved to Today")
        tick()
        _ = try await store.perform(.moveTask(movedIn.id, to: .today, expectedRevision: 1), in: g)

        // Every completion/archive combination, two completions tied in time.
        let doneA = try await task("Done A"), doneB = try await task("Done B")
        let hiddenOpen = try await task("Archived unfinished"), hiddenDone = try await task("Archived completed")
        let reopened = try await task("Reopened"), restoredOpen = try await task("Restored unfinished")
        let restoredDone = try await task("Restored completed", .today)
        tick()
        for item in [doneA, doneB, hiddenDone, reopened, restoredDone] {
            _ = try await store.perform(.completeTask(item.id, expectedRevision: 1), in: g)
        }
        tick()
        _ = try await store.perform(.archiveTask(hiddenOpen.id, expectedRevision: 1), in: g)
        _ = try await store.perform(.archiveTask(hiddenDone.id, expectedRevision: 2), in: g)
        _ = try await store.perform(.archiveTask(restoredOpen.id, expectedRevision: 1), in: g)
        _ = try await store.perform(.archiveTask(restoredDone.id, expectedRevision: 2), in: g)
        tick()
        _ = try await store.perform(.reopenTask(reopened.id, expectedRevision: 2), in: g)
        _ = try await store.perform(.restoreTask(restoredOpen.id, expectedRevision: 2), in: g)
        _ = try await store.perform(.restoreTask(restoredDone.id, expectedRevision: 3), in: g)
        tick()
        _ = try await store.perform(.editTaskTitle(doneB.id, expectedRevision: 2, title: "Done B, renamed"), in: g)

        return OrganizedCollection(views: try await views(of: store))
    }
}

@Suite(.timeLimit(.minutes(1)))
struct OrganizedCollectionFixtureTests {
    @Test func theFixtureCoversEveryOrganizationFactAndSurvivesRestart() async throws {
        let fixture = try TemporaryFixture()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000.250))
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let built = try await OrganizedCollection.build(in: store, clock: clock)
        await store.close()
        let views = built.views

        func titles(_ tasks: [TaskItem]) -> [String] { tasks.map(\.title) }
        #expect(views.records.notes.count == 7 && views.records.tasks.count == 14)
        #expect(views.notes.map(\.isPinned) == [true, false, false, false, false])
        #expect(views.archivedNotes.count == 2 && Set(views.archivedNotes.map(\.isPinned)) == [false, true])
        #expect(titles(views.inbox) == ["Restored unfinished", "Reopened", "Inbox ค", "Inbox ก", "Inbox ง", "Inbox ข"])
        #expect(titles(views.today) == ["Moved to Today", "Today 1", "Today 2"])
        #expect(Set(titles(views.completed)) == ["Restored completed", "Done A", "Done B, renamed"])
        #expect(Set(titles(views.archivedTasks)) == ["Archived unfinished", "Archived completed"])
        let combinations = Set(views.records.tasks.map { [$0.completedAt != nil, $0.archivedAt != nil] })
        #expect(combinations == [[false, false], [true, false], [false, true], [true, true]])
        // Inbox was renumbered by a move between neighbours; its keys are still strictly ascending.
        let keys = views.inbox.compactMap(\.orderKey)
        #expect(keys.count == views.inbox.count && zip(keys, keys.dropFirst()).allSatisfy { $0 < $1 })

        let reopened = try await CollectionStore.open(fixture.location)
        #expect(try await OrganizedCollection.views(of: reopened) == views)
        await reopened.close()
    }
}
