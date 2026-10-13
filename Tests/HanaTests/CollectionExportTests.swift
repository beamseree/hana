import CryptoKit
import Foundation
import Testing
@testable import Hana

/// Issue #28: full export through Collection Recovery, checked by an
/// independent test-only decoder that shares no code with the exporter.
@Suite(.timeLimit(.minutes(1)))
struct CollectionExportTests {
    @Test func exportReconstructsEveryDomainFactAndExactNoteBytes() async throws {
        let fixture = try TemporaryFixture()
        let destination = try ExportDestination()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000.125))
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        try await OrganizedCollection.populate(store, clock: clock)
        let contents = try await store.read(.contents, in: store.generation)
        let result = try await CollectionRecovery.export(store, in: store.generation, to: destination.url, clock: clock.now)
        await store.close()

        #expect(result.package.lastPathComponent.hasPrefix("hana-export-"))
        #expect(result.noteCount == OrganizedCollection.noteBodies.count && result.taskCount == OrganizedCollection.taskTitles.count)
        #expect(result.collectionID == contents.collectionID && result.exportedAt == clock.now())
        let decoded = try IndependentExportDecoder.decode(result.package)
        #expect(decoded.collectionID == contents.collectionID)
        #expect(decoded.notes == contents.notes)
        #expect(decoded.tasks == contents.tasks)
        for note in contents.notes {
            let bytes = try Data(contentsOf: result.package.appendingPathComponent("notes/\(note.id.uuidString).md"))
            #expect(Array(bytes) == Array(note.body.utf8))
        }
        // Paths come from IDs only: no title-derived or unsafe-looking names.
        let names = try FileManager.default.contentsOfDirectory(atPath: result.package.appendingPathComponent("notes").path)
        #expect(Set(names) == Set(contents.notes.map { "\($0.id.uuidString).md" }))
        #expect(Set(try FileManager.default.contentsOfDirectory(atPath: result.package.path)) == ["manifest.json", "notes", "tasks.json"])
        // The production reader agrees.
        let read = try CollectionRecovery.readExport(result.package)
        #expect(read.notes == contents.notes && read.tasks == contents.tasks && read.collectionID == contents.collectionID)
        // Organization is present: pins, archive, every completion/archive combination and manual order.
        #expect(decoded.notes.contains { $0.isPinned && $0.archivedAt != nil })
        #expect(decoded.tasks.contains { $0.isCompleted && $0.archivedAt != nil })
        #expect(decoded.tasks.contains { $0.isCompleted && $0.archivedAt == nil })
        #expect(decoded.tasks.contains { !$0.isCompleted && $0.archivedAt != nil })
        #expect(decoded.tasks.filter { $0.placement == .today }.count == 2)
        // Only the package exists in the destination; nothing was staged or left behind.
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.url.path) == [result.package.lastPathComponent])
    }

    @Test func anEmptyCollectionExportsAndReadsBack() async throws {
        let fixture = try TemporaryFixture()
        let destination = try ExportDestination()
        let store = try await CollectionStore.open(fixture.location)
        let contents = try await store.read(.contents, in: store.generation)
        let result = try await CollectionRecovery.export(store, in: store.generation, to: destination.url)
        await store.close()
        #expect(result.noteCount == 0 && result.taskCount == 0)
        let decoded = try IndependentExportDecoder.decode(result.package)
        #expect(decoded.notes.isEmpty && decoded.tasks.isEmpty && decoded.collectionID == contents.collectionID)
        #expect(try CollectionRecovery.readExport(result.package).notes.isEmpty)
    }

    @Test func laterExportsNeverOverwriteEarlierOnes() async throws {
        let fixture = try TemporaryFixture()
        let destination = try ExportDestination()
        let store = try await CollectionStore.open(fixture.location)
        _ = try await store.perform(.createNote(operation: UUID(), body: "First"), in: store.generation)
        let first = try await CollectionRecovery.export(store, in: store.generation, to: destination.url)
        let before = try FileTree(first.package)
        _ = try await store.perform(.createNote(operation: UUID(), body: "Second"), in: store.generation)
        let second = try await CollectionRecovery.export(store, in: store.generation, to: destination.url)
        await store.close()
        #expect(first.package != second.package)
        #expect(try FileTree(first.package).files == before.files)
        #expect(try IndependentExportDecoder.decode(first.package).notes.count == 1)
        #expect(try IndependentExportDecoder.decode(second.package).notes.count == 2)
    }

    @Test func exportsDuringWritesDescribeOneCommittedState() async throws {
        let fixture = try TemporaryFixture()
        let destination = try ExportDestination()
        let store = try await CollectionStore.open(fixture.location)
        let g = store.generation
        // Each round creates task n, then sets the counter note to n. Every
        // committed state therefore has tasks == counter or counter + 1; a torn
        // read across rounds would break that.
        let counter = try await store.perform(.createNote(operation: UUID(), body: "Count 0"), in: g)
        let rounds = 60
        let writer = Task {
            var revision = counter.revision
            for round in 1...rounds {
                _ = try await store.perform(.createTask(operation: UUID(), title: "Task \(round)"), in: g)
                revision = try await store.perform(.editNote(counter.id, expectedRevision: revision, body: "Count \(round)"), in: g).revision
            }
        }
        var packages: [URL] = []
        while packages.count < 8 {
            packages.append(try await CollectionRecovery.export(store, in: g, to: destination.url).package)
        }
        try await writer.value
        packages.append(try await CollectionRecovery.export(store, in: g, to: destination.url).package)
        await store.close()

        for package in packages {
            let decoded = try IndependentExportDecoder.decode(package)
            let note = try #require(decoded.notes.first)
            let count = try #require(Int(note.body.dropFirst("Count ".count)))
            #expect(decoded.tasks.count == count || decoded.tasks.count == count + 1, "torn export: \(count) vs \(decoded.tasks.count)")
            #expect(note.revision == Int64(count) + 1)
        }
        let last = try IndependentExportDecoder.decode(try #require(packages.last))
        #expect(last.tasks.count == rounds && last.notes.first?.body == "Count \(rounds)")
    }

    @Test(arguments: PackageTampering.allCases)
    func tamperedOrUnsupportedPackagesAreRefused(_ tampering: PackageTampering) async throws {
        let fixture = try TemporaryFixture()
        let destination = try ExportDestination()
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000))
        let store = try await CollectionStore.open(fixture.location, clock: clock.now)
        try await OrganizedCollection.populate(store, clock: clock)
        let good = try await CollectionRecovery.export(store, in: store.generation, to: destination.url).package
        await store.close()
        let copy = destination.url.appendingPathComponent("tampered", isDirectory: true)
        try FileManager.default.copyItem(at: good, to: copy)
        try tampering.apply(to: copy)
        #expect(throws: tampering.expected) { _ = try CollectionRecovery.readExport(copy) }
        // The original is still valid.
        _ = try CollectionRecovery.readExport(good)
    }

    enum PackageTampering: CaseIterable, Sendable {
        case missingNote, changedNote, extraFile, symlinkedNote, futureVersion, wrongFormat, countMismatch,
             pathTraversal, domainViolation, titleMismatch, malformedJSON, invalidUTF8

        var expected: CollectionRecoveryError {
            switch self {
            case .missingNote: .invalidPackage(.missingFile)
            case .changedNote: .invalidPackage(.hashMismatch)
            case .extraFile, .symlinkedNote: .invalidPackage(.unexpectedFile)
            case .futureVersion: .unsupportedFormat(version: 2)
            case .wrongFormat, .malformedJSON, .pathTraversal, .invalidUTF8: .invalidPackage(.malformed)
            case .countMismatch: .invalidPackage(.countMismatch)
            case .domainViolation, .titleMismatch: .invalidPackage(.domainViolation)
            }
        }

        func apply(to package: URL) throws {
            let manifestURL = package.appendingPathComponent("manifest.json")
            var manifest = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
            var notes = try #require(manifest["notes"] as? [[String: Any]])
            var files = try #require(manifest["files"] as? [String: [String: Any]])
            let firstPath = try #require(notes.first?["path"] as? String)
            let firstURL = package.appendingPathComponent(firstPath)
            /// Replaces a listed file and records its new size and hash, so
            /// only the intended defect remains.
            func rewrite(_ path: String, _ data: Data) throws {
                try FileManager.default.removeItem(at: package.appendingPathComponent(path))
                try data.write(to: package.appendingPathComponent(path))
                files[path] = ["bytes": data.count, "sha256": CollectionRecovery.hex(SHA256.hash(data: data))]
            }
            switch self {
            case .missingNote:
                try FileManager.default.removeItem(at: firstURL)
            case .changedNote:
                let handle = try FileHandle(forWritingTo: firstURL)
                _ = try handle.seekToEnd()
                try handle.write(contentsOf: Data(" ".utf8))
                try handle.close()
            case .extraFile:
                try Data("stray".utf8).write(to: package.appendingPathComponent("notes/extra.md"))
            case .symlinkedNote:
                let data = try Data(contentsOf: firstURL)
                try FileManager.default.removeItem(at: firstURL)
                let target = package.deletingLastPathComponent().appendingPathComponent("outside.md")
                try data.write(to: target)
                try FileManager.default.createSymbolicLink(at: firstURL, withDestinationURL: target)
            case .futureVersion:
                manifest["formatVersion"] = 2
            case .wrongFormat:
                manifest["format"] = "something.else"
            case .countMismatch:
                var counts = try #require(manifest["counts"] as? [String: Any])
                counts["notes"] = notes.count + 1
                manifest["counts"] = counts
            case .pathTraversal:
                notes[0]["path"] = "../\(firstPath)"
            case .domainViolation:
                // A completed task that still claims an Inbox placement.
                let tasksData = try Data(contentsOf: package.appendingPathComponent("tasks.json"))
                var tasksFile = try #require(try JSONSerialization.jsonObject(with: tasksData) as? [String: Any])
                var tasks = try #require(tasksFile["tasks"] as? [[String: Any]])
                let index = try #require(tasks.firstIndex { !($0["completedAt"] is NSNull) && $0["archivedAt"] is NSNull })
                tasks[index]["placement"] = "inbox"
                tasks[index]["orderKey"] = 0
                tasksFile["tasks"] = tasks
                try rewrite("tasks.json", try JSONSerialization.data(withJSONObject: tasksFile))
            case .titleMismatch:
                notes[0]["title"] = "Not the first line"
            case .malformedJSON:
                try rewrite("tasks.json", Data("{\"format\": \"hana.tasks\", \"formatVersion\": 1, \"tasks\": [".utf8))
            case .invalidUTF8:
                try rewrite(firstPath, Data([0x41, 0xFF, 0xFE, 0x42]))
            }
            manifest["notes"] = notes
            manifest["files"] = files
            try FileManager.default.removeItem(at: manifestURL)
            try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]).write(to: manifestURL)
        }
    }

    @Test func failedExportsPublishNothingAndPreserveEarlierOnes() async throws {
        let fixture = try TemporaryFixture()
        let destination = try ExportDestination()
        let store = try await CollectionStore.open(fixture.location)
        let g = store.generation
        let note = try await store.perform(.createNote(operation: UUID(), body: "Keep"), in: g)
        _ = try await store.perform(.createTask(operation: UUID(), title: "Keep too"), in: g)
        let earlier = try await CollectionRecovery.export(store, in: g, to: destination.url)
        let earlierTree = try FileTree(earlier.package)
        let contents = try await store.read(.contents, in: g)
        let notePath = "notes/\(note.id.uuidString).md"

        let failures: [(CollectionRecovery.Faults, CollectionRecoveryError)] = [
            (.init(failWrite: { $0 == notePath ? ENOSPC : nil }), .insufficientSpace),
            (.init(failWrite: { $0 == "tasks.json" ? EDQUOT : nil }), .insufficientSpace),
            (.init(failWrite: { $0 == "manifest.json" ? EIO : nil }), .writeFailed(code: EIO)),
            (.init(failWrite: { $0 == "manifest.json" ? EROFS : nil }), .readOnlyDestination),
        ]
        for (faults, expected) in failures {
            await #expect(throws: expected) {
                try await CollectionRecovery.export(store, in: g, to: destination.url, faults: faults)
            }
        }
        await #expect(throws: InjectedFailure.self) {
            try await CollectionRecovery.export(store, in: g, to: destination.url,
                                                faults: .init(beforePublish: { throw InjectedFailure() }))
        }
        // A real read-only destination.
        #expect(chmod(destination.url.path, 0o500) == 0)
        await #expect(throws: CollectionRecoveryError.readOnlyDestination) {
            try await CollectionRecovery.export(store, in: g, to: destination.url)
        }
        #expect(chmod(destination.url.path, 0o700) == 0)
        // Missing destinations and collection roots are refused before any write.
        await #expect(throws: CollectionRecoveryError.destinationUnavailable) {
            try await CollectionRecovery.export(store, in: g, to: destination.url.appendingPathComponent("missing"))
        }
        for inside in [fixture.location.root, fixture.location.collectionDirectory] {
            await #expect(throws: CollectionRecoveryError.destinationInsideCollection) {
                try await CollectionRecovery.export(store, in: g, to: inside)
            }
        }

        // Only the earlier package remains, unchanged; the source is unchanged.
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.url.path) == [earlier.package.lastPathComponent])
        #expect(try FileTree(earlier.package).files == earlierTree.files)
        #expect(try await store.read(.contents, in: g) == contents)
        let rootTree = try FileTree(fixture.location.root)
        #expect(!rootTree.files.keys.contains { $0.contains("hana-export") })
        await store.close()
        await #expect(throws: CollectionStoreError.closed) {
            try await CollectionRecovery.export(store, in: g, to: destination.url)
        }
    }

    @Test func unsavedTextAndCreationReceiptsAreNeverExported() async throws {
        let fixture = try TemporaryFixture()
        let destination = try ExportDestination()
        let sentinel = "HANA-UNSAVED-SENTINEL-\(UUID().uuidString)"
        let failNext = Switch()
        let store = try await CollectionStore.open(fixture.location, faults: .init(beforeCommit: { _ in
            if failNext.take() { throw InjectedFailure() }
        }))
        let g = store.generation
        let noteOperation = UUID(), taskOperation = UUID()
        let note = try await store.perform(.createNote(operation: noteOperation, body: "Saved"), in: g)
        _ = try await store.perform(.createTask(operation: taskOperation, title: "Saved task"), in: g)
        failNext.set()
        await #expect(throws: InjectedFailure.self) {
            try await store.perform(.editNote(note.id, expectedRevision: 1, body: "Draft \(sentinel)"), in: g)
        }
        failNext.set()
        await #expect(throws: InjectedFailure.self) {
            try await store.perform(.createTask(operation: UUID(), title: "Draft \(sentinel)"), in: g)
        }
        let result = try await CollectionRecovery.export(store, in: g, to: destination.url)
        await store.close()
        let tree = try FileTree(result.package)
        for (path, data) in tree.files {
            for forbidden in [sentinel, noteOperation.uuidString, taskOperation.uuidString, "receipt", "payload"] {
                #expect(data.range(of: Data(forbidden.utf8)) == nil, "\(forbidden) found in \(path)")
            }
        }
        #expect(tree.files.values.contains { $0.range(of: Data("Saved task".utf8)) != nil }, "positive control")
    }
}

