import Foundation
import GRDB
import Testing
@testable import Hana

/// Manual reorder of Inbox and Today through the Collection Store, against
/// real temporary SQLite stores.
@Suite(.timeLimit(.minutes(1)))
struct TaskOrderingTests {
    private static let start = Date(timeIntervalSince1970: 1_800_000_000.250)

    /// Creates `count` tasks in `placement`; returned in list order, top first.
    private func list(_ count: Int, in placement: TaskPlacement, store: CollectionStore) async throws -> [TaskItem] {
        for index in 0..<count {
            _ = try await store.perform(.createTask(operation: UUID(), title: "\(placement) \(index)", placement: placement),
                                        in: store.generation)
        }
        return try await store.read(.tasks(in: placement), in: store.generation)
    }

    @Test func reorderMovesOneTaskWithinItsListAndSurvivesReopen() async throws {
        let fixture = try TemporaryFixture()
        let clock = FixedClock(Self.start)
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let g = store.generation
        let inbox = try await list(4, in: .inbox, store: store)
        let today = try await list(2, in: .today, store: store)
        let (a, b, c, d) = (inbox[0], inbox[1], inbox[2], inbox[3])
        clock.advance(by: 5)
        let now = clock.now()

        let moved = try await store.perform(.reorderTask(a.id, in: .inbox, after: c.id, expectedOrder: inbox.map(\.id)), in: g)
        #expect(try await store.read(.inbox, in: g).map(\.id) == [b.id, c.id, a.id, d.id])
        #expect(moved.revision == a.revision + 1 && moved.updatedAt == now)
        #expect(moved.createdAt == a.createdAt && moved.contentEditedAt == a.contentEditedAt && moved.title == a.title)
        #expect(moved.placement == .inbox && moved.completedAt == nil && moved.archivedAt == nil)
        // To the top, then to the bottom.
        let order1 = [b.id, c.id, a.id, d.id]
        _ = try await store.perform(.reorderTask(d.id, in: .inbox, after: nil, expectedOrder: order1), in: g)
        let order2 = [d.id, b.id, c.id, a.id]
        #expect(try await store.read(.inbox, in: g).map(\.id) == order2)
        _ = try await store.perform(.reorderTask(b.id, in: .inbox, after: a.id, expectedOrder: order2), in: g)
        let order3 = [d.id, c.id, a.id, b.id]
        let final = try await store.read(.inbox, in: g)
        #expect(final.map(\.id) == order3)
        // Only the moved tasks changed; Today is independent.
        #expect(final.first { $0.id == c.id }?.revision == c.revision)
        #expect(try await store.read(.today, in: g) == today)
        await store.close()

        let reopened = try await CollectionStore.open(fixture.location)
        #expect(try await reopened.read(.inbox, in: reopened.generation) == final)
        #expect(try await reopened.read(.today, in: reopened.generation) == today)
        await reopened.close()
    }
}

extension TaskOrderingTests {
    /// Each change commits between reading the list and reordering it from that view.
    enum Interleaved: CaseIterable {
        case createAtTop, moveIn, moveOut, complete, archive, reopen, restore, reorder
    }

