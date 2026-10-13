import Foundation
import Testing
@testable import Hana

/// Issue #27: manual Inbox/Today order through the production Store on real
/// temporary SQLite.
@Suite(.timeLimit(.minutes(1)))
struct CollectionTaskOrderTests {
    /// Creates `titles` in `placement`, returning the list top first.
    private func list(_ titles: [String], in placement: TaskPlacement, store: CollectionStore) async throws -> [TaskItem] {
        for title in titles.reversed() {
            _ = try await store.perform(.createTask(operation: UUID(), title: title, placement: placement), in: store.generation)
        }
        return try await store.read(.tasks(in: placement), in: store.generation)
    }

    @Test func reorderMovesOneTaskAndPersistsAcrossRestart() async throws {
        let fixture = try TemporaryFixture()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000))
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let g = store.generation
        let inbox = try await list(["A", "B", "C", "D"], in: .inbox, store: store)
        #expect(inbox.map(\.title) == ["A", "B", "C", "D"])
        let today = try await list(["T1", "T2"], in: .today, store: store)

        clock.advance(by: 1)
        let d = inbox[3]
        let moved = try await store.perform(.reorderTask(d.id, expectedRevision: 1, in: .inbox, expectedOrder: inbox.map(\.id), toIndex: 1), in: g)
        #expect(moved.revision == 2 && moved.updatedAt == clock.now())
        #expect(moved.createdAt == d.createdAt && moved.contentEditedAt == d.contentEditedAt && moved.placement == .inbox)
        let reordered = try await store.read(.inbox, in: g)
        #expect(reordered.map(\.title) == ["A", "D", "B", "C"])
        // Unmoved tasks keep their revisions and times, even though renumbering
        // (the neighbours' keys were adjacent) rewrote their positions.
        for task in reordered where task.id != d.id {
            let earlier = try #require(inbox.first { $0.id == task.id })
            #expect(task.revision == earlier.revision && task.updatedAt == earlier.updatedAt && task.title == earlier.title)
        }
        // Lists are independent.
        #expect(try await store.read(.today, in: g) == today)

        // To the bottom and to the top.
        let bottom = try await store.perform(.reorderTask(inbox[0].id, expectedRevision: 1, in: .inbox,
                                                          expectedOrder: reordered.map(\.id), toIndex: 3), in: g)
        #expect(try await store.read(.inbox, in: g).map(\.title) == ["D", "B", "C", "A"])
        let afterBottom = try await store.read(.inbox, in: g)
        _ = try await store.perform(.reorderTask(bottom.id, expectedRevision: bottom.revision, in: .inbox,
                                                 expectedOrder: afterBottom.map(\.id), toIndex: 0), in: g)
        let final = try await store.read(.inbox, in: g)
        #expect(final.map(\.title) == ["A", "D", "B", "C"])
        await store.close()

        let reopened = try await CollectionStore.open(fixture.location)
        #expect(try await reopened.read(.inbox, in: reopened.generation) == final)
        #expect(try await reopened.read(.today, in: reopened.generation) == today)
        await reopened.close()
    }

    @Test func theCurrentPositionIsANoOpAndInvalidRequestsChangeNothing() async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        let g = store.generation
        let inbox = try await list(["A", "B", "C"], in: .inbox, store: store)
        let today = try await list(["T"], in: .today, store: store)
        let order = inbox.map(\.id)
        #expect(try await store.perform(.reorderTask(inbox[1].id, expectedRevision: 1, in: .inbox, expectedOrder: order, toIndex: 1), in: g) == inbox[1])

        for index in [-1, 3, 100] {
            await #expect(throws: CollectionStoreError.invalidPosition) {
                try await store.perform(.reorderTask(inbox[1].id, expectedRevision: 1, in: .inbox, expectedOrder: order, toIndex: index), in: g)
            }
        }
        // The wrong list, a list missing the task, and a stale revision.
        await #expect(throws: CollectionStoreError.staleList) {
            try await store.perform(.reorderTask(inbox[1].id, expectedRevision: 1, in: .today, expectedOrder: today.map(\.id), toIndex: 0), in: g)
        }
        await #expect(throws: CollectionStoreError.staleList) {
            try await store.perform(.reorderTask(inbox[1].id, expectedRevision: 1, in: .inbox, expectedOrder: [inbox[0].id, inbox[2].id], toIndex: 0), in: g)
        }
        await #expect(throws: CollectionStoreError.staleRevision) {
            try await store.perform(.reorderTask(inbox[1].id, expectedRevision: 2, in: .inbox, expectedOrder: order, toIndex: 0), in: g)
        }
        let completed = try await store.perform(.completeTask(today[0].id, expectedRevision: 1), in: g)
        await #expect(throws: CollectionStoreError.completed) {
            try await store.perform(.reorderTask(completed.id, expectedRevision: completed.revision, in: .today, expectedOrder: [], toIndex: 0), in: g)
        }
        let archived = try await store.perform(.archiveTask(completed.id, expectedRevision: completed.revision), in: g)
        await #expect(throws: CollectionStoreError.archived) {
            try await store.perform(.reorderTask(archived.id, expectedRevision: archived.revision, in: .today, expectedOrder: [], toIndex: 0), in: g)
        }
        #expect(try await store.read(.inbox, in: g) == inbox)
        await store.close()
    }

    @Test func obsoleteOrdersAreRejectedAfterEveryKindOfConcurrentListChange() async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        let g = store.generation
        let inbox = try await list(["A", "B", "C", "D", "E"], in: .inbox, store: store)
        var seen = inbox.map(\.id)
        let target = inbox[4]
        func reorderTargetToTop() async throws -> TaskItem {
            let revision = try #require(try await store.read(.task(target.id), in: g)).revision
            return try await store.perform(.reorderTask(target.id, expectedRevision: revision, in: .inbox, expectedOrder: seen, toIndex: 0), in: g)
        }
        let changes: [(String, CollectionCommand<TaskItem>)] = [
            ("insert", .createTask(operation: UUID(), title: "Inserted")),
            ("move out", .moveTask(inbox[1].id, to: .today, expectedRevision: 1)),
            ("complete", .completeTask(inbox[2].id, expectedRevision: 1)),
            ("archive", .archiveTask(inbox[3].id, expectedRevision: 1)),
            ("reorder", .reorderTask(inbox[0].id, expectedRevision: 1, in: .inbox, expectedOrder: [], toIndex: 0)),
        ]
        for (name, change) in changes {
            let before = try await store.read(.inbox, in: g)
            if name == "reorder" {
                // Another caller reorders from its own current view.
                _ = try await store.perform(.reorderTask(inbox[0].id, expectedRevision: 1, in: .inbox,
                                                         expectedOrder: before.map(\.id), toIndex: before.count - 1), in: g)
            } else {
                _ = try await store.perform(change, in: g)
            }
            let after = try await store.read(.inbox, in: g)
            await #expect(throws: CollectionStoreError.staleList, "after \(name)") { try await reorderTargetToTop() }
            #expect(try await store.read(.inbox, in: g) == after, "a rejected reorder changes nothing after \(name)")
            seen = after.map(\.id)
        }
        // With a current view the same reorder succeeds and nothing is lost.
        let moved = try await reorderTargetToTop()
        let final = try await store.read(.inbox, in: g)
        #expect(final.first == moved)
        #expect(Set(final.map(\.id)) == Set(seen))
        await store.close()
    }

    @Test func racingReordersFromTheSameViewCommitExactlyOnce() async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        let g = store.generation
        for round in 0..<10 {
            let inbox = try await list((0..<4).map { "Round \(round) task \($0)" }, in: .inbox, store: store)
            let order = inbox.map(\.id)
            async let first = outcome {
                try await store.perform(.reorderTask(inbox[3].id, expectedRevision: inbox[3].revision, in: .inbox, expectedOrder: order, toIndex: 0), in: g)
            }
            async let second = outcome {
                try await store.perform(.reorderTask(inbox[2].id, expectedRevision: inbox[2].revision, in: .inbox, expectedOrder: order, toIndex: 0), in: g)
            }
            let outcomes = await [first, second]
            #expect(outcomes.compactMap { try? $0.get() }.count == 1)
            for case .failure(let error) in outcomes {
                #expect(error as? CollectionStoreError == .staleList)
            }
            let after = try await store.read(.inbox, in: g)
            #expect(Set(after.map(\.id)) == Set(order), "no task disappears, duplicates or changes list")
            #expect(try await store.read(.today, in: g).isEmpty)
            // Archive this round's tasks so the next round starts from an empty Inbox.
            for task in after {
                _ = try await store.perform(.archiveTask(task.id, expectedRevision: task.revision), in: g)
            }
        }
        await store.close()
    }

    @Test func adjacentKeysRenumberTheListInTheSameTransaction() async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        let g = store.generation
        // Top insertion gives consecutive keys, so there is no room between any two tasks.
        let inbox = try await list(["A", "B", "C"], in: .inbox, store: store)
        #expect(inbox.compactMap(\.orderKey) == [-2, -1, 0])
        let moved = try await store.perform(.reorderTask(inbox[2].id, expectedRevision: 1, in: .inbox,
                                                         expectedOrder: inbox.map(\.id), toIndex: 1), in: g)
        let after = try await store.read(.inbox, in: g)
        #expect(after.map(\.title) == ["A", "C", "B"])
        #expect(after.compactMap(\.orderKey) == [0, TaskOrder.spacing, 2 * TaskOrder.spacing])
        #expect(moved.revision == 2 && after[1] == moved)
        // Renumbering rewrites positions only.
        for (task, earlier) in [(after[0], inbox[0]), (after[2], inbox[1])] {
            #expect(task.revision == earlier.revision && task.updatedAt == earlier.updatedAt)
        }
        // Later insertions and midpoints keep working after renumbering.
        let top = try await store.perform(.createTask(operation: UUID(), title: "Top"), in: g)
        #expect(top.orderKey == -1)
        let current = try await store.read(.inbox, in: g)
        let middle = try await store.perform(.reorderTask(top.id, expectedRevision: 1, in: .inbox,
                                                          expectedOrder: current.map(\.id), toIndex: 2), in: g)
        #expect(middle.orderKey == TaskOrder.spacing + TaskOrder.spacing / 2)
        #expect(try await store.read(.inbox, in: g).map(\.title) == ["A", "C", "Top", "B"])
        await store.close()
    }

    /// Opens a store whose Inbox is `Top`, `Middle`, `Bottom` with keys
    /// `Int64.min`, 0 and `Int64.max`.
    private func stretchedInbox(_ fixture: TemporaryFixture) async throws -> (CollectionStore, [TaskItem]) {
        let stretch = Switch()
        let store = try await CollectionStore.open(fixture.location, faults: .init(beforeCommit: { db in
            if stretch.take() {
                try db.execute(sql: """
                    UPDATE task SET order_key = CASE
                        WHEN order_key = (SELECT min(order_key) FROM task WHERE placement = 'inbox') THEN ?
                        WHEN order_key = (SELECT max(order_key) FROM task WHERE placement = 'inbox') THEN ?
                        ELSE 0 END
                    WHERE placement = 'inbox'
                    """, arguments: [Int64.min, Int64.max])
            }
        }))
        _ = try await list(["Top", "Middle", "Bottom"], in: .inbox, store: store)
        stretch.set()
        _ = try await store.perform(.createTask(operation: UUID(), title: "Trigger", placement: .today), in: store.generation)
        let inbox = try await store.read(.inbox, in: store.generation)
        #expect(inbox.map(\.title) == ["Top", "Middle", "Bottom"])
        #expect(inbox.compactMap(\.orderKey) == [Int64.min, 0, Int64.max])
        return (store, inbox)
    }

    @Test(arguments: [true, false])
    func extremeKeysAtEitherEndRenumberInsteadOfOverflowing(_ towardsTop: Bool) async throws {
        let fixture = try TemporaryFixture()
        let (store, inbox) = try await stretchedInbox(fixture)
        let subject = towardsTop ? inbox[2] : inbox[0]
        let index = towardsTop ? 0 : 2
        let moved = try await store.perform(.reorderTask(subject.id, expectedRevision: subject.revision, in: .inbox,
                                                         expectedOrder: inbox.map(\.id), toIndex: index), in: store.generation)
        let after = try await store.read(.inbox, in: store.generation)
        #expect(after.map(\.title) == (towardsTop ? ["Bottom", "Top", "Middle"] : ["Middle", "Bottom", "Top"]))
        #expect(after.compactMap(\.orderKey) == [0, TaskOrder.spacing, 2 * TaskOrder.spacing])
        #expect(moved.revision == subject.revision + 1)
        for task in after where task.id != subject.id {
            let earlier = try #require(inbox.first { $0.id == task.id })
            #expect(task.revision == earlier.revision && task.updatedAt == earlier.updatedAt)
        }
        await store.close()
    }

    @Test func midpointsBetweenExtremeKeysDoNotOverflow() async throws {
        let fixture = try TemporaryFixture()
        let (store, inbox) = try await stretchedInbox(fixture)
        // Between Int64.min and 0, with no renumbering.
        let moved = try await store.perform(.reorderTask(inbox[2].id, expectedRevision: inbox[2].revision, in: .inbox,
                                                         expectedOrder: inbox.map(\.id), toIndex: 1), in: store.generation)
        #expect(moved.orderKey == Int64.min / 2)
        let after = try await store.read(.inbox, in: store.generation)
        #expect(after.map(\.title) == ["Top", "Bottom", "Middle"])
        #expect(after.compactMap(\.orderKey) == [Int64.min, Int64.min / 2, 0])
        await store.close()
    }

    @Test func reorderInteractsWithInsertionMoveReopenAndRestore() async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        let g = store.generation
        let inbox = try await list(["A", "B", "C"], in: .inbox, store: store)
        let today = try await list(["T1", "T2"], in: .today, store: store)
        _ = try await store.perform(.reorderTask(inbox[0].id, expectedRevision: 1, in: .inbox, expectedOrder: inbox.map(\.id), toIndex: 2), in: g)
        _ = try await store.perform(.reorderTask(today[1].id, expectedRevision: 1, in: .today, expectedOrder: today.map(\.id), toIndex: 0), in: g)
        #expect(try await store.read(.inbox, in: g).map(\.title) == ["B", "C", "A"])
        #expect(try await store.read(.today, in: g).map(\.title) == ["T2", "T1"])

        let created = try await store.perform(.createTask(operation: UUID(), title: "New"), in: g)
        #expect(try await store.read(.inbox, in: g).map(\.title) == ["New", "B", "C", "A"])
        let a = try #require(try await store.read(.task(inbox[0].id), in: g))
        _ = try await store.perform(.moveTask(a.id, to: .today, expectedRevision: a.revision), in: g)
        #expect(try await store.read(.today, in: g).map(\.title) == ["A", "T2", "T1"])
        #expect(try await store.read(.inbox, in: g).map(\.title) == ["New", "B", "C"])

        let t1 = try #require(try await store.read(.task(today[0].id), in: g))
        let done = try await store.perform(.completeTask(t1.id, expectedRevision: t1.revision), in: g)
        _ = try await store.perform(.reopenTask(done.id, expectedRevision: done.revision), in: g)
        #expect(try await store.read(.inbox, in: g).map(\.title) == ["T1", "New", "B", "C"])
        let archived = try await store.perform(.archiveTask(created.id, expectedRevision: 1), in: g)
        _ = try await store.perform(.restoreTask(created.id, expectedRevision: archived.revision), in: g)
        #expect(try await store.read(.inbox, in: g).map(\.title) == ["New", "T1", "B", "C"])
        await store.close()
    }

    @Test func aFailedReorderRollsBackRenumberingToo() async throws {
        let fixture = try TemporaryFixture()
        let setup = try await CollectionStore.open(fixture.location)
        let inbox = try await list(["A", "B", "C"], in: .inbox, store: setup)
        await setup.close()
        let failing = try await CollectionStore.open(fixture.location, faults: .init(beforeCommit: { _ in throw InjectedFailure() }))
        // Adjacent keys: this reorder renumbers the list before failing.
        await #expect(throws: InjectedFailure.self) {
            try await failing.perform(.reorderTask(inbox[2].id, expectedRevision: 1, in: .inbox,
                                                   expectedOrder: inbox.map(\.id), toIndex: 1), in: failing.generation)
        }
        #expect(try await failing.read(.inbox, in: failing.generation) == inbox)
        await failing.close()
    }

    @Test func observationsReachTheReorderedList() async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        let g = store.generation
        let inbox = try await list(["A", "B", "C"], in: .inbox, store: store)
        var observed = store.observe(.inbox, in: g).makeAsyncIterator()
        #expect(try await observed.next() == inbox)
        _ = try await store.perform(.reorderTask(inbox[2].id, expectedRevision: 1, in: .inbox, expectedOrder: inbox.map(\.id), toIndex: 0), in: g)
        let expected = try await store.read(.inbox, in: g)
        #expect(expected.map(\.title) == ["C", "A", "B"])
        while let value = try await observed.next() {
            #expect(Set(value.map(\.id)) == Set(inbox.map(\.id)), "observed lists never lose or duplicate tasks")
            if value == expected { break }
        }
        await store.close()
    }

    @Test func theOrganizedFixtureSurvivesRestart() async throws {
        let fixture = try TemporaryFixture()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000))
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let contents = try await OrganizedCollection.populate(store, clock: clock)
        #expect(contents.notes.count == OrganizedCollection.noteBodies.count)
        #expect(contents.tasks.count == OrganizedCollection.taskTitles.count)
        let inbox = try await store.read(.inbox, in: store.generation)
        #expect(inbox.first?.title == "Inbox one")
        let today = try await store.read(.today, in: store.generation)
        #expect(today.map(\.title) == ["Today one", "Today two"])
        await store.close()

        let reopened = try await CollectionStore.open(fixture.location)
        #expect(try await OrganizedCollection.read(reopened) == contents)
        #expect(try await reopened.read(.inbox, in: reopened.generation) == inbox)
        await reopened.close()
    }
}

