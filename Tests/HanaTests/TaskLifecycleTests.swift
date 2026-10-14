import Foundation
import GRDB
import Synchronization
import Testing
@testable import Hana

/// Creating tasks and moving them between Inbox, Today, Completed and Archive
/// through the Collection Store, against real temporary SQLite stores.
@Suite(.timeLimit(.minutes(1)))
struct TaskLifecycleTests {
    private static let start = Date(timeIntervalSince1970: 1_800_000_000.250)

    @Test func newTasksGoToTheTopOfInboxByDefaultAndSurviveReopen() async throws {
        let fixture = try TemporaryFixture()
        let clock = FixedClock(Self.start)
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let g = store.generation
        let title = "  ซื้อนม Thai é (e\u{301}) 🌸\0end  "
        let first = try await store.perform(.createTask(operation: UUID(), title: title), in: g)
        #expect(Array(first.title.utf8) == Array(title.utf8))
        #expect(first.placement == .inbox && first.orderKey != nil)
        #expect(first.revision == 1 && first.completedAt == nil && first.archivedAt == nil)
        #expect(first.createdAt == Self.start && first.contentEditedAt == Self.start && first.updatedAt == Self.start)
        clock.advance(by: 1)
        let second = try await store.perform(.createTask(operation: UUID(), title: "Second"), in: g)
        #expect(try await store.read(.inbox, in: g) == [second, first])
        #expect(try await store.read(.today, in: g) == [])
        await store.close()

        let reopened = try await CollectionStore.open(fixture.location)
        #expect(try await reopened.read(.inbox, in: reopened.generation) == [second, first])
        #expect(try await reopened.read(.task(first.id), in: reopened.generation) == first)
        await reopened.close()
    }
}

extension TaskLifecycleTests {
    @Test func titlesMustBeNonblankSingleLinesAndAreRejectedWholeRatherThanFlattened() async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        let g = store.generation
        for blank in ["", " ", "\t \u{3000}"] {
            await #expect(throws: CollectionStoreError.blankTaskTitle) {
                try await store.perform(.createTask(operation: UUID(), title: blank), in: g)
            }
        }
        // LF, CR, CRLF, VT, FF, NEL, LINE SEPARATOR and PARAGRAPH SEPARATOR, also trailing or alone.
        for breaking in ["Buy\nmilk", "Buy\rmilk", "Buy\r\nmilk", "Buy\u{0B}milk", "Buy\u{0C}milk", "Buy\u{85}milk",
                         "Buy\u{2028}milk", "Buy\u{2029}milk", "Buy milk\n", "\n", " \r\n "] {
            for placement in TaskPlacement.allCases {
                await #expect(throws: CollectionStoreError.multilineTaskTitle) {
                    try await store.perform(.createTask(operation: UUID(), title: breaking, placement: placement), in: g)
                }
            }
        }
        #expect(try await store.read(.inbox, in: g).isEmpty)
        #expect(try await store.read(.today, in: g).isEmpty)

        // Other whitespace and controls are kept exactly.
        let kept = " \tTabbed\u{00A0}title\u{200B} "
        let task = try await store.perform(.createTask(operation: UUID(), title: kept), in: g)
        #expect(Array(task.title.utf8) == Array(kept.utf8))
        await store.close()
    }
}