    @Test(arguments: Interleaved.allCases)
    func aReorderFromAListThatChangedSinceItWasReadFailsWithoutChange(_ change: Interleaved) async throws {
        let fixture = try TemporaryFixture()
        let clock = FixedClock(Self.start)
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let g = store.generation
        let other = try await list(1, in: .today, store: store)[0]
        let done = try await store.perform(.completeTask(try await list(1, in: .inbox, store: store)[0].id, expectedRevision: 1), in: g)
        let hidden = try await store.perform(.archiveTask(try await list(1, in: .inbox, store: store)[0].id, expectedRevision: 1), in: g)
        let seen = try await list(3, in: .inbox, store: store)
        clock.advance(by: 1)
        switch change {
        case .createAtTop: _ = try await store.perform(.createTask(operation: UUID(), title: "New"), in: g)
        case .moveIn: _ = try await store.perform(.moveTask(other.id, to: .inbox, expectedRevision: other.revision), in: g)
        case .moveOut: _ = try await store.perform(.moveTask(seen[1].id, to: .today, expectedRevision: seen[1].revision), in: g)
        case .complete: _ = try await store.perform(.completeTask(seen[2].id, expectedRevision: seen[2].revision), in: g)
        case .archive: _ = try await store.perform(.archiveTask(seen[0].id, expectedRevision: seen[0].revision), in: g)
        case .reopen: _ = try await store.perform(.reopenTask(done.id, expectedRevision: done.revision), in: g)
        case .restore: _ = try await store.perform(.restoreTask(hidden.id, expectedRevision: hidden.revision), in: g)
        case .reorder:
            _ = try await store.perform(.reorderTask(seen[2].id, in: .inbox, after: nil, expectedOrder: seen.map(\.id)), in: g)
        }
        let records = try await store.read(.allRecords, in: g)
        // Moving the top task below the second, from the old view. Even a
        // reorder whose requested position already holds is refused.
        for command: CollectionCommand<TaskItem> in [
            .reorderTask(seen[0].id, in: .inbox, after: seen[1].id, expectedOrder: seen.map(\.id)),
            .reorderTask(seen[0].id, in: .inbox, after: nil, expectedOrder: seen.map(\.id)),
        ] {
            await #expect(throws: change == .archive ? CollectionStoreError.archivedTask : .staleList, "\(change)") {
                try await store.perform(command, in: g)
            }
        }
        #expect(try await store.read(.allRecords, in: g) == records)
        await store.close()
    }
}

extension TaskOrderingTests {
    @Test func reorderChecksTheTaskThenTheRequestThenTheListAndAlreadyHeldPositionsAreNoOps() async throws {
        let fixture = try TemporaryFixture()
        let clock = FixedClock(Self.start)
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let g = store.generation
        let today = try await list(1, in: .today, store: store)
        let done = try await store.perform(.completeTask(try await list(1, in: .inbox, store: store)[0].id, expectedRevision: 1), in: g)
        let hidden = try await store.perform(.archiveTask(try await list(1, in: .inbox, store: store)[0].id, expectedRevision: 1), in: g)
        let inbox = try await list(3, in: .inbox, store: store)
        let order = inbox.map(\.id)
        let records = try await store.read(.allRecords, in: g)
        clock.advance(by: 1)

        let missing = UUID()
        let refusals: [(CollectionCommand<TaskItem>, CollectionStoreError)] = [
            // The task itself, even when the list is stale too.
            (.reorderTask(missing, in: .inbox, after: nil, expectedOrder: [missing] + order), .taskNotFound),
            (.reorderTask(hidden.id, in: .inbox, after: nil, expectedOrder: [hidden.id] + order), .archivedTask),
            (.reorderTask(done.id, in: .inbox, after: nil, expectedOrder: [done.id] + order), .completedTask),
            // A request that does not describe a move within the list it names.
            (.reorderTask(inbox[0].id, in: .inbox, after: inbox[0].id, expectedOrder: order), .invalidReorder),
            (.reorderTask(inbox[0].id, in: .inbox, after: today[0].id, expectedOrder: order), .invalidReorder),
            (.reorderTask(inbox[0].id, in: .inbox, after: nil, expectedOrder: Array(order.dropFirst())), .invalidReorder),
            (.reorderTask(today[0].id, in: .inbox, after: nil, expectedOrder: order), .invalidReorder),
            // A list view that is not the list as it stands.
            (.reorderTask(today[0].id, in: .inbox, after: nil, expectedOrder: order + [today[0].id]), .staleList),
            (.reorderTask(inbox[0].id, in: .today, after: nil, expectedOrder: order), .staleList),
            (.reorderTask(inbox[0].id, in: .inbox, after: nil, expectedOrder: order.reversed()), .staleList),
            (.reorderTask(inbox[0].id, in: .inbox, after: inbox[1].id, expectedOrder: order + order), .staleList),
        ]
        for (command, error) in refusals {
            await #expect(throws: error) { try await store.perform(command, in: g) }
        }
        #expect(try await store.read(.allRecords, in: g) == records)

        // Positions that already hold change nothing, not even the revision.
        for (task, predecessor) in [(inbox[0], nil), (inbox[1], inbox[0].id), (inbox[2], inbox[1].id)] {
            #expect(try await store.perform(.reorderTask(task.id, in: .inbox, after: predecessor, expectedOrder: order), in: g) == task)
        }
        #expect(try await store.perform(.reorderTask(today[0].id, in: .today, after: nil, expectedOrder: [today[0].id]), in: g)
                == today[0])
        // So do the other commands' no-ops.
        for command: CollectionCommand<TaskItem> in [
            .moveTask(inbox[1].id, to: .inbox, expectedRevision: inbox[1].revision),
            .reopenTask(inbox[2].id, expectedRevision: inbox[2].revision),
            .restoreTask(inbox[1].id, expectedRevision: inbox[1].revision),
            .editTaskTitle(inbox[1].id, expectedRevision: inbox[1].revision, title: inbox[1].title),
            .completeTask(done.id, expectedRevision: done.revision), .archiveTask(hidden.id, expectedRevision: hidden.revision),
        ] { _ = try await store.perform(command, in: g) }
        #expect(try await store.read(.allRecords, in: g) == records)
        await store.close()
    }
}

