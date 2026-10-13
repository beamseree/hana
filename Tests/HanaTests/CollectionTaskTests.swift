import CryptoKit
import Foundation
import Testing
@testable import Hana

/// Issue #26: creating tasks and moving them across Inbox, Today, Completed
/// and Archive through the production Store on real temporary SQLite.
@Suite(.timeLimit(.minutes(1)))
struct CollectionTaskTests {
    @Test func newTasksGoToTheTopOfInboxByDefaultOrTodayExplicitly() async throws {
        let fixture = try TemporaryFixture()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000.25))
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let g = store.generation
        let title = "  Thai งาน é (e\u{301}) 🌸 [x] *kept*  "
        let first = try await store.perform(.createTask(operation: UUID(), title: title), in: g)
        #expect(Array(first.title.utf8) == Array(title.utf8))
        #expect(first.placement == .inbox && first.orderKey != nil)
        #expect(first.revision == 1 && first.completedAt == nil && first.archivedAt == nil)
        #expect(first.createdAt == Date(timeIntervalSince1970: 1_800_000_000.25))
        #expect(first.contentEditedAt == first.createdAt && first.updatedAt == first.createdAt)

        clock.advance(by: 1)
        let second = try await store.perform(.createTask(operation: UUID(), title: "Second"), in: g)
        let today = try await store.perform(.createTask(operation: UUID(), title: "Today", placement: .today), in: g)
        let laterToday = try await store.perform(.createTask(operation: UUID(), title: "Later today", placement: .today), in: g)
        #expect(try await store.read(.inbox, in: g) == [second, first])
        #expect(try await store.read(.today, in: g) == [laterToday, today])
        #expect(try await store.read(.task(first.id), in: g) == first)
        await store.close()

        let reopened = try await CollectionStore.open(fixture.location)
        #expect(try await reopened.read(.inbox, in: reopened.generation) == [second, first])
        #expect(try await reopened.read(.today, in: reopened.generation) == [laterToday, today])
        await reopened.close()
    }

    @Test(arguments: ["", " ", "\t \u{3000}", "Two\nlines", "Carriage\rreturn", "Windows\r\nbreak", "Next\u{85}line",
                      "Line\u{2028}separator", "Paragraph\u{2029}separator", "Vertical\u{0B}tab", "Form\u{0C}feed", "Trailing\n"])
    func blankAndMultilineTitlesAreRefusedWithoutFlattening(_ title: String) async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        let g = store.generation
        await #expect(throws: CollectionStoreError.invalidTitle) {
            try await store.perform(.createTask(operation: UUID(), title: title), in: g)
        }
        let task = try await store.perform(.createTask(operation: UUID(), title: "Valid"), in: g)
        await #expect(throws: CollectionStoreError.invalidTitle) {
            try await store.perform(.editTaskTitle(task.id, expectedRevision: 1, title: title), in: g)
        }
        #expect(try await store.read(.allTasks, in: g) == [task])
        await store.close()
    }

    @Test func titleEditsChangeContentTimeAndOrganizationDoesNot() async throws {
        let fixture = try TemporaryFixture()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000))
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let g = store.generation
        let task = try await store.perform(.createTask(operation: UUID(), title: "Draft"), in: g)
        clock.advance(by: 1)
        let edited = try await store.perform(.editTaskTitle(task.id, expectedRevision: 1, title: "Cafe\u{301}"), in: g)
        #expect(edited.revision == 2 && edited.contentEditedAt == clock.now() && edited.updatedAt == clock.now())
        #expect(edited.createdAt == task.createdAt && edited.placement == .inbox && edited.orderKey == task.orderKey)
        // Canonically equal, different bytes: a real edit. Identical bytes: a no-op.
        let composed = try await store.perform(.editTaskTitle(task.id, expectedRevision: 2, title: "Caf\u{E9}"), in: g)
        #expect(composed.revision == 3)
        #expect(try await store.perform(.editTaskTitle(task.id, expectedRevision: 3, title: "Caf\u{E9}"), in: g) == composed)

        clock.advance(by: 1)
        let moved = try await store.perform(.moveTask(task.id, to: .today, expectedRevision: 3), in: g)
        let completed = try await store.perform(.completeTask(task.id, expectedRevision: 4), in: g)
        // Completed tasks keep inline title editing.
        clock.advance(by: 1)
        let renamed = try await store.perform(.editTaskTitle(task.id, expectedRevision: 5, title: "Done thing"), in: g)
        for organized in [moved, completed] {
            #expect(organized.createdAt == task.createdAt && organized.contentEditedAt == composed.contentEditedAt)
        }
        #expect(renamed.isCompleted && renamed.contentEditedAt == clock.now() && renamed.placement == nil)
        await store.close()
    }

    @Test func theLifecycleMatrixFollowsTheAgreedTable() async throws {
        let fixture = try TemporaryFixture()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000))
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let g = store.generation
        let other = try await store.perform(.createTask(operation: UUID(), title: "Other", placement: .today), in: g)
        let task = try await store.perform(.createTask(operation: UUID(), title: "Subject"), in: g)

        // Move Inbox → Today: top of Today, creation time kept.
        clock.advance(by: 1)
        let moved = try await store.perform(.moveTask(task.id, to: .today, expectedRevision: 1), in: g)
        #expect(moved.placement == .today && moved.revision == 2 && moved.updatedAt == clock.now())
        #expect(moved.createdAt == task.createdAt && moved.contentEditedAt == task.contentEditedAt)
        #expect(try await store.read(.today, in: g).map(\.id) == [task.id, other.id])
        #expect(try await store.read(.inbox, in: g).isEmpty)
        // Already in Today: stays where it is.
        #expect(try await store.perform(.moveTask(task.id, to: .today, expectedRevision: 2), in: g) == moved)

        // Complete: completion time, no placement or order, in Completed.
        clock.advance(by: 1)
        let completed = try await store.perform(.completeTask(task.id, expectedRevision: 2), in: g)
        #expect(completed.completedAt == clock.now() && completed.placement == nil && completed.orderKey == nil)
        #expect(try await store.read(.completedTasks, in: g) == [completed])
        #expect(try await store.read(.today, in: g).map(\.id) == [other.id])
        await #expect(throws: CollectionStoreError.completed) {
            try await store.perform(.moveTask(task.id, to: .inbox, expectedRevision: 3), in: g)
        }

        // Reopen: top of Inbox, not the earlier Today placement.
        clock.advance(by: 1)
        let reopened = try await store.perform(.reopenTask(task.id, expectedRevision: 3), in: g)
        #expect(reopened.completedAt == nil && reopened.placement == .inbox && reopened.revision == 4)
        #expect(try await store.read(.inbox, in: g) == [reopened])
        #expect(try await store.read(.completedTasks, in: g).isEmpty)

        // Archive an unfinished task from Today, restore to the top of Inbox.
        let backToToday = try await store.perform(.moveTask(task.id, to: .today, expectedRevision: 4), in: g)
        clock.advance(by: 1)
        let archivedUnfinished = try await store.perform(.archiveTask(task.id, expectedRevision: backToToday.revision), in: g)
        #expect(archivedUnfinished.archivedAt == clock.now() && archivedUnfinished.completedAt == nil)
        #expect(archivedUnfinished.placement == nil && archivedUnfinished.orderKey == nil)
        #expect(try await store.read(.archivedTasks, in: g) == [archivedUnfinished])
        #expect(try await store.read(.today, in: g).map(\.id) == [other.id])
        let inboxTop = try await store.perform(.createTask(operation: UUID(), title: "Inbox top"), in: g)
        let restoredUnfinished = try await store.perform(.restoreTask(task.id, expectedRevision: archivedUnfinished.revision), in: g)
        #expect(restoredUnfinished.archivedAt == nil && restoredUnfinished.placement == .inbox)
        #expect(try await store.read(.inbox, in: g).map(\.id) == [task.id, inboxTop.id])

        // Archive a completed task: completion survives; restore returns it to Completed.
        clock.advance(by: 1)
        let completedAgain = try await store.perform(.completeTask(task.id, expectedRevision: restoredUnfinished.revision), in: g)
        clock.advance(by: 1)
        let archivedCompleted = try await store.perform(.archiveTask(task.id, expectedRevision: completedAgain.revision), in: g)
        #expect(archivedCompleted.completedAt == completedAgain.completedAt && archivedCompleted.archivedAt == clock.now())
        #expect(try await store.read(.completedTasks, in: g).isEmpty)
        clock.advance(by: 1)
        let restoredCompleted = try await store.perform(.restoreTask(task.id, expectedRevision: archivedCompleted.revision), in: g)
        #expect(restoredCompleted.completedAt == completedAgain.completedAt && restoredCompleted.archivedAt == nil)
        #expect(restoredCompleted.placement == nil && restoredCompleted.orderKey == nil)
        #expect(try await store.read(.completedTasks, in: g) == [restoredCompleted])
        #expect(restoredCompleted.createdAt == task.createdAt && restoredCompleted.contentEditedAt == task.contentEditedAt)
        await store.close()
    }

    @Test func archivedTasksMustBeRestoredBeforeAnyChange() async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        let g = store.generation
        let task = try await store.perform(.createTask(operation: UUID(), title: "Archived"), in: g)
        let archived = try await store.perform(.archiveTask(task.id, expectedRevision: 1), in: g)
        let refused: [CollectionCommand<TaskItem>] = [
            .editTaskTitle(task.id, expectedRevision: 2, title: "Changed"),
            .moveTask(task.id, to: .today, expectedRevision: 2),
            .completeTask(task.id, expectedRevision: 2),
            .reopenTask(task.id, expectedRevision: 2),
        ]
        for command in refused {
            await #expect(throws: CollectionStoreError.archived) { try await store.perform(command, in: g) }
        }
        #expect(try await store.read(.task(task.id), in: g) == archived)
        // Already archived: a no-op at the current revision.
        #expect(try await store.perform(.archiveTask(task.id, expectedRevision: 2), in: g) == archived)
        await store.close()
    }

    @Test func everyCompletionAndArchiveCombinationAppearsInExactlyItsViews() async throws {
        let fixture = try TemporaryFixture()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000))
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let g = store.generation
        let unfinished = try await store.perform(.createTask(operation: UUID(), title: "Unfinished", placement: .today), in: g)
        let done = try await store.perform(.createTask(operation: UUID(), title: "Done"), in: g)
        let shelved = try await store.perform(.createTask(operation: UUID(), title: "Shelved"), in: g)
        let doneShelved = try await store.perform(.createTask(operation: UUID(), title: "Done and shelved"), in: g)
        clock.advance(by: 1)
        let completed = try await store.perform(.completeTask(done.id, expectedRevision: 1), in: g)
        let archived = try await store.perform(.archiveTask(shelved.id, expectedRevision: 1), in: g)
        let both = try await store.perform(.completeTask(doneShelved.id, expectedRevision: 1), in: g)
        clock.advance(by: 1)
        let completedArchived = try await store.perform(.archiveTask(doneShelved.id, expectedRevision: both.revision), in: g)

        #expect(try await store.read(.today, in: g) == [unfinished])
        #expect(try await store.read(.inbox, in: g).isEmpty)
        #expect(try await store.read(.completedTasks, in: g) == [completed])
        #expect(try await store.read(.archivedTasks, in: g) == [completedArchived, archived])
        let all = try await store.read(.allTasks, in: g)
        #expect(Set(all.map(\.id)) == [unfinished.id, done.id, shelved.id, doneShelved.id])
        #expect(completedArchived.isCompleted && completedArchived.archivedAt != nil)

        // Default Search eligibility excludes archived and completed tasks.
        let defaults = try await store.read(.searchText(), in: g)
        #expect(defaults.map(\.id) == [unfinished.id])
        let withCompleted = try await store.read(.searchText(SearchEligibility(includesCompleted: true)), in: g)
        #expect(Set(withCompleted.map(\.id)) == [unfinished.id, done.id])
        let withArchived = try await store.read(.searchText(SearchEligibility(includesArchived: true)), in: g)
        #expect(Set(withArchived.map(\.id)) == [unfinished.id, shelved.id])
        let everything = try await store.read(.searchText(SearchEligibility(includesArchived: true, includesCompleted: true)), in: g)
        #expect(Set(everything.map(\.id)) == [unfinished.id, done.id, shelved.id, doneShelved.id])
        let projected = try #require(everything.first { $0.id == doneShelved.id })
        #expect(projected.kind == .task && projected.title == "Done and shelved" && projected.text == projected.title)
        #expect(projected.isArchived && projected.isCompleted)
        await store.close()

        let reopened = try await CollectionStore.open(fixture.location)
        #expect(try await reopened.read(.allTasks, in: reopened.generation) == all)
        await reopened.close()
    }

    @Test func searchTextMergesNotesAndTasksByContentEditedTime() async throws {
        let fixture = try TemporaryFixture()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000))
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let g = store.generation
        let task = try await store.perform(.createTask(operation: UUID(), title: "Task first"), in: g)
        clock.advance(by: 1)
        let note = try await store.perform(.createNote(operation: UUID(), body: "Note second"), in: g)
        clock.advance(by: 1)
        let edited = try await store.perform(.editTaskTitle(task.id, expectedRevision: 1, title: "Task edited last"), in: g)
        let projection = try await store.read(.searchText(), in: g)
        #expect(projection.map(\.id) == [edited.id, note.id])
        #expect(projection.map(\.kind) == [.task, .note])
        await store.close()
    }

    @Test func creationIsIdempotentPerOperationAndPayload() async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        let g = store.generation
        let operation = UUID()
        let ids = try await withThrowingTaskGroup(of: UUID.self) { group in
            for _ in 0..<20 {
                group.addTask { try await store.perform(.createTask(operation: operation, title: "Once", placement: .today), in: g).id }
            }
            return try await group.reduce(into: Set<UUID>()) { $0.insert($1) }
        }
        #expect(ids.count == 1)
        for reused in [CollectionCommand<TaskItem>.createTask(operation: operation, title: "Different", placement: .today),
                       .createTask(operation: operation, title: "Once", placement: .inbox)] {
            await #expect(throws: CollectionStoreError.operationReused) { try await store.perform(reused, in: g) }
        }
        // Operations are shared across item kinds.
        let noteOperation = UUID()
        _ = try await store.perform(.createNote(operation: noteOperation, body: "Once"), in: g)
        await #expect(throws: CollectionStoreError.operationReused) {
            try await store.perform(.createTask(operation: noteOperation, title: "Once"), in: g)
        }
        await #expect(throws: CollectionStoreError.operationReused) {
            try await store.perform(.createNote(operation: operation, body: "Once"), in: g)
        }
        #expect(try await store.read(.today, in: g).count == 1)
        #expect(try await store.read(.allTasks, in: g).count == 1)
        await store.close()
    }

    @Test func aLostAcknowledgementRetryReturnsTheTaskInItsCurrentState() async throws {
        let fixture = try TemporaryFixture()
        let operation = UUID()
        let lossy = try await CollectionStore.open(fixture.location, faults: .init(afterCommit: { throw InjectedFailure() }))
        await #expect(throws: InjectedFailure.self) {
            try await lossy.perform(.createTask(operation: operation, title: "Lost ack"), in: lossy.generation)
        }
        await lossy.close()

        let store = try await CollectionStore.open(fixture.location)
        let committed = try #require(try await store.read(.inbox, in: store.generation).first)
        let completed = try await store.perform(.completeTask(committed.id, expectedRevision: 1), in: store.generation)
        // The retry does not resurrect the original placement or overwrite later state.
        let retried = try await store.perform(.createTask(operation: operation, title: "Lost ack"), in: store.generation)
        #expect(retried == completed)
        #expect(try await store.read(.allTasks, in: store.generation) == [completed])
        await store.close()
    }

    @Test func satisfiedTaskCommandsAreNoOpsButStaleOnesFail() async throws {
        let fixture = try TemporaryFixture()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000))
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let g = store.generation
        let task = try await store.perform(.createTask(operation: UUID(), title: "Steady"), in: g)
        clock.advance(by: 1)
        let noOps: [CollectionCommand<TaskItem>] = [
            .editTaskTitle(task.id, expectedRevision: 1, title: "Steady"),
            .moveTask(task.id, to: .inbox, expectedRevision: 1),
            .reopenTask(task.id, expectedRevision: 1),
            .restoreTask(task.id, expectedRevision: 1),
        ]
        for command in noOps { #expect(try await store.perform(command, in: g) == task) }
        let completed = try await store.perform(.completeTask(task.id, expectedRevision: 1), in: g)
        #expect(try await store.perform(.completeTask(task.id, expectedRevision: 2), in: g) == completed)
        let stale: [CollectionCommand<TaskItem>] = [
            .completeTask(task.id, expectedRevision: 1),
            .editTaskTitle(task.id, expectedRevision: 1, title: "Steady"),
            .archiveTask(task.id, expectedRevision: 1),
            .reopenTask(task.id, expectedRevision: 1),
        ]
        for command in stale {
            await #expect(throws: CollectionStoreError.staleRevision) { try await store.perform(command, in: g) }
        }
        await #expect(throws: CollectionStoreError.notFound) {
            try await store.perform(.completeTask(UUID(), expectedRevision: 1), in: g)
        }
        #expect(try await store.read(.task(task.id), in: g) == completed)
        await store.close()
    }

    @Test func competingTitleEditAndArchiveCannotOverwriteEachOther() async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        let g = store.generation
        for round in 0..<10 {
            let task = try await store.perform(.createTask(operation: UUID(), title: "Round \(round)"), in: g)
            async let edit = outcome { try await store.perform(.editTaskTitle(task.id, expectedRevision: 1, title: "Edited \(round)"), in: g) }
            async let archive = outcome { try await store.perform(.archiveTask(task.id, expectedRevision: 1), in: g) }
            let outcomes = await [edit, archive]
            let winners = outcomes.compactMap { try? $0.get() }
            #expect(winners.count == 1)
            for case .failure(let error) in outcomes {
                #expect(error as? CollectionStoreError == .staleRevision)
            }
            let winner = try #require(winners.first)
            #expect(try await store.read(.task(task.id), in: g) == winner)
            if winner.archivedAt == nil {
                #expect(winner.title == "Edited \(round)" && winner.placement == .inbox)
            } else {
                #expect(winner.title == "Round \(round)" && winner.placement == nil)
            }
        }
        await store.close()
    }

    @Test func failedTaskCommandsPublishNothing() async throws {
        let fixture = try TemporaryFixture()
        let setup = try await CollectionStore.open(fixture.location)
        let active = try await setup.perform(.createTask(operation: UUID(), title: "Active"), in: setup.generation)
        let done = try await setup.perform(.createTask(operation: UUID(), title: "Done", placement: .today), in: setup.generation)
        let completed = try await setup.perform(.completeTask(done.id, expectedRevision: 1), in: setup.generation)
        let archivedTask = try await setup.perform(.createTask(operation: UUID(), title: "Archived"), in: setup.generation)
        let archived = try await setup.perform(.archiveTask(archivedTask.id, expectedRevision: 1), in: setup.generation)
        let before = try await setup.read(.allTasks, in: setup.generation)
        await setup.close()

        let failNext = Switch()
        let store = try await CollectionStore.open(fixture.location, faults: .init(beforeCommit: { _ in
            if failNext.take() { throw InjectedFailure() }
        }))
        let operation = UUID()
        let commands: [CollectionCommand<TaskItem>] = [
            .createTask(operation: operation, title: "Never"),
            .editTaskTitle(active.id, expectedRevision: 1, title: "Never"),
            .moveTask(active.id, to: .today, expectedRevision: 1),
            .completeTask(active.id, expectedRevision: 1),
            .archiveTask(active.id, expectedRevision: 1),
            .reopenTask(completed.id, expectedRevision: completed.revision),
            .restoreTask(archived.id, expectedRevision: archived.revision),
        ]
        for command in commands {
            failNext.set()
            await #expect(throws: InjectedFailure.self) { try await store.perform(command, in: store.generation) }
            #expect(try await store.read(.allTasks, in: store.generation) == before)
        }
        // No receipt was committed, so the creation can still run once.
        let created = try await store.perform(.createTask(operation: operation, title: "Never"), in: store.generation)
        #expect(try await store.read(.inbox, in: store.generation).map(\.id) == [created.id, active.id])
        await store.close()
    }

    @Test func topInsertionRenumbersWhenKeysRunOutWithoutLosingAnything() async throws {
        let fixture = try TemporaryFixture()
        let exhaust = Switch()
        let store = try await CollectionStore.open(fixture.location, faults: .init(beforeCommit: { db in
            // Simulates a list that has used up every key above its top task.
            if exhaust.take() {
                try db.execute(sql: "UPDATE task SET order_key = order_key - (SELECT min(order_key) FROM task WHERE placement = 'inbox') + ? WHERE placement = 'inbox'",
                               arguments: [Int64.min])
            }
        }))
        let g = store.generation
        var created: [TaskItem] = []
        for index in 0..<4 {
            if index == 3 { exhaust.set() }
            created.append(try await store.perform(.createTask(operation: UUID(), title: "Task \(index)"), in: g))
        }
        let exhausted = try await store.read(.inbox, in: g)
        #expect(exhausted.first?.orderKey == Int64.min)
        #expect(exhausted.map(\.id) == created.reversed().map(\.id))
        let today = try await store.perform(.createTask(operation: UUID(), title: "Unaffected", placement: .today), in: g)

        let top = try await store.perform(.createTask(operation: UUID(), title: "Needs room"), in: g)
        let inbox = try await store.read(.inbox, in: g)
        #expect(inbox.map(\.id) == [top.id] + created.reversed().map(\.id))
        let keys = inbox.compactMap(\.orderKey)
        #expect(keys.count == inbox.count && keys == keys.sorted() && Set(keys).count == keys.count)
        // Renumbering rewrites positions only: other tasks' revisions and times are unchanged.
        for task in inbox.dropFirst() {
            let earlier = try #require(exhausted.first { $0.id == task.id })
            #expect(task.revision == earlier.revision && task.updatedAt == earlier.updatedAt)
        }
        #expect(try await store.read(.today, in: g) == [today])
        // A move into the exhausted-then-renumbered list keeps working.
        let moved = try await store.perform(.moveTask(today.id, to: .inbox, expectedRevision: 1), in: g)
        #expect(try await store.read(.inbox, in: g).first == moved)
        await store.close()
    }

    @Test func todayMembershipIgnoresMidnightDSTAndTimeZoneChanges() async throws {
        let fixture = try TemporaryFixture()
        // 23:59:30 on 2026-03-07 in New York, the night before US daylight saving begins.
        let evening = try #require(DateComponents(calendar: Calendar(identifier: .gregorian),
                                                  timeZone: TimeZone(identifier: "America/New_York"),
                                                  year: 2026, month: 3, day: 7, hour: 23, minute: 59, second: 30).date)
        let clock = FixedClock(evening)
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let task = try await store.perform(.createTask(operation: UUID(), title: "Still today", placement: .today), in: store.generation)
        await store.close()

        // Past local midnight, across the DST change and 40 days later. The Store
        // reads no calendar or time zone, so a time-zone change has nothing to
        // act on; this process-global setting is not mutated in parallel tests.
        for hours in [0.01, 3.0, 26.0, 24.0 * 40] {
            clock.advance(by: hours * 3600)
            let reopened = try await CollectionStore.open(fixture.location, clock: clock.now)
            _ = try await reopened.perform(.createTask(operation: UUID(), title: "Unrelated \(hours)"), in: reopened.generation)
            #expect(try await reopened.read(.today, in: reopened.generation) == [task])
            await reopened.close()
        }
    }

    @Test func observationsFollowTaskTransitions() async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        let g = store.generation
        let task = try await store.perform(.createTask(operation: UUID(), title: "Watched"), in: g)
        var inbox = store.observe(.inbox, in: g).makeAsyncIterator()
        var today = store.observe(.today, in: g).makeAsyncIterator()
        var completed = store.observe(.completedTasks, in: g).makeAsyncIterator()
        #expect(try await inbox.next() == [task])
        #expect(try await today.next() == [])
        #expect(try await completed.next() == [])

        let moved = try await store.perform(.moveTask(task.id, to: .today, expectedRevision: 1), in: g)
        // Intermediate commits may coalesce, so only the latest state is awaited.
        while let value = try await today.next() { if value == [moved] { break } }
        let done = try await store.perform(.completeTask(task.id, expectedRevision: 2), in: g)
        while let value = try await inbox.next() { if value.isEmpty { break } }
        while let value = try await today.next() {
            #expect(value == [] || value == [moved])
            if value.isEmpty { break }
        }
        while let value = try await completed.next() {
            #expect(value == [] || value == [done])
            if value == [done] { break }
        }
        await store.close()
    }
}

