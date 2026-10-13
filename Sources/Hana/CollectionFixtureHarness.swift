import CryptoKit
import Foundation

/// Fixture-only command-line harness over the production Collection Store:
/// `Hana --collection-fixture <action> <root> [options]`.
///
/// It accepts only marked disposable roots (never the live root, descendants or
/// aliases) and prints content-free JSON lines: IDs, revisions, timestamps,
/// counts and body digests, never note text. Normal launch does not use it.
///
/// - `create-root <root>`: create a new marked disposable root.
/// - `create-note <root> --operation <uuid> [--pause before-commit|after-commit] [--fail before-commit]`:
///   save the note body read from standard input while observing Notes.
/// - `edit-note <root> --id <uuid> --revision <n> [faults]`: replace the body
///   with standard input.
/// - `pin-note <root> --id <uuid> --revision <n> --pinned true|false [faults]`.
/// - `archive-note|restore-note <root> --id <uuid> --revision <n> [faults]`.
/// - `read <root> [--view notes|archive|all]`: summarize active Notes (default),
///   archived notes or every note record.
/// - `create-task <root> --operation <uuid> [--placement inbox|today] [faults]`:
///   save the task title read from standard input.
/// - `edit-task <root> --id <uuid> --revision <n> [faults]`: replace the title
///   with standard input.
/// - `move-task <root> --id <uuid> --revision <n> --to inbox|today [faults]`.
/// - `complete-task|reopen-task|archive-task|restore-task <root> --id <uuid> --revision <n> [faults]`.
/// - `reorder-task <root> --id <uuid> --revision <n> --placement inbox|today --order <uuid,…> --index <i> [faults]`:
///   move the task to position `i` of the list last read as `--order`.
/// - `read-tasks <root> [--view inbox|today|completed|archive|all]`: summarize
///   one task view (Inbox by default).
/// - `export <root> --destination <dir> [--fail-write <package path> --errno <n>] [--fail-publish true]`:
///   full export into a new package below `dir`.
/// - `verify-export <package>`: read back and validate a package.
/// - `runtime-report <root>`: linked SQLite identity and effective settings.
///
/// Faults on every command: `--pause before-commit|after-commit` and `--fail before-commit`.
enum CollectionFixtureHarness {
    static let flag = "--collection-fixture"

    private struct Usage: Error {}
    private struct InjectedFailure: Error {}