/// Export through fresh `Hana --collection-fixture` processes.
@Suite(.timeLimit(.minutes(1)))
struct CollectionExportHarnessTests {
    @Test func exportAndVerifyAcrossFreshProcesses() throws {
        let root = try HarnessRoot()
        let destination = try ExportDestination()
        _ = try Harness.run(["create-note", root.path, "--operation", UUID().uuidString], stdin: "บันทึก exported")
        _ = try Harness.run(["create-task", root.path, "--operation", UUID().uuidString, "--placement", "today"], stdin: "Task")
        let exported = try Harness.run(["export", root.path, "--destination", destination.url.path]).event("export.published")
        #expect(exported["notes"] as? Int == 1 && exported["tasks"] as? Int == 1)
        let package = destination.url.appendingPathComponent(try #require(exported["package"] as? String))
        let verified = try Harness.run(["verify-export", package.path]).event("export.verified")
        #expect(verified["collectionID"] as? String == exported["collectionID"] as? String)
        #expect(try IndependentExportDecoder.decode(package).notes.first?.body == "บันทึก exported")

        let failed = try Harness.run(["export", root.path, "--destination", destination.url.path,
                                      "--fail-write", "tasks.json", "--errno", "\(ENOSPC)"])
        #expect(failed.status == 1 && failed.event("error")["error"] as? String == "insufficientSpace")
        let unpublished = try Harness.run(["export", root.path, "--destination", destination.url.path, "--fail-publish", "true"])
        #expect(unpublished.status == 1 && unpublished.event("error")["error"] as? String == "injectedFailure")
        #expect(try FileManager.default.contentsOfDirectory(atPath: destination.url.path) == [package.lastPathComponent])

        try Data("stray".utf8).write(to: package.appendingPathComponent("stray.txt"))
        let refused = try Harness.run(["verify-export", package.path])
        #expect(refused.status == 1 && refused.event("error")["error"] as? String == "invalidPackage(unexpectedFile)")
    }
}

/// A fresh empty export destination below the temporary directory.
struct ExportDestination {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("hana-exports-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    }
}

/// Reconstructs collection facts from an export package using only
/// `JSONSerialization` and file reads, independently of the exporter's types.
/// Test-only; not a user-facing import.
enum IndependentExportDecoder {
    struct Decoded {
        let collectionID: UUID
        let notes: [Note]
        let tasks: [TaskItem]
    }