/// The task commands in fresh `Hana --collection-fixture` processes.
@Suite(.timeLimit(.minutes(1)))
struct CollectionTaskHarnessTests {
    @Test func organizeATaskAcrossFreshProcesses() throws {
        let root = try HarnessRoot()
        let title = "งาน Thai task"
        let operation = UUID().uuidString
        let created = try Harness.run(["create-task", root.path, "--operation", operation, "--placement", "today"], stdin: title)
            .event("task.created")
        let id = try #require(created["id"] as? String)
        #expect(created["placement"] as? String == "today" && created["titleSHA256"] as? String == taskDigest(title))
        let retried = try Harness.run(["create-task", root.path, "--operation", operation, "--placement", "today"], stdin: title)
            .event("task.created")
        #expect(retried["id"] as? String == id)

        let refused = try Harness.run(["create-task", root.path, "--operation", UUID().uuidString], stdin: "Two\nlines")
        #expect(refused.status == 1 && refused.event("error")["error"] as? String == "invalidTitle")

        let moved = try Harness.run(["move-task", root.path, "--id", id, "--revision", "1", "--to", "inbox"]).event("task.updated")
        #expect(moved["placement"] as? String == "inbox" && moved["revision"] as? Int == 2)
        let completed = try Harness.run(["complete-task", root.path, "--id", id, "--revision", "2"]).event("task.updated")
        #expect(completed["completedAt"] as? Int != nil && completed["placement"] is NSNull)
        #expect(try Harness.run(["read-tasks", root.path, "--view", "completed"]).event("tasks")["count"] as? Int == 1)
        let archived = try Harness.run(["archive-task", root.path, "--id", id, "--revision", "3"]).event("task.updated")
        #expect(archived["completedAt"] as? Int == completed["completedAt"] as? Int)
        #expect(try Harness.run(["read-tasks", root.path, "--view", "archive"]).event("tasks")["count"] as? Int == 1)
        let reopenRefused = try Harness.run(["reopen-task", root.path, "--id", id, "--revision", "4"])
        #expect(reopenRefused.status == 1 && reopenRefused.event("error")["error"] as? String == "archived")
        let restored = try Harness.run(["restore-task", root.path, "--id", id, "--revision", "4"]).event("task.updated")
        #expect(restored["archivedAt"] is NSNull && restored["completedAt"] as? Int == completed["completedAt"] as? Int)
        let reopened = try Harness.run(["reopen-task", root.path, "--id", id, "--revision", "5"]).event("task.updated")
        #expect(reopened["placement"] as? String == "inbox" && reopened["completedAt"] is NSNull)
        let edited = try Harness.run(["edit-task", root.path, "--id", id, "--revision", "6"], stdin: "Renamed").event("task.updated")
        #expect(edited["titleSHA256"] as? String == taskDigest("Renamed"))
        let inbox = try Harness.run(["read-tasks", root.path]).event("tasks")
        #expect(inbox["count"] as? Int == 1)
        #expect((inbox["tasks"] as? [[String: Any]])?.first?["revision"] as? Int == 7)
        #expect(try Harness.run(["read-tasks", root.path, "--view", "today"]).event("tasks")["count"] as? Int == 0)
        #expect(try Harness.run(["read-tasks", root.path, "--view", "all"]).event("tasks")["count"] as? Int == 1)
    }

    @Test(arguments: ["before-commit", "after-commit"])
    func killedCompletionIsAllOrNone(_ point: String) throws {
        let root = try HarnessRoot()
        let created = try Harness.run(["create-task", root.path, "--operation", UUID().uuidString], stdin: "Finish me").event("task.created")
        let id = try #require(created["id"] as? String)
        let paused = try Harness.start(["complete-task", root.path, "--id", id, "--revision", "1", "--pause", point])
        try paused.waitForPause()
        paused.kill()
        let inbox = try Harness.run(["read-tasks", root.path]).event("tasks")
        let completed = try Harness.run(["read-tasks", root.path, "--view", "completed"]).event("tasks")
        #expect(inbox["count"] as? Int == (point == "after-commit" ? 0 : 1))
        #expect(completed["count"] as? Int == (point == "after-commit" ? 1 : 0))
    }
}

private func taskDigest(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}
