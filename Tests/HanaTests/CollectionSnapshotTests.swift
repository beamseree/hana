import CryptoKit
import Foundation
import GRDB
import Testing
@testable import Hana

/// Issue #29: manual snapshots through Collection Recovery, proven usable by
/// reopening copies in new disposable Stores.
@Suite(.timeLimit(.minutes(1)))
struct CollectionSnapshotTests {
    @Test func aSnapshotOfAnUncheckpointedWALReopensWithEveryFact() async throws {
        let fixture = try TemporaryFixture()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000))
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        try await OrganizedCollection.populate(store, clock: clock)
        let contents = try await store.read(.contents, in: store.generation)
        // Recent commits live only in the WAL until a checkpoint.
        let wal = fixture.location.databaseURL.path + "-wal"
        let walBytes = try #require(try FileManager.default.attributesOfItem(atPath: wal)[.size] as? Int)
        #expect(walBytes > 0)

        let info = try await CollectionRecovery.createSnapshot(store, in: store.generation, clock: clock.now)
        #expect(info.collectionID == contents.collectionID && info.schemaVersion == 1)
        #expect(info.noteCount == contents.notes.count && info.taskCount == contents.tasks.count)
        #expect(info.capturedAt == clock.now() && info.latestUpdatedAt == contents.latestUpdatedAt)
        let directory = CollectionRecovery.snapshotsURL(fixture.location).appendingPathComponent(info.id)
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) == ["collection.sqlite", "snapshot.json"])
        // One self-contained rollback-journal file: header bytes 18 and 19 are 1, not WAL's 2.
        let header = try Data(contentsOf: directory.appendingPathComponent("collection.sqlite")).prefix(20)
        #expect(Array(header.suffix(2)) == [1, 1])
        let before = try FileTree(directory)

        // A copy in a new disposable Store, with no source WAL alongside it.
        let disposable = try TemporaryFixture().directory.appendingPathComponent("reopened")
        let reopened = try await CollectionRecovery.reopenSnapshotCopy(fixture.location, id: info.id, into: disposable)
        #expect(reopened == contents)
        // The snapshot itself was only read; the live store is unaffected.
        #expect(try FileTree(directory).files == before.files)
        #expect(try await store.read(.contents, in: store.generation) == contents)
        #expect(CollectionRecovery.listSnapshots(fixture.location) == [.init(id: info.id, result: .success(info))])
        await store.close()
    }

    @Test func snapshotsAreSeparateFromTheLiveCollectionAndOwnerOnly() async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        _ = try await store.perform(.createNote(operation: UUID(), body: "Private"), in: store.generation)
        let info = try await CollectionRecovery.createSnapshot(store, in: store.generation)
        await store.close()
        let snapshots = CollectionRecovery.snapshotsURL(fixture.location)
        #expect(snapshots.deletingLastPathComponent().standardizedFileURL == fixture.location.root.standardizedFileURL)
        #expect(!snapshots.path.hasPrefix(fixture.location.collectionDirectory.path))
        let tree = try FileTree(snapshots)
        for (path, mode) in tree.modes {
            #expect(mode == (tree.directories.contains(path) ? 0o700 : 0o600), "\(path) has mode \(String(mode, radix: 8))")
        }
        #expect(tree.files.keys.allSatisfy { $0.hasPrefix(info.id + "/") })
    }

    @Test func snapshotsDuringConcurrentCommandsCaptureOneCommittedState() async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        let g = store.generation
        // As in the export race: tasks == counter or counter + 1 in every committed state.
        let counter = try await store.perform(.createNote(operation: UUID(), body: "Count 0"), in: g)
        let rounds = 60
        let writer = Task {
            var revision = counter.revision
            for round in 1...rounds {
                _ = try await store.perform(.createTask(operation: UUID(), title: "Task \(round)"), in: g)
                revision = try await store.perform(.editNote(counter.id, expectedRevision: revision, body: "Count \(round)"), in: g).revision
            }
        }
        var snapshots: [CollectionRecovery.SnapshotInfo] = []
        while snapshots.count < 6 { snapshots.append(try await CollectionRecovery.createSnapshot(store, in: g)) }
        try await writer.value
        snapshots.append(try await CollectionRecovery.createSnapshot(store, in: g))
        let final = try await store.read(.contents, in: g)
        await store.close()

        for (index, snapshot) in snapshots.enumerated() {
            let root = try TemporaryFixture().directory.appendingPathComponent("copy-\(index)")
            let copy = try await CollectionRecovery.reopenSnapshotCopy(fixture.location, id: snapshot.id, into: root)
            let note = try #require(copy.notes.first)
            let count = try #require(Int(note.body.dropFirst("Count ".count)))
            #expect(copy.tasks.count == count || copy.tasks.count == count + 1, "torn snapshot: \(count) vs \(copy.tasks.count)")
            #expect(snapshot.taskCount == copy.tasks.count)
        }
        let lastRoot = try TemporaryFixture().directory.appendingPathComponent("last")
        let last = try await CollectionRecovery.reopenSnapshotCopy(fixture.location, id: try #require(snapshots.last).id, into: lastRoot)
        #expect(last == final)
        #expect(CollectionRecovery.listSnapshots(fixture.location).filter(\.isUsable).count == snapshots.count)
    }

    @Test(arguments: SnapshotTampering.allCases)
    func invalidSnapshotsAreRefusedAndListedAsUnusable(_ tampering: SnapshotTampering) async throws {
        let fixture = try TemporaryFixture()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000))
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        try await OrganizedCollection.populate(store, clock: clock)
        let good = try await CollectionRecovery.createSnapshot(store, in: store.generation, clock: clock.now)
        clock.advance(by: 1)
        let victim = try await CollectionRecovery.createSnapshot(store, in: store.generation, clock: clock.now)
        await store.close()
        let goodTree = try FileTree(CollectionRecovery.snapshotsURL(fixture.location).appendingPathComponent(good.id))

        let directory = CollectionRecovery.snapshotsURL(fixture.location).appendingPathComponent(victim.id)
        try tampering.apply(to: directory)
        #expect(throws: tampering.expected) { _ = try CollectionRecovery.inspectSnapshot(fixture.location, id: victim.id) }
        let listings = CollectionRecovery.listSnapshots(fixture.location)
        #expect(listings.first { $0.id == good.id }?.result == .success(good))
        #expect(listings.first { $0.id == victim.id }?.result == .failure(tampering.expected))
        await #expect(throws: tampering.expected) {
            _ = try await CollectionRecovery.reopenSnapshotCopy(fixture.location, id: victim.id,
                                                                into: try TemporaryFixture().directory.appendingPathComponent("never"))
        }
        // The good snapshot is untouched and still usable.
        #expect(try FileTree(CollectionRecovery.snapshotsURL(fixture.location).appendingPathComponent(good.id)).files == goodTree.files)
    }

    enum SnapshotTampering: CaseIterable, Sendable {
        case truncatedDatabase, truncatedDatabaseWithMatchingManifest, foreignBytesWithMatchingManifest, walHeader, futureSchema,
             blankNoteBody, missingManifest, missingDatabase, futureManifest, malformedManifest, countMismatch,
             wrongID, extraFile

        var expected: CollectionRecoveryError {
            switch self {
            case .truncatedDatabase: .invalidPackage(.hashMismatch)
            case .truncatedDatabaseWithMatchingManifest, .foreignBytesWithMatchingManifest, .walHeader: .invalidPackage(.corruptDatabase)
            case .futureSchema: .unsupportedSchema(version: 2)
            case .blankNoteBody: .invalidPackage(.domainViolation)
            case .missingManifest: .invalidPackage(.incomplete)
            case .missingDatabase: .invalidPackage(.missingFile)
            case .futureManifest: .unsupportedFormat(version: 2)
            case .malformedManifest, .wrongID: .invalidPackage(.malformed)
            case .countMismatch: .invalidPackage(.countMismatch)
            case .extraFile: .invalidPackage(.unexpectedFile)
            }
        }

        func apply(to directory: URL) throws {
            let database = directory.appendingPathComponent("collection.sqlite")
            let manifestURL = directory.appendingPathComponent("snapshot.json")
            var manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
            /// Rewrites the database, then records its new size and hash so
            /// only the database-level defect remains.
            func replaceDatabase(_ data: Data) throws {
                try FileManager.default.removeItem(at: database)
                try data.write(to: database)
                try matchManifestToDatabase()
            }
            func matchManifestToDatabase() throws {
                let data = try Data(contentsOf: database)
                manifest["database"] = ["name": "collection.sqlite", "bytes": data.count,
                                        "sha256": SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()]
            }
            switch self {
            case .truncatedDatabase:
                let data = try Data(contentsOf: database)
                try data.prefix(data.count / 2).write(to: database)
            case .truncatedDatabaseWithMatchingManifest:
                let data = try Data(contentsOf: database)
                try replaceDatabase(data.prefix(data.count / 2))
            case .foreignBytesWithMatchingManifest:
                try replaceDatabase(Data((0..<8192).map { UInt8(truncatingIfNeeded: $0 &* 31) }))
            case .walHeader:
                var data = try Data(contentsOf: database)
                data[data.startIndex + 18] = 2
                data[data.startIndex + 19] = 2
                try replaceDatabase(data)
            case .futureSchema:
                try mutateDatabase(database) { try $0.execute(sql: "PRAGMA user_version = 2") }
                try matchManifestToDatabase()
            case .blankNoteBody:
                try mutateDatabase(database) { try $0.execute(sql: "UPDATE note SET body = '   ' WHERE rowid = (SELECT min(rowid) FROM note)") }
                try matchManifestToDatabase()
            case .missingManifest:
                try FileManager.default.removeItem(at: manifestURL)
                return
            case .missingDatabase:
                try FileManager.default.removeItem(at: database)
            case .futureManifest:
                manifest["formatVersion"] = 2
            case .malformedManifest:
                try FileManager.default.removeItem(at: manifestURL)
                try Data("{\"format\": \"hana.snapshot\", \"formatVersion\": 1, ".utf8).write(to: manifestURL)
                return
            case .countMismatch:
                var counts = try #require(manifest["counts"] as? [String: Any])
                counts["tasks"] = (counts["tasks"] as? Int ?? 0) + 1
                manifest["counts"] = counts
            case .wrongID:
                manifest["id"] = "20260101T000000Z-00000000"
            case .extraFile:
                try Data("stray".utf8).write(to: directory.appendingPathComponent("collection.sqlite-wal"))
            }
            try FileManager.default.removeItem(at: manifestURL)
            try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL)
        }

        /// Edits a detached copy with plain SQLite, as an external tamperer would.
        private func mutateDatabase(_ url: URL, _ change: (Database) throws -> Void) throws {
            let queue = try DatabaseQueue(path: url.path)
            try queue.writeWithoutTransaction { try change($0) }
            try queue.close()
        }
    }

    @Test func failedSnapshotsPublishNothingAndPreserveSourceAndEarlierCopies() async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        let g = store.generation
        _ = try await store.perform(.createNote(operation: UUID(), body: "Source"), in: g)
        let earlier = try await CollectionRecovery.createSnapshot(store, in: g)
        let snapshots = CollectionRecovery.snapshotsURL(fixture.location)
        let earlierTree = try FileTree(snapshots.appendingPathComponent(earlier.id))
        _ = try await store.perform(.createTask(operation: UUID(), title: "Later"), in: g)
        let contents = try await store.read(.contents, in: g)

        let failures: [(CollectionRecovery.Faults, CollectionRecoveryError)] = [
            (.init(failWrite: { $0 == "collection.sqlite" ? ENOSPC : nil }), .insufficientSpace),
            (.init(failWrite: { $0 == "close" ? EIO : nil }), .writeFailed(code: EIO)),
            (.init(failWrite: { $0 == "snapshot.json" ? EDQUOT : nil }), .insufficientSpace),
            (.init(failWrite: { $0 == "snapshot.json" ? EROFS : nil }), .readOnlyDestination),
        ]
        for (faults, expected) in failures {
            await #expect(throws: expected) { try await CollectionRecovery.createSnapshot(store, in: g, faults: faults) }
        }
        await #expect(throws: InjectedFailure.self) {
            try await CollectionRecovery.createSnapshot(store, in: g, faults: .init(beforePublish: { throw InjectedFailure() }))
        }
        // A real unwritable snapshot directory.
        #expect(chmod(snapshots.path, 0o500) == 0)
        await #expect(throws: CollectionRecoveryError.readOnlyDestination) { try await CollectionRecovery.createSnapshot(store, in: g) }
        #expect(chmod(snapshots.path, 0o700) == 0)

        #expect(try FileManager.default.contentsOfDirectory(atPath: snapshots.path) == [earlier.id])
        #expect(try FileTree(snapshots.appendingPathComponent(earlier.id)).files == earlierTree.files)
        #expect(try await store.read(.contents, in: g) == contents)
        #expect(CollectionRecovery.listSnapshots(fixture.location) == [.init(id: earlier.id, result: .success(earlier))])
        // Retry is explicit and succeeds.
        let retried = try await CollectionRecovery.createSnapshot(store, in: g)
        #expect(retried.taskCount == 1 && retried.id != earlier.id)
        await store.close()
        await #expect(throws: CollectionStoreError.closed) { try await CollectionRecovery.createSnapshot(store, in: g) }
    }

    @Test func anInterruptedSnapshotIsListedAsIncompleteNeverUsable() async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        let good = try await CollectionRecovery.createSnapshot(store, in: store.generation)
        await store.close()
        // What a process killed mid-snapshot leaves: a staging directory.
        let staging = CollectionRecovery.snapshotsURL(fixture.location).appendingPathComponent(".staging-\(UUID().uuidString)")
        #expect(mkdir(staging.path, 0o700) == 0)
        try Data("partial".utf8).write(to: staging.appendingPathComponent("collection.sqlite"))
        let listings = CollectionRecovery.listSnapshots(fixture.location)
        #expect(listings.count == 2)
        #expect(listings.first { $0.id == staging.lastPathComponent }?.result == .failure(.invalidPackage(.incomplete)))
        #expect(listings.filter(\.isUsable).map(\.id) == [good.id])
        // Not deleted automatically.
        #expect(FileManager.default.fileExists(atPath: staging.path))
    }

    @Test func unsavedTextNeverReachesASnapshot() async throws {
        let fixture = try TemporaryFixture()
        let sentinel = "HANA-UNSAVED-SENTINEL-\(UUID().uuidString)"
        let failNext = Switch()
        let store = try await CollectionStore.open(fixture.location, faults: .init(beforeCommit: { _ in
            if failNext.take() { throw InjectedFailure() }
        }))
        let g = store.generation
        let note = try await store.perform(.createNote(operation: UUID(), body: "Committed control"), in: g)
        failNext.set()
        await #expect(throws: InjectedFailure.self) {
            try await store.perform(.editNote(note.id, expectedRevision: 1, body: "Draft \(sentinel)"), in: g)
        }
        failNext.set()
        await #expect(throws: InjectedFailure.self) {
            try await store.perform(.createTask(operation: UUID(), title: "Draft \(sentinel)"), in: g)
        }
        let info = try await CollectionRecovery.createSnapshot(store, in: g)
        await store.close()
        let tree = try FileTree(CollectionRecovery.snapshotsURL(fixture.location).appendingPathComponent(info.id))
        #expect(tree.files.values.allSatisfy { $0.range(of: Data(sentinel.utf8)) == nil })
        #expect(tree.files.values.contains { $0.range(of: Data("Committed control".utf8)) != nil }, "positive control")
    }

    /// AC10: create and organize → restart → full export reconstruction →
    /// manual snapshot → independent disposable reopen, all agreeing.
    @Test func theBoundedFoundationJourneyAgreesEndToEnd() async throws {
        let fixture = try TemporaryFixture()
        let destination = try ExportDestination()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000))
        let first = try await CollectionStore.open(fixture.location, clock: clock.now)
        let organized = try await OrganizedCollection.populate(first, clock: clock)
        await first.close()

        let restarted = try await CollectionStore.open(fixture.location, clock: clock.now)
        let contents = try await restarted.read(.contents, in: restarted.generation)
        #expect(contents.notes == organized.notes && contents.tasks == organized.tasks)
        let export = try await CollectionRecovery.export(restarted, in: restarted.generation, to: destination.url, clock: clock.now)
        let snapshot = try await CollectionRecovery.createSnapshot(restarted, in: restarted.generation, clock: clock.now)
        await restarted.close()

        let decoded = try IndependentExportDecoder.decode(export.package)
        #expect(decoded.collectionID == contents.collectionID && decoded.notes == contents.notes && decoded.tasks == contents.tasks)
        let reopened = try await CollectionRecovery.reopenSnapshotCopy(fixture.location, id: snapshot.id,
                                                                        into: try TemporaryFixture().directory.appendingPathComponent("journey"))
        #expect(reopened == contents)
    }
}