    struct Failure: Error { let reason: String }

    static func decode(_ package: URL) throws -> Decoded {
        let manifest = try object(package.appendingPathComponent("manifest.json"))
        let tasksFile = try object(package.appendingPathComponent("tasks.json"))
        guard manifest["format"] as? String == "hana.collection-export", manifest["formatVersion"] as? Int == 1,
              tasksFile["format"] as? String == "hana.tasks", tasksFile["formatVersion"] as? Int == 1,
              let collection = manifest["collectionID"] as? String, let collectionID = UUID(uuidString: collection),
              tasksFile["collectionID"] as? String == collection,
              let noteEntries = manifest["notes"] as? [[String: Any]], let taskEntries = tasksFile["tasks"] as? [[String: Any]]
        else { throw Failure(reason: "header") }

        let notes = try noteEntries.map { entry -> Note in
            guard let id = (entry["id"] as? String).flatMap(UUID.init(uuidString:)), let path = entry["path"] as? String,
                  let pinned = entry["pinned"] as? Bool, let revision = (entry["revision"] as? NSNumber)?.int64Value
            else { throw Failure(reason: "note entry") }
            let bytes = try Data(contentsOf: package.appendingPathComponent(path))
            let body = String(decoding: bytes, as: UTF8.self)
            guard Array(body.utf8) == Array(bytes) else { throw Failure(reason: "note bytes") }
            return Note(id: id, body: body, createdAt: try date(entry["createdAt"]), contentEditedAt: try date(entry["contentEditedAt"]),
                        updatedAt: try date(entry["updatedAt"]), revision: revision, isPinned: pinned,
                        archivedAt: try optionalDate(entry["archivedAt"]))
        }
        let tasks = try taskEntries.map { entry -> TaskItem in
            guard let id = (entry["id"] as? String).flatMap(UUID.init(uuidString:)), let title = entry["title"] as? String,
                  let revision = (entry["revision"] as? NSNumber)?.int64Value
            else { throw Failure(reason: "task entry") }
            let placement: TaskPlacement?
            switch entry["placement"] {
            case let raw as String: placement = TaskPlacement(rawValue: raw)
            case is NSNull: placement = nil
            default: throw Failure(reason: "placement")
            }
            let orderKey: Int64?
            switch entry["orderKey"] {
            case let number as NSNumber: orderKey = number.int64Value
            case is NSNull: orderKey = nil
            default: throw Failure(reason: "order key")
            }
            return TaskItem(id: id, title: title, createdAt: try date(entry["createdAt"]),
                            contentEditedAt: try date(entry["contentEditedAt"]), updatedAt: try date(entry["updatedAt"]),
                            revision: revision, completedAt: try optionalDate(entry["completedAt"]),
                            archivedAt: try optionalDate(entry["archivedAt"]), placement: placement, orderKey: orderKey)
        }
        return Decoded(collectionID: collectionID, notes: notes.sorted { $0.id.uuidString < $1.id.uuidString },
                       tasks: tasks.sorted { $0.id.uuidString < $1.id.uuidString })
    }

    private static func object(_ url: URL) throws -> [String: Any] {
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        else { throw Failure(reason: "json") }
        return object
    }

    /// Integer UTC milliseconds since 1970.
    private static func date(_ value: Any?) throws -> Date {
        guard let number = value as? NSNumber else { throw Failure(reason: "time") }
        return Date(timeIntervalSince1970: Double(number.int64Value) / 1000)
    }

    private static func optionalDate(_ value: Any?) throws -> Date? {
        if value is NSNull { return nil }
        return try date(value)
    }
}