extension TaskOrderingTests {
    /// Sets order keys directly while no Store owns the root: the only way to
    /// reach the edge of the key space without 2^63 insertions.
    private func setOrderKeys(_ keys: [UUID: Int64], in fixture: TemporaryFixture) throws {
        let queue = try DatabaseQueue(path: fixture.location.databaseURL.path)
        try queue.write { db in
            for (id, key) in keys { try db.execute(sql: "UPDATE task SET order_key = ? WHERE id = ?", arguments: [key, id.uuidString]) }
        }
        try queue.close()
    }

    @Test func reorderUsesAFreeKeyWhenOneFitsAndOtherwiseRenumbersAtomicallyWithoutLosingAnyTask() async throws {
        let fixture = try TemporaryFixture()
        let clock = FixedClock(Self.start)
        var store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let created = try await list(5, in: .inbox, store: store)
        let today = try await list(2, in: .today, store: store)
        await store.close()
        // Two tasks tie on the lowest key (ID breaks the tie), a wide gap whose
        // width overflows Int64, then the highest key.
        let ids = created.map(\.id)
        let (tieLow, tieHigh) = ids[0].uuidString < ids[1].uuidString ? (ids[0], ids[1]) : (ids[1], ids[0])
        let (m, w, top) = (ids[2], ids[3], ids[4])
        try setOrderKeys([tieLow: .min, tieHigh: .min, m: -2, w: .max - 1, top: .max], in: fixture)

        let inject = Switch(), violate = Switch()
        store = try await CollectionStore.open(fixture.location, clock: clock.now, faults: .init(beforeCommit: { db in
            if inject.take() { throw InjectedFailure() }
            if violate.take() { try db.execute(sql: "UPDATE task SET revision = 0") }
        }))
        let g = store.generation
        func inbox() async throws -> [TaskItem] { try await store.read(.inbox, in: g) }
        func keys(_ list: [TaskItem]) -> [UUID: Int64?] { Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0.orderKey) }) }
        @discardableResult
        func reorder(_ id: UUID, after predecessor: UUID?) async throws -> TaskItem {
            clock.advance(by: 1)
            return try await store.perform(.reorderTask(id, in: .inbox, after: predecessor, expectedOrder: try await inbox().map(\.id)), in: g)
        }
        /// Every task is still there exactly once, in strictly ascending keys,
        /// and only `moved` has a new revision.
        func expectCoherent(_ before: [TaskItem], _ after: [TaskItem], moved: UUID, _ comment: Comment) {
            #expect(Set(after.map(\.id)) == Set(before.map(\.id)) && after.count == before.count, comment)
            let keys = after.compactMap(\.orderKey)
            #expect(keys.count == after.count && zip(keys, keys.dropFirst()).allSatisfy { $0 < $1 }, comment)
            for task in after {
                let old = before.first { $0.id == task.id }!
                #expect(task.revision == old.revision + (task.id == moved ? 1 : 0), comment)
                #expect(task.title == old.title && task.createdAt == old.createdAt && task.contentEditedAt == old.contentEditedAt)
            }
        }
        let start = try await inbox()
        #expect(start.map(\.id) == [tieLow, tieHigh, m, w, top])

        // Failed reorders that would renumber leave every key as it was.
        for fault in [inject, violate] {
            fault.set()
            await #expect(throws: (any Error).self) {
                try await store.perform(.reorderTask(m, in: .inbox, after: nil, expectedOrder: start.map(\.id)), in: g)
            }
            #expect(try await inbox() == start)
        }

        // Between the tied keys: no integer fits, so the list is renumbered.
        var before = try await inbox()
        try await reorder(top, after: tieLow)
        var after = try await inbox()
        #expect(after.map(\.id) == [tieLow, top, tieHigh, m, w])
        expectCoherent(before, after, moved: top, "between ties")

        // A wide gap takes a key strictly inside it; nothing else moves.
        await store.close()
        try setOrderKeys([tieLow: .min + 1, top: .min + 2, tieHigh: .min + 3, m: .max - 1, w: .max], in: fixture)
        store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let g2 = store.generation
        before = try await store.read(.inbox, in: g2)
        clock.advance(by: 1)
        let wide = try await store.perform(.reorderTask(w, in: .inbox, after: tieHigh, expectedOrder: before.map(\.id)), in: g2)
        after = try await store.read(.inbox, in: g2)
        #expect(after.map(\.id) == [tieLow, top, tieHigh, w, m])
        #expect(try #require(wide.orderKey) > .min + 3 && wide.orderKey! < .max - 1)
        #expect(keys(after.filter { $0.id != w }) == keys(before.filter { $0.id != w }))
        expectCoherent(before, after, moved: w, "wide gap")

        // Past the lowest and the highest possible key, then between adjacent keys.
        await store.close()
        try setOrderKeys([tieLow: .min, top: 0, tieHigh: 1, w: 2, m: .max], in: fixture)
        store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let g3 = store.generation
        for (id, predecessor, order) in [(m, nil as UUID?, [m, tieLow, top, tieHigh, w]), (tieLow, w, [m, top, tieHigh, w, tieLow]),
                                         (tieLow, top, [m, top, tieLow, tieHigh, w])] {
            before = try await store.read(.inbox, in: g3)
            clock.advance(by: 1)
            _ = try await store.perform(.reorderTask(id, in: .inbox, after: predecessor, expectedOrder: before.map(\.id)), in: g3)
            after = try await store.read(.inbox, in: g3)
            #expect(after.map(\.id) == order)
            expectCoherent(before, after, moved: id, "edge")
        }
        // Today was never touched.
        #expect(try await store.read(.today, in: g3) == today)
        await store.close()

        let reopened = try await CollectionStore.open(fixture.location)
        #expect(try await reopened.read(.inbox, in: reopened.generation) == after)
        await reopened.close()
    }
}