/// Snapshots, and the bounded AC10 journey, through fresh
/// `Hana --collection-fixture` processes.
@Suite(.timeLimit(.minutes(1)))
struct CollectionSnapshotHarnessTests {
    @Test func theFoundationJourneyAcrossFreshProcesses() throws {
        let root = try HarnessRoot()
        let destination = try ExportDestination()
        // Create and organize.
        let note = try Harness.run(["create-note", root.path, "--operation", UUID().uuidString], stdin: "บันทึก journey\n- [ ] kept").event("note.created")
        let noteID = try #require(note["id"] as? String)
        _ = try Harness.run(["pin-note", root.path, "--id", noteID, "--revision", "1", "--pinned", "true"]).event("note.updated")
        var taskIDs: [String] = []
        for title in ["Third", "Second", "First"] {
            let created = try Harness.run(["create-task", root.path, "--operation", UUID().uuidString, "--placement", "today"], stdin: title)
                .event("task.created")
            taskIDs.insert(try #require(created["id"] as? String), at: 0)
        }
        _ = try Harness.run(["reorder-task", root.path, "--id", taskIDs[2], "--revision", "1", "--placement", "today",
                             "--order", taskIDs.joined(separator: ","), "--index", "0"]).event("task.updated")
        _ = try Harness.run(["complete-task", root.path, "--id", taskIDs[1], "--revision", "1"]).event("task.updated")

        // Restart is implicit: every step is a fresh process. Export and verify.
        let exported = try Harness.run(["export", root.path, "--destination", destination.url.path]).event("export.published")
        let package = destination.url.appendingPathComponent(try #require(exported["package"] as? String))
        _ = try Harness.run(["verify-export", package.path]).event("export.verified")
        let decoded = try IndependentExportDecoder.decode(package)
        #expect(decoded.notes.count == 1 && decoded.notes.first?.isPinned == true)
        #expect(decoded.tasks.count == 3 && decoded.tasks.filter(\.isCompleted).count == 1)

        // Snapshot, list, and reopen a copy in a new disposable root.
        let failed = try Harness.run(["create-snapshot", root.path, "--fail-write", "snapshot.json", "--errno", "\(ENOSPC)"])
        #expect(failed.status == 1 && failed.event("error")["error"] as? String == "insufficientSpace")
        let snapshot = try Harness.run(["create-snapshot", root.path]).event("snapshot.created")
        let id = try #require(snapshot["id"] as? String)
        #expect(snapshot["notes"] as? Int == 1 && snapshot["tasks"] as? Int == 3)
        let listed = try #require(try Harness.run(["list-snapshots", root.path]).event("snapshots")["snapshots"] as? [[String: Any]])
        #expect(listed.count == 1 && listed.first?["usable"] as? Bool == true && listed.first?["id"] as? String == id)
        let copyRoot = destination.url.appendingPathComponent("reopened-root").path
        let reopened = try Harness.run(["reopen-snapshot", root.path, "--id", id, "--into", copyRoot]).event("snapshot.reopened")
        let reopenedNotes = try #require(reopened["notes"] as? [[String: Any]])
        let current = try #require(try Harness.run(["read", root.path, "--view", "all"]).event("notes")["notes"] as? [[String: Any]])
        #expect(reopenedNotes.map { $0["bodySHA256"] as? String } == current.map { $0["bodySHA256"] as? String })
        #expect(reopenedNotes.first?["pinned"] as? Bool == true)
        let reopenedTasks = try #require(reopened["tasks"] as? [[String: Any]])
        let allTasks = try #require(try Harness.run(["read-tasks", root.path, "--view", "all"]).event("tasks")["tasks"] as? [[String: Any]])
        #expect(reopenedTasks.map { $0["orderKey"] is NSNull } == allTasks.map { $0["orderKey"] is NSNull })
        #expect(reopenedTasks.map { $0["titleSHA256"] as? String } == allTasks.map { $0["titleSHA256"] as? String })
        // The reopened copy is a separate disposable root; the snapshot is unchanged.
        let relisted = try #require(try Harness.run(["list-snapshots", root.path]).event("snapshots")["snapshots"] as? [[String: Any]])
        #expect(relisted.first?["databaseSHA256"] as? String == snapshot["databaseSHA256"] as? String)
    }
}