extension TaskLifecycleTests {
    @Test func explicitTodayCreationAndIdenticalRetriesReturnOneTask() async throws {
        let fixture = try TemporaryFixture()
        let lossy = Switch()
        let store = try await CollectionStore.open(fixture.location, faults: .init(afterCommit: {
            if lossy.take() { throw InjectedFailure() }
        }))
        let g = store.generation
        let operation = UUID()
        let ids = try await withThrowingTaskGroup(of: UUID.self) { group in
            for _ in 0..<20 {
                group.addTask { try await store.perform(.createTask(operation: operation, title: "Call", placement: .today), in: g).id }
            }
            return try await group.reduce(into: Set<UUID>()) { $0.insert($1) }
        }
        #expect(ids.count == 1)
        let id = try #require(ids.first)
        let created = try #require(try await store.read(.task(id), in: g))
        #expect(created.placement == .today)
        #expect(try await store.read(.today, in: g) == [created])
        #expect(try await store.read(.inbox, in: g).isEmpty)

        // The same operation with another title or placement, or a note, is a different payload.
        for command: CollectionCommand<TaskItem> in [.createTask(operation: operation, title: "Call", placement: .inbox),
                                                     .createTask(operation: operation, title: "Call "),
                                                     .createTask(operation: operation, title: "Other", placement: .today)] {
            await #expect(throws: CollectionStoreError.operationReused) { try await store.perform(command, in: g) }
        }
        await #expect(throws: CollectionStoreError.operationReused) {
            try await store.perform(.createNote(operation: operation, body: "Call"), in: g)
        }
        let noteOperation = UUID()
        _ = try await store.perform(.createNote(operation: noteOperation, body: "Call"), in: g)
        await #expect(throws: CollectionStoreError.operationReused) {
            try await store.perform(.createTask(operation: noteOperation, title: "Call"), in: g)
        }

        // A lost acknowledgement is retried after restart; a stale generation is refused first.
        let lost = UUID()
        lossy.set()
        await #expect(throws: InjectedFailure.self) {
            try await store.perform(.createTask(operation: lost, title: "Lost ack"), in: g)
        }
        await store.close()
        let reopened = try await CollectionStore.open(fixture.location)
        await #expect(throws: CollectionStoreError.staleGeneration) {
            try await reopened.perform(.createTask(operation: lost, title: "Lost ack"), in: g)
        }
        let retried = try await reopened.perform(.createTask(operation: lost, title: "Lost ack"), in: reopened.generation)
        #expect(try await reopened.read(.inbox, in: reopened.generation) == [retried])
        #expect(try await reopened.perform(.createTask(operation: operation, title: "Call", placement: .today),
                                           in: reopened.generation) == created)
        await reopened.close()
    }
}

extension TaskLifecycleTests {
    enum State: CaseIterable {
        case inbox, today, completed, archivedUnfinished, archivedCompleted
        var isCompleted: Bool { self == .completed || self == .archivedCompleted }
        var isArchived: Bool { self == .archivedUnfinished || self == .archivedCompleted }
        var placement: TaskPlacement? { self == .inbox ? .inbox : self == .today ? .today : nil }
    }

    enum Command: CaseIterable {
        case editTitle, editSameTitle, moveToInbox, moveToToday, complete, reopen, archive, restore
        func command(_ task: TaskItem) -> CollectionCommand<TaskItem> {
            let r = task.revision
            return switch self {
            case .editTitle: .editTaskTitle(task.id, expectedRevision: r, title: "Renamed")
            case .editSameTitle: .editTaskTitle(task.id, expectedRevision: r, title: task.title)
            case .moveToInbox: .moveTask(task.id, to: .inbox, expectedRevision: r)
            case .moveToToday: .moveTask(task.id, to: .today, expectedRevision: r)
            case .complete: .completeTask(task.id, expectedRevision: r)
            case .reopen: .reopenTask(task.id, expectedRevision: r)
            case .archive: .archiveTask(task.id, expectedRevision: r)
            case .restore: .restoreTask(task.id, expectedRevision: r)
            }
        }
    }

    enum Outcome: Equatable { case becomes(State), noOp, fails(CollectionStoreError) }

    /// The agreed operation table, written out for every state.
    static func expected(_ state: State, _ command: Command) -> Outcome {
        switch (state, command) {
        case (_, .editSameTitle) where !state.isArchived: .noOp
        case (.archivedUnfinished, .archive), (.archivedCompleted, .archive): .noOp
        case (.archivedUnfinished, .restore): .becomes(.inbox)
        case (.archivedCompleted, .restore): .becomes(.completed)
        case (.archivedUnfinished, _), (.archivedCompleted, _): .fails(.archivedTask)
        case (_, .restore): .noOp
        case (_, .editTitle): .becomes(state)
        case (.inbox, .moveToInbox), (.today, .moveToToday): .noOp
        case (.inbox, .moveToToday): .becomes(.today)
        case (.today, .moveToInbox): .becomes(.inbox)
        case (.completed, .moveToInbox), (.completed, .moveToToday): .fails(.completedTask)
        case (.completed, .complete): .noOp
        case (_, .complete): .becomes(.completed)
        case (.completed, .reopen): .becomes(.inbox)
        case (_, .reopen): .noOp
        case (.completed, .archive): .becomes(.archivedCompleted)
        case (_, .archive): .becomes(.archivedUnfinished)
        default: fatalError("unlisted \(state) \(command)")
        }
    }

