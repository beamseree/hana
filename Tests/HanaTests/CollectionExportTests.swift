import Synchronization

import CryptoKit

import Foundation
import Testing
@testable import Hana

@Suite(.timeLimit(.minutes(1)))
struct CollectionExportTests {
    @Test func emptyCollectionPublishesACompleteVersionedPackage() async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        let expected = try await store.read(.allRecords, in: store.generation)
        let destination = fixture.location.root.deletingLastPathComponent()
        let result = try await CollectionRecovery.export(from: store, in: store.generation, to: destination)
        let manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: result.url.appendingPathComponent("manifest.json"))) as? [String: Any])
        let tasks = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: result.url.appendingPathComponent("tasks.json"))) as? [String: Any])
        #expect(manifest["formatVersion"] as? Int == 1)
        #expect(manifest["collectionID"] as? String == expected.collectionID.uuidString)
        #expect(manifest["noteCount"] as? Int == 0 && manifest["taskCount"] as? Int == 0)
        #expect((manifest["notes"] as? [Any])?.isEmpty == true)
        #expect(tasks["formatVersion"] as? Int == 1 && (tasks["tasks"] as? [Any])?.isEmpty == true)
        await store.close()
    }
}

extension CollectionExportTests {
    @Test func independentReconstructionPreservesExactBytesAndEveryOrganizedView() async throws {
        let fixture = try TemporaryFixture()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000.250))
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        let organized = try await OrganizedCollection.build(in: store, clock: clock)
        let result = try await CollectionRecovery.export(from: store, in: store.generation, to: fixture.directory)
        let reconstructed = try IndependentExportDecoder.records(at: result.url)
        #expect(reconstructed == organized.views.records)
        #expect(IndependentExportDecoder.views(reconstructed) == organized.views)
        // UUID paths preserve repeated titles and traversal-looking text as content.
        for note in organized.views.records.notes {
            #expect(try Data(contentsOf: result.url.appendingPathComponent("notes/\(note.id.uuidString).md")) == Data(note.body.utf8))
        }
        #expect(result.noteCount == 7 && result.taskCount == 14)
        await store.close()
    }
}

extension CollectionExportTests {
    @Test(arguments: ["valid", "missing-note", "changed-note", "invalid-utf8", "missing-tasks", "changed-tasks", "future-manifest", "future-tasks",
                      "count", "hash", "path", "id", "duplicate-note", "duplicate-task", "revision", "placement", "completed-placement",
                      "blank-note", "title", "multiline-task", "identity", "extra-file", "symlink-note", "symlink-package", "unpublished-stage"])
    func validatesTheCompletePackageAndRejectsCorruption(_ change: String) async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        _ = try await store.perform(.createNote(operation: UUID(), body: "Exact note\r\nไทย e\u{301}"), in: store.generation)
        _ = try await store.perform(.createTask(operation: UUID(), title: "Task"), in: store.generation)
        let result = try await CollectionRecovery.export(from: store, in: store.generation, to: fixture.directory)
        let manifestURL = result.url.appendingPathComponent("manifest.json")
        let tasksURL = result.url.appendingPathComponent("tasks.json")
        var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        var document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: tasksURL)) as? [String: Any])
        var notes = try #require(manifest["notes"] as? [[String: Any]])
        var tasks = try #require(document["tasks"] as? [[String: Any]])
        let noteURL = result.url.appendingPathComponent(try #require(notes[0]["path"] as? String))
        var checkedURL = result.url
        switch change {
        case "missing-note": try FileManager.default.removeItem(at: noteURL)
        case "changed-note": try Data("tampered".utf8).write(to: noteURL)
        case "invalid-utf8":
            let bytes = Data([0xFF, 0xFE]); try bytes.write(to: noteURL)
            notes[0]["sha256"] = testExportHash(bytes); notes[0]["byteCount"] = bytes.count
        case "missing-tasks": try FileManager.default.removeItem(at: tasksURL)
        case "changed-tasks": try Data("tampered".utf8).write(to: tasksURL)
        case "future-manifest": manifest["formatVersion"] = 999
        case "future-tasks": document["formatVersion"] = 999
        case "count": manifest["noteCount"] = 22
        case "hash": notes[0]["sha256"] = String(repeating: "0", count: 64)
        case "path": notes[0]["path"] = "../outside.md"
        case "id": notes[0]["id"] = "not-an-id"
        case "duplicate-note": notes.append(notes[0]); manifest["noteCount"] = 2
        case "duplicate-task": tasks.append(tasks[0]); manifest["taskCount"] = 2
        case "revision": tasks[0]["revision"] = 0
        case "placement": tasks[0]["placement"] = "someday"
        case "completed-placement": tasks[0]["completedAt"] = tasks[0]["updatedAt"]
        case "blank-note":
            let bytes = Data(" \n\t".utf8); try bytes.write(to: noteURL)
            notes[0]["sha256"] = testExportHash(bytes); notes[0]["byteCount"] = bytes.count
        case "title": notes[0]["title"] = "Wrong derived title"
        case "multiline-task": tasks[0]["title"] = "line\nline"
        case "identity": document["collectionID"] = UUID().uuidString
        case "extra-file": try Data().write(to: result.url.appendingPathComponent("receipt.json"))
        case "symlink-note":
            let outside = fixture.directory.appendingPathComponent("outside.md")
            try FileManager.default.moveItem(at: noteURL, to: outside)
            try FileManager.default.createSymbolicLink(at: noteURL, withDestinationURL: outside)
        case "unpublished-stage":
            checkedURL = fixture.directory.appendingPathComponent(".hana-export-\(UUID().uuidString).partial")
        case "symlink-package":
            checkedURL = fixture.directory.appendingPathComponent("alias")
            try FileManager.default.createSymbolicLink(at: checkedURL, withDestinationURL: result.url)
        default: break
        }
        manifest["notes"] = notes; document["tasks"] = tasks
        if !["missing-tasks", "changed-tasks"].contains(change) {
            let bytes = try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
            try bytes.write(to: tasksURL)
            manifest["tasksSHA256"] = testExportHash(bytes)
        }
        try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL)
        if change == "unpublished-stage" { try FileManager.default.moveItem(at: result.url, to: checkedURL) }
        if change == "valid" {
            let checked = try await CollectionRecovery.validateExport(at: checkedURL)
            #expect(checked.collectionID == result.collectionID && checked.noteCount == 1 && checked.taskCount == 1)
        } else {
            await #expect(throws: (any Error).self) { try await CollectionRecovery.validateExport(at: checkedURL) }
        }
        await store.close()
    }
}

