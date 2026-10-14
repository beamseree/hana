import CryptoKit
import GRDB
import Foundation
import Testing
import Synchronization
@testable import Hana

@Suite(.timeLimit(.minutes(1)))
struct CollectionSnapshotTests {
    @Test func snapshotReopensEveryOrganizedFactWithoutSourceWALOrUnsavedCapture() async throws {
        let fixture = try TemporaryFixture()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000.250))
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let organized = try await OrganizedCollection.build(in: store, clock: clock)
        let unsaved = "UNSAVED-SNAPSHOT-\(UUID())"
        let catalog = fixture.directory.appendingPathComponent("Snapshots")
        let snapshot = try await CollectionRecovery.createSnapshot(from: store, in: store.generation, destination: catalog)
        #expect(snapshot.manifest.noteCount == 7)
        #expect(snapshot.manifest.taskCount == 14)
        #expect(snapshot.manifest.collectionID == organized.views.records.collectionID)
        await store.close()
        // The source is gone; only the closed single-file backup is available.
        try FileManager.default.removeItem(at: fixture.location.collectionDirectory)
        let reopened = try await CollectionRecovery.reopenSnapshot(at: snapshot.url,
            disposableRoot: fixture.directory.appendingPathComponent("validation"))
        #expect(reopened.generation != store.generation)
        #expect(try await OrganizedCollection.views(of: reopened) == organized.views)
        await reopened.close()
        for name in ["collection.sqlite", "manifest.json"] {
            #expect(try Data(contentsOf: snapshot.url.appendingPathComponent(name)).range(of: Data(unsaved.utf8)) == nil)
        }
    }
    @Test(arguments: ["valid", "truncated", "future-schema", "future-manifest", "bad-count", "bad-hash", "bad-identity",
                      "bad-time", "bad-name", "missing-manifest", "incomplete", "blank-note", "multiline-task", "bad-utf8",
                      "foreign-key", "invalid-placement", "symlink", "missing-table", "lowercase-note-id", "lowercase-task-id"])
    func onlyCompleteCompatibleValidatedSnapshotsAreUsable(_ damage: String) async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        _ = try await store.perform(.createNote(operation: UUID(), body: "Saved"), in: store.generation)
        _ = try await store.perform(.createTask(operation: UUID(), title: "Task"), in: store.generation)
        let catalog = fixture.directory.appendingPathComponent("Snapshots")
        let snapshot = try await CollectionRecovery.createSnapshot(from: store, in: store.generation, destination: catalog)
        await store.close()
        var candidate = snapshot.url
        let database = candidate.appendingPathComponent("collection.sqlite")
        let manifestURL = candidate.appendingPathComponent("manifest.json")
        var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        switch damage {
        case "truncated": try Data("not sqlite".utf8).write(to: database)
        case "future-schema", "blank-note", "multiline-task", "bad-utf8", "foreign-key", "invalid-placement", "missing-table", "lowercase-note-id", "lowercase-task-id":
            var config = Configuration(); config.foreignKeysEnabled = false
            let db = try DatabaseQueue(path: database.path, configuration: config)
            try await db.write { db in
                try db.execute(sql: "PRAGMA ignore_check_constraints = ON")
                let sql: String
                switch damage {
                case "future-schema": sql = "PRAGMA user_version = 999"
                case "missing-table": sql = "DROP TABLE creation_receipt"
                case "blank-note": sql = "UPDATE note SET body = '   '"
                case "multiline-task": sql = "UPDATE task SET title = 'one' || char(11) || 'two'"
                case "bad-utf8": sql = "UPDATE note SET body = CAST(x'fffe' AS TEXT)"
                case "foreign-key": sql = "UPDATE creation_receipt SET note_id = '11111111-1111-1111-1111-111111111111' WHERE note_id IS NOT NULL"
                // Keep foreign keys and the manifest hash valid so rejection
                // depends on the ID representation, not unrelated corruption.
                case "lowercase-note-id": sql = "UPDATE note SET id = 'abcdefab-1234-4567-89ab-abcdefabcdef'; UPDATE creation_receipt SET note_id = 'abcdefab-1234-4567-89ab-abcdefabcdef' WHERE note_id IS NOT NULL"
                case "lowercase-task-id": sql = "UPDATE task SET id = 'abcdefab-1234-4567-89ab-abcdefabcdef'; UPDATE creation_receipt SET task_id = 'abcdefab-1234-4567-89ab-abcdefabcdef' WHERE task_id IS NOT NULL"
                default: sql = "UPDATE task SET placement = NULL, order_key = NULL"
                }
                try db.execute(sql: sql)
            }
            try db.close()
            manifest["databaseSHA256"] = SHA256.hash(data: try Data(contentsOf: database)).map { String(format: "%02x", $0) }.joined()
        case "future-manifest": manifest["formatVersion"] = 999
        case "bad-count": manifest["noteCount"] = 99
        case "bad-hash": manifest["databaseSHA256"] = String(repeating: "0", count: 64)
        case "bad-identity": manifest["collectionID"] = UUID().uuidString
        case "bad-time": manifest["capturedAtUTC"] = "yesterday"
        case "bad-name", "incomplete":
            candidate = catalog.appendingPathComponent(damage == "incomplete" ? ".incomplete-test" : "snapshot-\(UUID())")
            try FileManager.default.moveItem(at: snapshot.url, to: candidate)
        case "symlink":
            try FileManager.default.moveItem(at: database, to: fixture.directory.appendingPathComponent("outside.sqlite"))
            try FileManager.default.createSymbolicLink(at: database, withDestinationURL: fixture.directory.appendingPathComponent("outside.sqlite"))
        default: break
        }
        if damage != "bad-name" && damage != "incomplete" {
            try JSONSerialization.data(withJSONObject: manifest).write(to: manifestURL)
        }
        if damage == "missing-manifest" { try FileManager.default.removeItem(at: manifestURL) }
        let inspection = await CollectionRecovery.inspectSnapshot(at: candidate)
        #expect(inspection.isUsable == (damage == "valid"))
        #expect(try await CollectionRecovery.listSnapshots(in: catalog).filter(\.isUsable).count == (damage == "valid" ? 1 : 0))
        if damage != "valid" {
            await #expect(throws: (any Error).self) {
                try await CollectionRecovery.reopenSnapshot(at: candidate, disposableRoot: fixture.directory.appendingPathComponent("verification"))
            }
            #expect(!FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent("verification").path))
        }
    }

    @Test func reopenedCanonicalIdentifiersSupportReadsAndMutations() async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        let note = try await store.perform(.createNote(operation: UUID(), body: "Saved note"), in: store.generation)
        let task = try await store.perform(.createTask(operation: UUID(), title: "Saved task"), in: store.generation)
        let snapshot = try await CollectionRecovery.createSnapshot(from: store, in: store.generation,
            destination: fixture.directory.appendingPathComponent("Snapshots"))
        await store.close()
        let database = snapshot.url.appendingPathComponent("collection.sqlite")
        let before = try Data(contentsOf: database)
        let reopened = try await CollectionRecovery.reopenSnapshot(at: snapshot.url,
            disposableRoot: fixture.directory.appendingPathComponent("verification"))
        #expect(try await reopened.read(.note(note.id), in: reopened.generation) == note)
        #expect(try await reopened.read(.task(task.id), in: reopened.generation) == task)
        let pinned = try await reopened.perform(.setNotePinned(note.id, true, expectedRevision: note.revision), in: reopened.generation)
        let edited = try await reopened.perform(.editTaskTitle(task.id, expectedRevision: task.revision, title: "Edited task"), in: reopened.generation)
        #expect(pinned.isPinned)
        #expect(edited.title == "Edited task")
        #expect(try await reopened.read(.note(note.id), in: reopened.generation) == pinned)
        #expect(try await reopened.read(.task(task.id), in: reopened.generation) == edited)
        await reopened.close()
        #expect(try Data(contentsOf: database) == before)
    }

    @Test func captureBarrierIncludesCommittedWALAndExcludesAConcurrentLaterCommand() async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        let first = try await store.perform(.createNote(operation: UUID(), body: "Committed in WAL"), in: store.generation)
        #expect(try Data(contentsOf: URL(fileURLWithPath: store.location.databaseURL.path + "-wal")).count > 0)
        let held = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let backup = Task {
            try await CollectionRecovery.createSnapshot(from: store, in: store.generation,
                destination: fixture.directory.appendingPathComponent("Snapshots"),
                faults: .init(captureBarrier: { #expect(!Thread.isMainThread); held.signal(); release.wait() }))
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { held.wait(); continuation.resume() }
        }
        let laterStarted = DispatchSemaphore(value: 0)
        let later = Task {
            laterStarted.signal()
            return try await store.perform(.createNote(operation: UUID(), body: "Later command"), in: store.generation)
        }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { laterStarted.wait(); continuation.resume() }
        }
        release.signal()
        let snapshot = try await backup.value
        let second = try await later.value
        #expect(try await store.read(.notes, in: store.generation).contains(second))
        let reopened = try await CollectionRecovery.reopenSnapshot(at: snapshot.url,
            disposableRoot: fixture.directory.appendingPathComponent("verification"))
        #expect(try await reopened.read(.notes, in: reopened.generation) == [first])
        #expect(snapshot.manifest.noteCount == 1)
        await reopened.close()
        await store.close()
    }

    @Test(arguments: ["staging", "capturing", "closing", "validating", "writingManifest", "publishing"])
    func failedAttemptPreservesSourceAndGoodSnapshotAndRetryIsExplicit(_ point: String) async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        _ = try await store.perform(.createNote(operation: UUID(), body: "Keep me"), in: store.generation)
        let catalog = fixture.directory.appendingPathComponent("Snapshots")
        let good = try await CollectionRecovery.createSnapshot(from: store, in: store.generation, destination: catalog)
        let bytes = try Data(contentsOf: good.url.appendingPathComponent("collection.sqlite"))
        let before = try await store.read(.allRecords, in: store.generation)
        let states = Mutex<[CollectionRecovery.SnapshotPhase]>([])
        await #expect(throws: CollectionRecovery.SnapshotError.fileFailure(code: ENOSPC)) {
            try await CollectionRecovery.createSnapshot(from: store, in: store.generation, destination: catalog,
                faults: .init(atPhase: { phase in
                    if phase.rawValue == point { throw CollectionRecovery.SnapshotError.fileFailure(code: ENOSPC) }
                }), onStatus: { phase in states.withLock { $0.append(phase) } })
        }
        #expect(states.withLock { $0.last } == .failed)
        #expect(!states.withLock { $0.contains(.complete) })
        #expect(try await store.read(.allRecords, in: store.generation) == before)
        #expect(try Data(contentsOf: good.url.appendingPathComponent("collection.sqlite")) == bytes)
        #expect(try await CollectionRecovery.listSnapshots(in: catalog).filter(\.isUsable).count == 1)
        let retryStates = Mutex<[CollectionRecovery.SnapshotPhase]>([])
        let retry = try await CollectionRecovery.createSnapshot(from: store, in: store.generation, destination: catalog,
            onStatus: { phase in retryStates.withLock { $0.append(phase) } })
        #expect(retry.url != good.url)
        #expect(retryStates.withLock { $0 } == [.staging, .capturing, .closing, .validating, .writingManifest, .publishing, .complete])
        #expect(try await CollectionRecovery.listSnapshots(in: catalog).filter(\.isUsable).count == 2)
        await store.close()
    }

    @Test func readOnlyDestinationAndPublicationCollisionPreserveAllEarlierArtifacts() async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        let catalog = fixture.directory.appendingPathComponent("Snapshots")
        let good = try await CollectionRecovery.createSnapshot(from: store, in: store.generation, destination: catalog)
        let before = try Data(contentsOf: good.url.appendingPathComponent("collection.sqlite"))
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: catalog.path)
        await #expect(throws: CollectionRecovery.SnapshotError.fileFailure(code: EACCES)) {
            try await CollectionRecovery.createSnapshot(from: store, in: store.generation, destination: catalog)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: catalog.path)
        await #expect(throws: CollectionRecovery.SnapshotError.publicationFailure(code: EEXIST)) {
            try await CollectionRecovery.createSnapshot(from: store, in: store.generation, destination: catalog,
                faults: .init(atPhase: { phase in
                    if phase == .publishing {
                        let candidates = try FileManager.default.contentsOfDirectory(at: catalog, includingPropertiesForKeys: nil)
                        let staging = try #require(candidates.first { $0.lastPathComponent.hasPrefix(".incomplete-") })
                        let name = staging.lastPathComponent.replacingOccurrences(of: ".incomplete-", with: "snapshot-")
                        try FileManager.default.createDirectory(at: catalog.appendingPathComponent(name), withIntermediateDirectories: false,
                            attributes: [.posixPermissions: 0o700])
                    }
                }))
        }
        #expect(try Data(contentsOf: good.url.appendingPathComponent("collection.sqlite")) == before)
        #expect(try await CollectionRecovery.listSnapshots(in: catalog).filter(\.isUsable).count == 1)
        await #expect(throws: CollectionRecovery.SnapshotError.unsafeLocation) {
            try await CollectionRecovery.createSnapshot(from: store, in: store.generation, destination: store.location.collectionDirectory)
        }
        // Inspection and writable disposable reopening leave the sole snapshot byte-identical.
        let manifest = try Data(contentsOf: good.url.appendingPathComponent("manifest.json"))
        let reopened = try await CollectionRecovery.reopenSnapshot(at: good.url,
            disposableRoot: fixture.directory.appendingPathComponent("verification"))
        _ = try await reopened.perform(.createNote(operation: UUID(), body: "Disposable only"), in: reopened.generation)
        await reopened.close()
        #expect(try Data(contentsOf: good.url.appendingPathComponent("collection.sqlite")) == before)
        #expect(try Data(contentsOf: good.url.appendingPathComponent("manifest.json")) == manifest)
        #expect(try Set(FileManager.default.contentsOfDirectory(atPath: good.url.path)) == ["collection.sqlite", "manifest.json"])
        #expect(try await store.read(.allRecords, in: store.generation).notes.isEmpty)
        await store.close()
    }

}