    private func make(_ state: State, in store: CollectionStore, clock: FixedClock) async throws -> TaskItem {
        let g = store.generation
        var task = try await store.perform(.createTask(operation: UUID(), title: "Task \(state)",
                                                       placement: state.placement ?? .inbox), in: g)
        clock.advance(by: 1)
        if state.isCompleted { task = try await store.perform(.completeTask(task.id, expectedRevision: task.revision), in: g) }
        clock.advance(by: 1)
        if state.isArchived { task = try await store.perform(.archiveTask(task.id, expectedRevision: task.revision), in: g) }
        clock.advance(by: 1)
        return task
    }

    @Test func everyCommandFromEveryCompletionAndArchiveStateFollowsTheOperationTable() async throws {
        let fixture = try TemporaryFixture()
        let clock = FixedClock(Self.start)
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let g = store.generation
        // Neighbours, so "top of the list" is a real claim.
        for state in State.allCases { _ = try await make(state, in: store, clock: clock) }

        var checked = 0
        for state in State.allCases {
            for command in Command.allCases {
                let before = try await make(state, in: store, clock: clock)
                #expect(before.placement == state.placement && (before.completedAt != nil) == state.isCompleted
                        && (before.archivedAt != nil) == state.isArchived)
                let now = clock.now()
                let outcome = Self.expected(state, command)
                let after: TaskItem
                switch outcome {
                case .fails(let error):
                    await #expect(throws: error, "\(state) \(command)") { try await store.perform(command.command(before), in: g) }
                    after = try #require(try await store.read(.task(before.id), in: g))
                    #expect(after == before, "\(state) \(command)")
                case .noOp:
                    after = try await store.perform(command.command(before), in: g)
                    #expect(after == before, "\(state) \(command)")
                case .becomes(let next):
                    after = try await store.perform(command.command(before), in: g)
                    #expect(try await store.read(.task(before.id), in: g) == after)
                    #expect(after.revision == before.revision + 1 && after.updatedAt == now, "\(state) \(command)")
                    #expect(after.createdAt == before.createdAt)
                    #expect(after.contentEditedAt == (command == .editTitle ? now : before.contentEditedAt), "\(state) \(command)")
                    #expect(after.title == (command == .editTitle ? "Renamed" : before.title))
                    #expect(after.placement == next.placement, "\(state) \(command)")
                    #expect(after.completedAt == (next.isCompleted ? before.completedAt ?? now : nil), "\(state) \(command)")
                    #expect(after.archivedAt == (next.isArchived ? before.archivedAt ?? now : nil), "\(state) \(command)")
                    if next.placement != nil, next.placement != before.placement {
                        #expect(after.orderKey != nil)
                        let list = try await store.read(.tasks(in: try #require(next.placement)), in: g)
                        #expect(list.first == after, "\(state) \(command) is not at the top")
                    } else {
                        // Leaving a list clears the key; staying keeps it.
                        #expect(after.orderKey == (next.placement == nil ? nil : before.orderKey), "\(state) \(command)")
                    }
                }
                // Each task is in exactly the view its state names.
                let inbox = try await store.read(.inbox, in: g), today = try await store.read(.today, in: g)
                let completed = try await store.read(.completedTasks, in: g), archived = try await store.read(.archivedTasks, in: g)
                let views = [inbox.contains(after), today.contains(after), completed.contains(after), archived.contains(after)]
                let expectedViews = [after.placement == .inbox, after.placement == .today,
                                     after.completedAt != nil && after.archivedAt == nil, after.archivedAt != nil]
                #expect(views == expectedViews, "\(state) \(command)")
                checked += 1
            }
        }
        #expect(checked == 40)

        let records = try await store.read(.allRecords, in: g)
        #expect(records.tasks.count == 45)
        await store.close()
        let reopened = try await CollectionStore.open(fixture.location)
        #expect(try await reopened.read(.allRecords, in: reopened.generation) == records)
        await reopened.close()
    }
}

extension TaskLifecycleTests {
    @Test func staleOrMissingReferencesFailWithoutChangeEvenWhenTheResultAlreadyHolds() async throws {
        let fixture = try TemporaryFixture()
        let clock = FixedClock(Self.start)
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let g = store.generation
        let task = try await store.perform(.createTask(operation: UUID(), title: "Task"), in: g)
        clock.advance(by: 1)
        let moved = try await store.perform(.moveTask(task.id, to: .today, expectedRevision: 1), in: g)
        for command: CollectionCommand<TaskItem> in [
            .editTaskTitle(task.id, expectedRevision: 1, title: "Task"), .moveTask(task.id, to: .today, expectedRevision: 1),
            .moveTask(task.id, to: .inbox, expectedRevision: 3), .completeTask(task.id, expectedRevision: 1),
            .reopenTask(task.id, expectedRevision: 1), .archiveTask(task.id, expectedRevision: 1),
            .restoreTask(task.id, expectedRevision: 1),
        ] {
            await #expect(throws: CollectionStoreError.staleRevision) { try await store.perform(command, in: g) }
        }
        let missing = UUID()
        for command: CollectionCommand<TaskItem> in [
            .editTaskTitle(missing, expectedRevision: 1, title: "x"), .moveTask(missing, to: .today, expectedRevision: 1),
            .completeTask(missing, expectedRevision: 1), .reopenTask(missing, expectedRevision: 1),
            .archiveTask(missing, expectedRevision: 1), .restoreTask(missing, expectedRevision: 1),
        ] {
            await #expect(throws: CollectionStoreError.taskNotFound) { try await store.perform(command, in: g) }
        }
        // A title check never runs ahead of the revision check, and never flattens.
        await #expect(throws: CollectionStoreError.staleRevision) {
            try await store.perform(.editTaskTitle(task.id, expectedRevision: 1, title: "Two\nlines"), in: g)
        }
        for (title, error) in [("Two\nlines", CollectionStoreError.multilineTaskTitle), (" ", .blankTaskTitle)] {
            await #expect(throws: error) { try await store.perform(.editTaskTitle(task.id, expectedRevision: 2, title: title), in: g) }
        }
        #expect(try await store.read(.task(task.id), in: g) == moved)
        #expect(try await store.read(.today, in: g) == [moved])