private func testExportHash(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
}

extension CollectionExportTests {
    @Test(arguments: ["write", "readonly", "space", "publication", "invalid-stage"])
    func failedAttemptsPreserveTheSourceAndEarlierExports(_ failure: String) async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        _ = try await store.perform(.createNote(operation: UUID(), body: "Saved"), in: store.generation)
        let before = try await store.read(.allRecords, in: store.generation)
        let good = try await CollectionRecovery.export(from: store, in: store.generation, to: fixture.directory)
        let manifest = try Data(contentsOf: good.url.appendingPathComponent("manifest.json"))
        let faults = CollectionRecovery.ExportFaults(beforeWrite: { path in
            guard path == "tasks.json" else { return }
            switch failure {
            case "write": throw POSIXError(.EIO)
            case "readonly": throw POSIXError(.EROFS)
            case "space": throw POSIXError(.ENOSPC)
            default: break
            }
        }, beforePublish: { stage, target in
            if failure == "publication" {
                try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
                try Data("existing destination".utf8).write(to: target.appendingPathComponent("keep"))
            }
            if failure == "invalid-stage" { try FileManager.default.removeItem(at: stage.appendingPathComponent("tasks.json")) }
        })
        let expected: CollectionRecovery.ExportError = switch failure {
        case "write": .writeFailure(code: EIO)
        case "readonly": .readOnly
        case "space": .noSpace
        case "publication": .publicationFailure(code: EEXIST)
        default: .invalidPackage
        }
        await #expect(throws: expected) {
            try await CollectionRecovery.export(from: store, in: store.generation, to: fixture.directory, faults: faults)
        }
        #expect(try await store.read(.allRecords, in: store.generation) == before)
        #expect(try Data(contentsOf: good.url.appendingPathComponent("manifest.json")) == manifest)
        #expect(try IndependentExportDecoder.records(at: good.url) == before)
        let children = try FileManager.default.contentsOfDirectory(at: fixture.directory, includingPropertiesForKeys: nil)
        #expect(!children.contains { $0.lastPathComponent.hasPrefix(".hana-export-") })
        if failure == "publication" {
            let collision = try #require(children.first { $0.lastPathComponent != good.url.lastPathComponent && $0.lastPathComponent.hasPrefix("Hana-export-") })
            #expect(try Data(contentsOf: collision.appendingPathComponent("keep")) == Data("existing destination".utf8))
        }
        let retry = try await CollectionRecovery.export(from: store, in: store.generation, to: fixture.directory)
        #expect(retry.url != good.url)
        #expect(try IndependentExportDecoder.records(at: retry.url) == before)
        await store.close()
    }

    @Test func refusesSourceStorageAliasesAndRealUnwritableDestinations() async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        let alias = fixture.directory.appendingPathComponent("source-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.location.root)
        for destination in [fixture.location.root, fixture.location.collectionDirectory, alias,
                            CollectionLocation.defaultLiveRoot.appendingPathComponent("export")] {
            await #expect(throws: CollectionRecovery.ExportError.destinationRefused) {
                try await CollectionRecovery.export(from: store, in: store.generation, to: destination)
            }
        }
        let locked = fixture.directory.appendingPathComponent("locked")
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o500])
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        await #expect(throws: CollectionRecovery.ExportError.writeFailure(code: EACCES)) {
            try await CollectionRecovery.export(from: store, in: store.generation, to: locked)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: locked.path).isEmpty)
        await store.close()
    }
}