extension TaskOrderingTests {
    struct Outcome: Sendable {
        let reorder: Int?
        let task: TaskItem?
        let error: CollectionStoreError?
    }

    @Test func concurrentReordersInsertsAndMovesFromOneViewLoseNothingAndAtMostOneReorderWins() async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        let g = store.generation
        for round in 0..<10 {
            let incoming = try await list(1, in: .today, store: store).first!
            let seen = try await store.read(.inbox, in: g)
            let order = seen.map(\.id)
            // Every task but the last moves below the next one, a real move
            // each; plus a creation and a move in.
            let reorders: [CollectionCommand<TaskItem>] = order.indices.dropLast().map {
                .reorderTask(order[$0], in: .inbox, after: order[$0 + 1], expectedOrder: order)
            }
            // Index of each reorder, or nil for the creation and the move in.
            let commands: [(Int?, CollectionCommand<TaskItem>)] = reorders.enumerated().map { ($0.offset, $0.element) }
                + [(nil, .createTask(operation: UUID(), title: "New \(round)")), (nil, .moveTask(incoming.id, to: .inbox, expectedRevision: 1))]
            let outcomes = await withTaskGroup(of: Outcome.self) { group in
                for (index, command) in commands {
                    group.addTask {
                        do { return Outcome(reorder: index, task: try await store.perform(command, in: g), error: nil) }
                        catch { return Outcome(reorder: index, task: nil, error: error as? CollectionStoreError) }
                    }
                }
                return await group.reduce(into: [Outcome]()) { $0.append($1) }
            }
            let others = outcomes.filter { $0.reorder == nil }.compactMap(\.task)
            #expect(others.count == 2, "round \(round)")
            let won = outcomes.filter { $0.task != nil }.compactMap(\.reorder)
            #expect(won.count <= 1, "round \(round)")
            #expect(outcomes.filter { $0.task == nil }.allSatisfy { $0.error == .staleList }, "round \(round)")

            let final = try await store.read(.inbox, in: g)
            #expect(Set(final.map(\.id)) == Set(order + others.map(\.id)) && final.count == order.count + 2, "round \(round)")
            #expect(Set(final.prefix(2).map(\.id)) == Set(others.map(\.id)), "round \(round): insertions are on top")
            var expected = order
            if let index = won.first {
                let id = expected.remove(at: index)
                let predecessor = order[index + 1]
                expected.insert(id, at: expected.firstIndex(of: predecessor)! + 1)
            }
            #expect(final.dropFirst(2).map(\.id) == expected, "round \(round)")
            #expect(try await store.read(.today, in: g).isEmpty)
        }
        await store.close()
    }

    @Test func insertionMoveReopenAndRestoreGoAboveTheManualOrderWhichSurvivesRestart() async throws {
        let fixture = try TemporaryFixture()
        let clock = FixedClock(Self.start)
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let g = store.generation
        let made = try await list(4, in: .inbox, store: store)
        let todayTasks = try await list(2, in: .today, store: store)
        // Manual order: last created to the bottom, first to the top of Today.
        _ = try await store.perform(.reorderTask(made[0].id, in: .inbox, after: made[3].id, expectedOrder: made.map(\.id)), in: g)
        _ = try await store.perform(.reorderTask(todayTasks[1].id, in: .today, after: nil, expectedOrder: todayTasks.map(\.id)), in: g)
        let manual = [made[1].id, made[2].id, made[3].id, made[0].id]
        let manualToday = [todayTasks[1].id, todayTasks[0].id]
        func ids(_ query: CollectionQuery<[TaskItem]>) async throws -> [UUID] { try await store.read(query, in: g).map(\.id) }
        #expect(try await ids(.inbox) == manual)
        #expect(try await ids(.today) == manualToday)

        // Completing and archiving take tasks out without disturbing the rest.
        clock.advance(by: 1)
        let done = try await store.perform(.completeTask(made[2].id, expectedRevision: 1), in: g)
        clock.advance(by: 1)
        let hidden = try await store.perform(.archiveTask(made[1].id, expectedRevision: 1), in: g)
        #expect(try await ids(.inbox) == [made[3].id, made[0].id])
        // Top insertion from every source: create, move, reopen, restore.
        clock.advance(by: 1)
        let created = try await store.perform(.createTask(operation: UUID(), title: "Created"), in: g)
        let moved = try await store.perform(.moveTask(todayTasks[0].id, to: .inbox, expectedRevision: 1), in: g)
        let reopened = try await store.perform(.reopenTask(done.id, expectedRevision: done.revision), in: g)
        let restored = try await store.perform(.restoreTask(hidden.id, expectedRevision: hidden.revision), in: g)
        let inbox = [restored.id, reopened.id, moved.id, created.id, made[3].id, made[0].id]
        #expect(try await ids(.inbox) == inbox)
        #expect(try await ids(.today) == [todayTasks[1].id])
        // Reopened and restored tasks keep their creation and content-edited times.
        for (task, original) in [(reopened, made[2]), (restored, made[1])] {
            #expect(task.createdAt == original.createdAt && task.contentEditedAt == original.contentEditedAt)
        }
        // A reorder from the current view still works after all that.
        _ = try await store.perform(.reorderTask(made[0].id, in: .inbox, after: restored.id, expectedOrder: inbox), in: g)
        let final = [restored.id, made[0].id, reopened.id, moved.id, created.id, made[3].id]
        #expect(try await ids(.inbox) == final)
        let records = try await store.read(.allRecords, in: g)
        await store.close()

        let restarted = try await CollectionStore.open(fixture.location)
        #expect(try await restarted.read(.inbox, in: restarted.generation).map(\.id) == final)
        #expect(try await restarted.read(.today, in: restarted.generation).map(\.id) == [todayTasks[1].id])
        #expect(try await restarted.read(.allRecords, in: restarted.generation) == records)
        await restarted.close()
    }

    @Test func completedAndArchiveKeepTheirTimeOrderWhateverTheManualOrderWas() async throws {
        let fixture = try TemporaryFixture()
        let clock = FixedClock(Self.start)
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let g = store.generation
        let made = try await list(4, in: .inbox, store: store)
        // Reverse the manual order, then finish and hide tasks top-down.
        var order = made.map(\.id)
        for task in made {
            _ = try await store.perform(.reorderTask(task.id, in: .inbox, after: nil, expectedOrder: order), in: g)
            order = try await store.read(.inbox, in: g).map(\.id)
        }
        #expect(order == made.reversed().map(\.id))
        let current = try await store.read(.inbox, in: g)
        clock.advance(by: 1)
        _ = try await store.perform(.completeTask(current[0].id, expectedRevision: current[0].revision), in: g)
        clock.advance(by: 1)
        _ = try await store.perform(.completeTask(current[1].id, expectedRevision: current[1].revision), in: g)
        clock.advance(by: 1)
        _ = try await store.perform(.archiveTask(current[2].id, expectedRevision: current[2].revision), in: g)
        clock.advance(by: 1)
        _ = try await store.perform(.archiveTask(current[3].id, expectedRevision: current[3].revision), in: g)
        #expect(try await store.read(.completedTasks, in: g).map(\.id) == [current[1].id, current[0].id])
        #expect(try await store.read(.archivedTasks, in: g).map(\.id) == [current[3].id, current[2].id])
        for task in try await store.read(.allRecords, in: g).tasks { #expect(task.orderKey == nil) }
        await store.close()
    }
}