        // Completed from Today, reopened into Inbox.
        clock.advance(by: 1)
        let completed = try await store.perform(.completeTask(task.id, expectedRevision: 2), in: g)
        clock.advance(by: 1)
        let reopened = try await store.perform(.reopenTask(task.id, expectedRevision: completed.revision), in: g)
        #expect(reopened.placement == .inbox && reopened.completedAt == nil)
        #expect(try await store.read(.today, in: g).isEmpty)
        #expect(try await store.read(.inbox, in: g) == [reopened])
        await store.close()
    }

    @Test func competingTitleEditsAndArchiveOnOneRevisionLetExactlyOneWin() async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        let g = store.generation
        let task = try await store.perform(.createTask(operation: UUID(), title: "Base"), in: g)
        let commands: [CollectionCommand<TaskItem>] = (0..<12).map { .editTaskTitle(task.id, expectedRevision: 1, title: "Edit \($0)") }
            + [.archiveTask(task.id, expectedRevision: 1), .completeTask(task.id, expectedRevision: 1),
               .moveTask(task.id, to: .today, expectedRevision: 1)]
        let outcomes = await withTaskGroup(of: Result<TaskItem, any Error>.self) { group in
            for command in commands {
                group.addTask {
                    do { return .success(try await store.perform(command, in: g)) } catch { return .failure(error) }
                }
            }
            return await group.reduce(into: []) { $0.append($1) }
        }
        let winners = outcomes.compactMap { try? $0.get() }
        #expect(winners.count == 1)
        let failures = outcomes.compactMap { outcome -> CollectionStoreError? in
            if case .failure(let error) = outcome { error as? CollectionStoreError } else { nil }
        }
        #expect(failures == Array(repeating: .staleRevision, count: commands.count - 1))
        let winner = try #require(winners.first)
        #expect(winner.revision == 2)
        #expect(try await store.read(.task(task.id), in: g) == winner)