extension CollectionExportTests {
    @Test func editsStatusAndOrderContinueWhileAnEarlierCaptureIsBeingWritten() async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        let organized = try await OrganizedCollection.build(in: store, clock: FixedClock(Date()))
        let gate = ExportWriteGate()
        defer { gate.release.signal() }
        let export = Task {
            try await CollectionRecovery.export(from: store, in: store.generation, to: fixture.directory,
                                                faults: .init(beforeWrite: { path in
                if path == "tasks.json" { gate.reached.withLock { $0 = true }; gate.release.wait() }
            }))
        }
        while !gate.reached.withLock({ $0 }) { try await Task.sleep(for: .milliseconds(2)) }
        let note = try #require(organized.views.notes.first)
        _ = try await store.perform(.editNote(note.id, expectedRevision: note.revision, body: "Later edit"), in: store.generation)
        let task = try #require(organized.views.inbox.first)
        _ = try await store.perform(.completeTask(task.id, expectedRevision: task.revision), in: store.generation)
        let order = try await store.read(.inbox, in: store.generation).map(\.id)
        _ = try await store.perform(.reorderTask(order.last!, in: .inbox, after: nil, expectedOrder: order), in: store.generation)
        gate.release.signal()
        let result = try await export.value
        #expect(try IndependentExportDecoder.records(at: result.url) == organized.views.records)
        #expect(try await store.read(.allRecords, in: store.generation) != organized.views.records)
        let manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: result.url.appendingPathComponent("manifest.json"))) as? [String: Any])
        #expect(manifest["captureMethod"] as? String == "single-committed-store-read")
        #expect(manifest["captureStartedAt"] is Int64 && manifest["captureFinishedAt"] is Int64 && manifest["packagedAt"] is Int64)
        await store.close()
    }

    @Test func racingExportsMatchOneOfTheActualCommittedStates() async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        let g = store.generation
        let note = try await store.perform(.createNote(operation: UUID(), body: "Original"), in: g)
        for index in 0..<4 { _ = try await store.perform(.createTask(operation: UUID(), title: "Task \(index)"), in: g) }
        let before = try await store.read(.allRecords, in: g)
        async let writes: [CollectionRecords] = {
            var states = [before]
            for index in 0..<8 {
                let current = try #require(try await store.read(.note(note.id), in: g))
                _ = try await store.perform(.editNote(note.id, expectedRevision: current.revision, body: "Edit \(index)"), in: g)
                states.append(try await store.read(.allRecords, in: g))
                let order = try await store.read(.inbox, in: g)
                _ = try await store.perform(.reorderTask(order.last!.id, in: .inbox, after: nil, expectedOrder: order.map(\.id)), in: g)
                states.append(try await store.read(.allRecords, in: g))
                let task = try await store.read(.inbox, in: g)[0]
                let done = try await store.perform(.completeTask(task.id, expectedRevision: task.revision), in: g)
                states.append(try await store.read(.allRecords, in: g))
                _ = try await store.perform(.reopenTask(done.id, expectedRevision: done.revision), in: g)
                states.append(try await store.read(.allRecords, in: g))
            }
            return states
        }()
        async let exports: [CollectionRecovery.ExportResult] = withThrowingTaskGroup(of: CollectionRecovery.ExportResult.self) { group in
            for _ in 0..<20 {
                group.addTask { try await CollectionRecovery.export(from: store, in: g, to: fixture.directory) }
            }
            var results: [CollectionRecovery.ExportResult] = []
            for try await result in group { results.append(result) }
            return results
        }
        let (states, results) = try await (writes, exports)
        for result in results { #expect(try states.contains(IndependentExportDecoder.records(at: result.url))) }
        await store.close()
    }
}

private final class ExportWriteGate: Sendable {
    let reached = Mutex(false)
    let release = DispatchSemaphore(value: 0)
}