    static func run(_ arguments: [String]) async -> Int32 {
        do {
            guard arguments.count >= 2 else { throw Usage() }
            let root = URL(fileURLWithPath: arguments[1])
            let options = Dictionary(stride(from: 2, to: arguments.count - 1, by: 2).map { (arguments[$0], arguments[$0 + 1]) },
                                     uniquingKeysWith: { $1 })
            switch arguments[0] {
            case "create-root":
                _ = try CollectionLocation.createFixtureRoot(at: root)
                emit("fixture.root-created", [:])
            case "create-note":
                guard let operation = options["--operation"].flatMap(UUID.init(uuidString:)) else { throw Usage() }
                try await createNote(at: try CollectionLocation.fixture(root), operation: operation,
                                     pause: options["--pause"], fail: options["--fail"])
            case "edit-note", "pin-note", "archive-note", "restore-note":
                guard let id = options["--id"].flatMap(UUID.init(uuidString:)),
                      let revision = options["--revision"].flatMap({ Int64($0) }) else { throw Usage() }
                let command: CollectionCommand<Note>
                switch arguments[0] {
                case "edit-note":
                    let body = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                    command = .editNote(id, expectedRevision: revision, body: body)
                case "pin-note":
                    guard let pinned = options["--pinned"].flatMap({ Bool($0) }) else { throw Usage() }
                    command = .setNotePinned(id, pinned, expectedRevision: revision)
                case "archive-note": command = .archiveNote(id, expectedRevision: revision)
                default: command = .restoreNote(id, expectedRevision: revision)
                }
                let store = try await CollectionStore.open(try CollectionLocation.fixture(root),
                                                           faults: faults(pause: options["--pause"], fail: options["--fail"]))
                let note = try await store.perform(command, in: store.generation)
                await store.close()
                emit("note.updated", summary(note))
            case "create-task":
                guard let operation = options["--operation"].flatMap(UUID.init(uuidString:)),
                      let placement = TaskPlacement(rawValue: options["--placement"] ?? "inbox") else { throw Usage() }
                let title = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                let store = try await CollectionStore.open(try CollectionLocation.fixture(root),
                                                           faults: faults(pause: options["--pause"], fail: options["--fail"]))
                let task = try await store.perform(.createTask(operation: operation, title: title, placement: placement),
                                                   in: store.generation)
                await store.close()
                emit("task.created", summary(task))
            case "edit-task", "move-task", "reorder-task", "complete-task", "reopen-task", "archive-task", "restore-task":
                guard let id = options["--id"].flatMap(UUID.init(uuidString:)),
                      let revision = options["--revision"].flatMap({ Int64($0) }) else { throw Usage() }
                let command: CollectionCommand<TaskItem>
                switch arguments[0] {
                case "edit-task":
                    let title = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
                    command = .editTaskTitle(id, expectedRevision: revision, title: title)
                case "move-task":
                    guard let placement = options["--to"].flatMap({ TaskPlacement(rawValue: $0) }) else { throw Usage() }
                    command = .moveTask(id, to: placement, expectedRevision: revision)
                case "reorder-task":
                    guard let placement = options["--placement"].flatMap({ TaskPlacement(rawValue: $0) }),
                          let index = options["--index"].flatMap({ Int($0) }),
                          let order = options["--order"].map({ $0.split(separator: ",").map { UUID(uuidString: String($0)) } }),
                          !order.contains(nil)
                    else { throw Usage() }
                    command = .reorderTask(id, expectedRevision: revision, in: placement,
                                           expectedOrder: order.compactMap { $0 }, toIndex: index)
                case "complete-task": command = .completeTask(id, expectedRevision: revision)
                case "reopen-task": command = .reopenTask(id, expectedRevision: revision)
                case "archive-task": command = .archiveTask(id, expectedRevision: revision)
                default: command = .restoreTask(id, expectedRevision: revision)
                }
                let store = try await CollectionStore.open(try CollectionLocation.fixture(root),
                                                           faults: faults(pause: options["--pause"], fail: options["--fail"]))
                let task = try await store.perform(command, in: store.generation)
                await store.close()
                emit("task.updated", summary(task))
            case "read-tasks":
                let query: CollectionQuery<[TaskItem]>
                switch options["--view"] ?? "inbox" {
                case "inbox": query = .inbox
                case "today": query = .today
                case "completed": query = .completedTasks
                case "archive": query = .archivedTasks
                case "all": query = .allTasks
                default: throw Usage()
                }
                let store = try await CollectionStore.open(try CollectionLocation.fixture(root))
                let tasks = try await store.read(query, in: store.generation)
                await store.close()
                emit("tasks", ["count": tasks.count, "tasks": tasks.map(summary)])
            case "read":
                let query: CollectionQuery<[Note]>
                switch options["--view"] ?? "notes" {
                case "notes": query = .notes
                case "archive": query = .archivedNotes
                case "all": query = .allNotes
                default: throw Usage()
                }
                let store = try await CollectionStore.open(try CollectionLocation.fixture(root))
                let notes = try await store.read(query, in: store.generation)
                await store.close()
                emit("notes", ["count": notes.count, "notes": notes.map(summary)])
            case "export":
                guard let destination = options["--destination"].map({ URL(fileURLWithPath: $0, isDirectory: true) })
                else { throw Usage() }
                let failPath = options["--fail-write"]
                let failCode = options["--errno"].flatMap({ Int32($0) }) ?? EIO
                let failPublish = options["--fail-publish"] == "true"
                let faults = CollectionRecovery.Faults(
                    failWrite: { path in path == failPath ? failCode : nil },
                    beforePublish: { if failPublish { throw InjectedFailure() } })
                let store = try await CollectionStore.open(try CollectionLocation.fixture(root))
                let result: CollectionRecovery.ExportResult
                do {
                    result = try await CollectionRecovery.export(store, in: store.generation, to: destination, faults: faults)
                } catch {
                    await store.close()
                    throw error
                }
                await store.close()
                emit("export.published", ["package": result.package.lastPathComponent, "notes": result.noteCount,
                                          "tasks": result.taskCount, "manifestSHA256": result.manifestSHA256,
                                          "collectionID": result.collectionID.uuidString,
                                          "exportedAt": CollectionStore.milliseconds(result.exportedAt)])
            case "verify-export":
                let exported = try CollectionRecovery.readExport(root)
                emit("export.verified", ["notes": exported.notes.count, "tasks": exported.tasks.count,
                                         "collectionID": exported.collectionID.uuidString])
            case "runtime-report":
                let store = try await CollectionStore.open(try CollectionLocation.fixture(root))
                let report = try await store.runtimeReport()
                await store.close()
                let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(report))
                emit("runtime-report", ["report": object])
            default:
                throw Usage()
            }
            return 0
        } catch {
            emit("error", ["error": describe(error)])
            return 1
        }
    }

    /// Pauses forever (for an external kill) or fails at the named point.
    private static func faults(pause: String?, fail: String?) -> CollectionStore.Faults {
        let holdForever: @Sendable (String) -> Void = { point in
            emit("paused", ["at": point])
            while true { sleep(60) }
        }
        return CollectionStore.Faults(
            beforeCommit: { _ in
                if pause == "before-commit" { holdForever("before-commit") }
                if fail == "before-commit" { throw InjectedFailure() }
            },
            afterCommit: { if pause == "after-commit" { holdForever("after-commit") } })
    }

    private static func createNote(at location: CollectionLocation, operation: UUID, pause: String?, fail: String?) async throws {
        let body = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        let store = try await CollectionStore.open(location, faults: faults(pause: pause, fail: fail))
        var observed = store.observe(.notes, in: store.generation).makeAsyncIterator()
        let before = try await observed.next() ?? []
        let note = try await store.perform(.createNote(operation: operation, body: body), in: store.generation)
        var after = before
        while !after.contains(where: { $0.id == note.id }), let next = try await observed.next() { after = next }
        await store.close()
        var fields = summary(note)
        fields["observedBefore"] = before.count
        fields["observedAfter"] = after.count
        emit("note.created", fields)
    }

    private static func summary(_ note: Note) -> [String: Any] {
        let body = Data(note.body.utf8)
        return ["id": note.id.uuidString, "revision": note.revision, "bodyBytes": body.count,
                "bodySHA256": SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined(),
                "createdAt": CollectionStore.milliseconds(note.createdAt),
                "contentEditedAt": CollectionStore.milliseconds(note.contentEditedAt),
                "updatedAt": CollectionStore.milliseconds(note.updatedAt),
                "pinned": note.isPinned, "archived": note.archivedAt != nil,
                "archivedAt": note.archivedAt.map { CollectionStore.milliseconds($0) as Any } ?? NSNull()]
    }

    private static func summary(_ task: TaskItem) -> [String: Any] {
        let title = Data(task.title.utf8)
        func milliseconds(_ date: Date?) -> Any { date.map { CollectionStore.milliseconds($0) as Any } ?? NSNull() }
        return ["id": task.id.uuidString, "revision": task.revision, "titleBytes": title.count,
                "titleSHA256": SHA256.hash(data: title).map { String(format: "%02x", $0) }.joined(),
                "createdAt": CollectionStore.milliseconds(task.createdAt),
                "contentEditedAt": CollectionStore.milliseconds(task.contentEditedAt),
                "updatedAt": CollectionStore.milliseconds(task.updatedAt),
                "completedAt": milliseconds(task.completedAt), "archivedAt": milliseconds(task.archivedAt),
                "placement": task.placement.map { $0.rawValue as Any } ?? NSNull(),
                "orderKey": task.orderKey.map { $0 as Any } ?? NSNull()]
    }

    /// Error names only; never descriptions that could carry content or paths.
    private static func describe(_ error: any Error) -> String {
        switch error {
        case let error as CollectionStoreError:
            if case .unsupportedSchema(let version) = error { return "unsupportedSchema(\(version))" }
            if case .storageFailure(let code) = error { return "storageFailure(\(code))" }
            return "\(error)"
        case let error as CollectionRecoveryError:
            switch error {
            case .writeFailed(let code): return "writeFailed(\(code))"
            case .publicationFailed(let code): return "publicationFailed(\(code))"
            case .unsupportedFormat(let version): return "unsupportedFormat(\(version))"
            case .invalidPackage(let reason): return "invalidPackage(\(reason.rawValue))"
            default: return "\(error)"
            }
        case is InjectedFailure: return "injectedFailure"
        case is Usage: return "usage"
        default: return "unexpected"
        }
    }

    private static func emit(_ event: String, _ fields: [String: Any]) {
        var row = fields
        row["event"] = event
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        FileHandle.standardOutput.write(data + Data([10]))
    }
}