        // A late title edit carrying a replaced revision cannot undo a later archive.
        let archived = try await store.perform(.archiveTask(task.id, expectedRevision: 2), in: g)
        let current = archived.revision
        for revision: Int64 in [1, 2] {
            await #expect(throws: CollectionStoreError.staleRevision) {
                try await store.perform(.editTaskTitle(task.id, expectedRevision: revision, title: "Late"), in: g)
            }
        }
        #expect(try await store.read(.task(task.id), in: g) == archived)
        await #expect(throws: CollectionStoreError.archivedTask) {
            try await store.perform(.editTaskTitle(task.id, expectedRevision: current, title: "Late"), in: g)
        }
        await store.close()
    }
}

extension TaskLifecycleTests {
    @Test func topInsertionAtTheEndOfTheKeySpaceRenumbersAtomicallyAndKeepsOrderAndTies() async throws {
        let fixture = try TemporaryFixture()
        let clock = FixedClock(Self.start)
        var store = try await CollectionStore.open(fixture.location, clock: clock.now)
        var g = store.generation
        var inbox: [TaskItem] = []
        for index in 0..<4 { inbox.append(try await store.perform(.createTask(operation: UUID(), title: "Inbox \(index)"), in: g)) }
        let todayTask = try await store.perform(.createTask(operation: UUID(), title: "Today", placement: .today), in: g)
        await store.close()
        // Two tasks tie on the lowest possible key; ID breaks the tie.
        let (tiedLow, tiedHigh) = inbox[0].id.uuidString < inbox[1].id.uuidString ? (inbox[0], inbox[1]) : (inbox[1], inbox[0])
        try fixture.setOrderKeys([tiedLow.id: .min, tiedHigh.id: .min, inbox[2].id: .min + 1, inbox[3].id: .max,
                                  todayTask.id: .min])
        let expectedOrder = [tiedLow.id, tiedHigh.id, inbox[2].id, inbox[3].id]

        let inject = Switch(), violate = Switch()
        store = try await CollectionStore.open(fixture.location, clock: clock.now, faults: .init(beforeCommit: { db in
            if inject.take() { throw InjectedFailure() }
            if violate.take() { try db.execute(sql: "UPDATE task SET revision = 0") }
        }))
        g = store.generation
        let before = try await store.read(.inbox, in: g)
        #expect(before.map(\.id) == expectedOrder)
        let todayBefore = try await store.read(.today, in: g)
        clock.advance(by: 10)
        let operation = UUID()
        inject.set()
        await #expect(throws: InjectedFailure.self) { try await store.perform(.createTask(operation: operation, title: "Top"), in: g) }
        violate.set()
        await #expect(throws: CollectionStoreError.storageFailure(code: 19)) {
            try await store.perform(.createTask(operation: operation, title: "Top"), in: g)
        }
        #expect(try await store.read(.inbox, in: g) == before)

        let top = try await store.perform(.createTask(operation: operation, title: "Top"), in: g)
        let after = try await store.read(.inbox, in: g)
        #expect(after.map(\.id) == [top.id] + expectedOrder)
        #expect(after.compactMap(\.orderKey) == after.compactMap(\.orderKey).sorted())
        #expect(Set(after.compactMap(\.orderKey)).count == after.count)
        // Renumbering is internal: other tasks keep their revision and times.
        for (old, new) in zip(before, after.dropFirst()) {
            #expect(new.revision == old.revision && new.updatedAt == old.updatedAt && new.title == old.title)
        }
        #expect(try await store.read(.today, in: g) == todayBefore)

        // Moving into an exhausted list renumbers it too.
        let moved = try await store.perform(.moveTask(inbox[3].id, to: .today, expectedRevision: 1), in: g)
        #expect(try await store.read(.today, in: g).map(\.id) == [moved.id, todayTask.id])
        await store.close()

        let reopened = try await CollectionStore.open(fixture.location)
        #expect(try await reopened.read(.inbox, in: reopened.generation).map(\.id) == [top.id] + expectedOrder.dropLast())
        #expect(try await reopened.read(.today, in: reopened.generation).map(\.id) == [moved.id, todayTask.id])
        await reopened.close()
    }
}