extension TaskOrderingTests {
    @Test func observersSeeOnlyCommittedOrdersAndOldGenerationsCannotReorder() async throws {
        let fixture = try TemporaryFixture()
        let failNext = Switch()
        let store = try await CollectionStore.open(fixture.location, faults: .init(beforeCommit: { _ in
            if failNext.take() { throw InjectedFailure() }
        }))
        let g = store.generation
        var current = try await list(4, in: .inbox, store: store).map(\.id)
        var observed = store.observe(.inbox, in: g).makeAsyncIterator()
        var committed = [current]
        #expect(try await observed.next()?.map(\.id) == current)
        // Rotate the bottom task to the top three times; each first attempt rolls back.
        for _ in 0..<3 {
            let command = CollectionCommand<TaskItem>.reorderTask(current.last!, in: .inbox, after: nil, expectedOrder: current)
            failNext.set()
            await #expect(throws: InjectedFailure.self) { try await store.perform(command, in: g) }
            _ = try await store.perform(command, in: g)
            current = [current.last!] + current.dropLast()
            committed.append(current)
        }
        #expect(try await store.read(.inbox, in: g).map(\.id) == current)
        // Intermediate commits may coalesce; every value is committed and the latest arrives.
        while let value = try await observed.next()?.map(\.id) {
            #expect(committed.contains(value))
            if value == current { break }
        }
        await store.close()

        let reopened = try await CollectionStore.open(fixture.location)
        await #expect(throws: CollectionStoreError.staleGeneration) {
            try await reopened.perform(.reorderTask(current[0], in: .inbox, after: current[1], expectedOrder: current), in: g)
        }
        #expect(try await reopened.read(.inbox, in: reopened.generation).map(\.id) == current)
        await reopened.close()
    }
}