/// Manual reorder in fresh `Hana --collection-fixture` processes.
@Suite(.timeLimit(.minutes(1)))
struct CollectionTaskOrderHarnessTests {
    @Test func reorderAcrossFreshProcessesAndRejectAStaleOrder() throws {
        let root = try HarnessRoot()
        var ids: [String] = []
        for title in ["C", "B", "A"] {
            let created = try Harness.run(["create-task", root.path, "--operation", UUID().uuidString], stdin: title).event("task.created")
            ids.insert(try #require(created["id"] as? String), at: 0)
        }
        let order = ids.joined(separator: ",")
        let moved = try Harness.run(["reorder-task", root.path, "--id", ids[2], "--revision", "1", "--placement", "inbox",
                                     "--order", order, "--index", "0"]).event("task.updated")
        #expect(moved["revision"] as? Int == 2)
        let inbox = try Harness.run(["read-tasks", root.path]).event("tasks")
        #expect((inbox["tasks"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == [ids[2], ids[0], ids[1]])

        let stale = try Harness.run(["reorder-task", root.path, "--id", ids[1], "--revision", "1", "--placement", "inbox",
                                     "--order", order, "--index", "0"])
        #expect(stale.status == 1 && stale.event("error")["error"] as? String == "staleList")
        let failed = try Harness.run(["reorder-task", root.path, "--id", ids[1], "--revision", "1", "--placement", "inbox",
                                      "--order", [ids[2], ids[0], ids[1]].joined(separator: ","), "--index", "0",
                                      "--fail", "before-commit"])
        #expect(failed.status == 1 && failed.event("error")["error"] as? String == "injectedFailure")
        let unchanged = try Harness.run(["read-tasks", root.path]).event("tasks")
        #expect((unchanged["tasks"] as? [[String: Any]])?.compactMap { $0["id"] as? String } == [ids[2], ids[0], ids[1]])
    }
}