extension TaskLifecycleTests {
    @Test func completedAndArchiveSortByTheirTimesThenIDAndSearchEligibilityIsExplicit() async throws {
        let fixture = try TemporaryFixture()
        let clock = FixedClock(Self.start)
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let g = store.generation
        func create(_ title: String, _ placement: TaskPlacement = .inbox) async throws -> TaskItem {
            try await store.perform(.createTask(operation: UUID(), title: title, placement: placement), in: g)
        }
        func ordered(_ a: TaskItem, _ b: TaskItem) -> [UUID] { [a.id, b.id].sorted { $0.uuidString < $1.uuidString } }
        let inbox = try await create("ซื้อนม Inbox")
        let today = try await create("Today", .today)
        let (doneA, doneB, doneLater) = (try await create("Done A"), try await create("Done B"), try await create("Done later"))
        let (hiddenA, hiddenB, hiddenDone) = (try await create("Hidden A"), try await create("Hidden B"), try await create("Hidden done"))
        clock.advance(by: 1)
        for task in [doneA, doneB, hiddenDone] { _ = try await store.perform(.completeTask(task.id, expectedRevision: 1), in: g) }
        clock.advance(by: 1)
        _ = try await store.perform(.completeTask(doneLater.id, expectedRevision: 1), in: g)
        // Three completed at one instant tie on ID, below the later completion.
        let tied = [doneA.id, doneB.id, hiddenDone.id].sorted { $0.uuidString < $1.uuidString }
        #expect(try await store.read(.completedTasks, in: g).map(\.id) == [doneLater.id] + tied)
        clock.advance(by: 1)
        for task in [hiddenA, hiddenB] { _ = try await store.perform(.archiveTask(task.id, expectedRevision: 1), in: g) }
        clock.advance(by: 1)
        _ = try await store.perform(.archiveTask(hiddenDone.id, expectedRevision: 2), in: g)
        #expect(try await store.read(.archivedTasks, in: g).map(\.id) == [hiddenDone.id] + ordered(hiddenA, hiddenB))
        #expect(try await store.read(.completedTasks, in: g).map(\.id) == [doneLater.id] + ordered(doneA, doneB))

        let records = try await store.read(.allRecords, in: g)
        #expect(records.tasks.map(\.id) == [inbox, today, doneA, doneB, doneLater, hiddenA, hiddenB, hiddenDone]
            .map(\.id).sorted { $0.uuidString < $1.uuidString })
        #expect(records.notes.isEmpty)

        func entry(_ task: TaskItem, completed: Bool = false, archived: Bool = false) -> TaskSearchEntry {
            TaskSearchEntry(id: task.id, title: task.title, isCompleted: completed, isArchived: archived)
        }
        func sorted(_ entries: [TaskSearchEntry]) -> [TaskSearchEntry] { entries.sorted { $0.id.uuidString < $1.id.uuidString } }
        let active = [entry(inbox), entry(today)]
        let completed = [entry(doneA, completed: true), entry(doneB, completed: true), entry(doneLater, completed: true)]
        let archived = [entry(hiddenA, archived: true), entry(hiddenB, archived: true)]
        let archivedDone = [entry(hiddenDone, completed: true, archived: true)]
        #expect(try await store.read(.taskSearchEntries(), in: g) == sorted(active))
        #expect(try await store.read(.taskSearchEntries(includingCompleted: true), in: g) == sorted(active + completed))
        #expect(try await store.read(.taskSearchEntries(includingArchived: true), in: g) == sorted(active + archived))
        #expect(try await store.read(.taskSearchEntries(includingCompleted: true, includingArchived: true), in: g)
                == sorted(active + completed + archived + archivedDone))
        await store.close()

        let reopened = try await CollectionStore.open(fixture.location)
        #expect(try await reopened.read(.allRecords, in: reopened.generation) == records)
        await reopened.close()
    }
}

extension TaskLifecycleTests {
    @Test func failedTaskCommandsPublishNothingAndOldGenerationsCannotChangeTasks() async throws {
        let fixture = try TemporaryFixture()
        let clock = FixedClock(Self.start)
        let inject = Switch(), violate = Switch()
        let store = try await CollectionStore.open(fixture.location, clock: clock.now, faults: .init(beforeCommit: { db in
            if inject.take() { throw InjectedFailure() }
            // A real SQLite CHECK failure after the command's own statements.
            if violate.take() { try db.execute(sql: "UPDATE task SET revision = 0") }
        }))
        let g = store.generation
        let active = try await store.perform(.createTask(operation: UUID(), title: "Active"), in: g)
        let done = try await store.perform(.completeTask(
            try await store.perform(.createTask(operation: UUID(), title: "Done", placement: .today), in: g).id, expectedRevision: 1), in: g)
        let hidden = try await store.perform(.archiveTask(
            try await store.perform(.createTask(operation: UUID(), title: "Hidden"), in: g).id, expectedRevision: 1), in: g)
        let records = try await store.read(.allRecords, in: g)
        clock.advance(by: 60)
        let attempts: [CollectionCommand<TaskItem>] = [
            .createTask(operation: UUID(), title: "Never", placement: .today),
            .editTaskTitle(active.id, expectedRevision: 1, title: "Lost edit"), .moveTask(active.id, to: .today, expectedRevision: 1),
            .completeTask(active.id, expectedRevision: 1), .reopenTask(done.id, expectedRevision: 2),
            .archiveTask(done.id, expectedRevision: 2), .restoreTask(hidden.id, expectedRevision: 2),
        ]
        for command in attempts {
            inject.set()
            await #expect(throws: InjectedFailure.self) { try await store.perform(command, in: g) }
            violate.set()
            await #expect(throws: CollectionStoreError.storageFailure(code: 19)) { try await store.perform(command, in: g) }
            #expect(try await store.read(.allRecords, in: g) == records)
        }
        await store.close()

        let reopened = try await CollectionStore.open(fixture.location)
        for command in attempts {
            await #expect(throws: CollectionStoreError.staleGeneration) { try await reopened.perform(command, in: g) }
        }
        #expect(try await reopened.read(.allRecords, in: reopened.generation) == records)
        // Nothing was consumed: each command still applies once, now.
        let created = try await reopened.perform(attempts[0], in: reopened.generation)
        let restored = try await reopened.perform(attempts[6], in: reopened.generation)
        #expect(created.placement == .today && created.title == "Never")
        #expect(restored.archivedAt == nil && restored.placement == .inbox)
        await reopened.close()
    }

    @Test func theSchemaItselfRefusesTasksThatBreakPlacementOrTitleRules() async throws {
        let fixture = try TemporaryFixture()
        let statement = Mutex<String?>(nil)
        let store = try await CollectionStore.open(fixture.location, faults: .init(beforeCommit: { db in
            if let sql = statement.withLock({ $0.take() }) { try db.execute(sql: sql) }
        }))
        let g = store.generation
        let active = try await store.perform(.createTask(operation: UUID(), title: "Active"), in: g)
        let done = try await store.perform(.completeTask(
            try await store.perform(.createTask(operation: UUID(), title: "Done"), in: g).id, expectedRevision: 1), in: g)
        let records = try await store.read(.allRecords, in: g)
        for sql in [
            "UPDATE task SET placement = 'inbox', order_key = 5 WHERE id = '\(done.id)'",   // completed with a list
            "UPDATE task SET archived_at = 1 WHERE id = '\(active.id)'",                    // archived keeps its list
            "UPDATE task SET order_key = NULL WHERE id = '\(active.id)'",                   // placement without key
            "UPDATE task SET placement = NULL, order_key = NULL WHERE id = '\(active.id)'", // active without list
            "UPDATE task SET placement = 'someday' WHERE id = '\(active.id)'",
            "UPDATE task SET title = 'a' || char(10) || 'b' WHERE id = '\(active.id)'",
            "UPDATE task SET title = 'a' || char(8232) || 'b' WHERE id = '\(active.id)'",
            "UPDATE task SET title = '' WHERE id = '\(active.id)'",
        ] {
            statement.withLock { $0 = sql }
            await #expect(throws: CollectionStoreError.storageFailure(code: 19), "\(sql)") {
                try await store.perform(.createTask(operation: UUID(), title: "Carrier"), in: g)
            }
            #expect(try await store.read(.allRecords, in: g) == records)
        }
        await store.close()
    }

    @Test func todayMembershipIgnoresMidnightAndDaylightSavingChanges() async throws {
        let fixture = try TemporaryFixture()
        // 23:59:30 in Bangkok; then just past Bangkok and New York midnight, a
        // minute either side of the 2026 Berlin and New York daylight-saving
        // ends (local clocks repeat an hour), and just past a UTC new year.
        let clock = FixedClock(Date(timeIntervalSince1970: 1_791_910_770))
        var store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let today = [try await store.perform(.createTask(operation: UUID(), title: "Today 1", placement: .today), in: store.generation),
                     try await store.perform(.createTask(operation: UUID(), title: "Today 2", placement: .today), in: store.generation)]
        let expected = Array(today.reversed())
        await store.close()
        for instant: TimeInterval in [1_791_910_830, 1_791_950_430, 1_792_889_940, 1_792_890_060,
                                        1_793_512_740, 1_793_512_860, 1_798_761_630] {
            clock.advance(by: instant - clock.now().timeIntervalSince1970)
            store = try await CollectionStore.open(fixture.location, clock: clock.now)
            #expect(try await store.read(.today, in: store.generation) == expected)
            let inbox = try await store.read(.inbox, in: store.generation)
            #expect(!inbox.contains { task in today.contains { $0.id == task.id } })
            // An unrelated write at the new instant does not move anything.
            _ = try await store.perform(.createTask(operation: UUID(), title: "Inbox \(instant)"), in: store.generation)
            #expect(try await store.read(.today, in: store.generation) == expected)
            await store.close()
        }
    }
}

extension TaskLifecycleTests {
    @Test func observationsFollowCommittedTaskTransitionsAndNeverShowRolledBackOnes() async throws {
        let fixture = try TemporaryFixture()
        let clock = FixedClock(Self.start)
        let failNext = Switch()
        let store = try await CollectionStore.open(fixture.location, clock: clock.now, faults: .init(beforeCommit: { _ in
            if failNext.take() { throw InjectedFailure() }
        }))
        let g = store.generation
        let queries: [CollectionQuery<[TaskItem]>] = [.inbox, .today, .completedTasks, .archivedTasks]
        var iterators = queries.map { store.observe($0, in: g).makeAsyncIterator() }
        var search = store.observe(.taskSearchEntries(), in: g).makeAsyncIterator()
        for index in iterators.indices { #expect(try await iterators[index].next() == []) }
        #expect(try await search.next() == [])

        var committed: [[[TaskItem]]] = []
        var committedSearch: [[TaskSearchEntry]] = []
        let operation = UUID()
        var task: TaskItem?
        let steps: [(TaskItem?) -> CollectionCommand<TaskItem>] = [
            { _ in .createTask(operation: operation, title: "Watched") },
            { .editTaskTitle($0!.id, expectedRevision: $0!.revision, title: "Watched, edited") },
            { .moveTask($0!.id, to: .today, expectedRevision: $0!.revision) },
            { .completeTask($0!.id, expectedRevision: $0!.revision) },
            { .archiveTask($0!.id, expectedRevision: $0!.revision) },
            { .restoreTask($0!.id, expectedRevision: $0!.revision) },
            { .reopenTask($0!.id, expectedRevision: $0!.revision) },
        ]
        for step in steps {
            clock.advance(by: 1)
            failNext.set()
            await #expect(throws: InjectedFailure.self) { try await store.perform(step(task), in: g) }
            task = try await store.perform(step(task), in: g)
            var values: [[TaskItem]] = []
            for query in queries { values.append(try await store.read(query, in: g)) }
            committed.append(values)
            committedSearch.append(try await store.read(.taskSearchEntries(), in: g))
        }
        #expect(committed.last == [[try #require(task)], [], [], []])

        // Intermediate commits may coalesce; every value is committed and the
        // latest is eventually observed.
        for index in iterators.indices {
            let states = committed.map { $0[index] }
            while let value = try await iterators[index].next() {
                #expect(states.contains(value))
                if value == states.last { break }
            }
        }
        while let value = try await search.next() {
            #expect(committedSearch.contains(value))
            if value == committedSearch.last { break }
        }
        await store.close()
    }
}
