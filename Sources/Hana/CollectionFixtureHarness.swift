import CryptoKit
import Foundation

/// Fixture-only command-line harness over the production Collection Store:
/// `Hana --collection-fixture <action> <root> [options]`.
///
/// It accepts only marked disposable roots (never the live root, descendants or
/// aliases) and prints content-free JSON lines: IDs, revisions, timestamps,
/// counts and body/title digests, never note or task text. Normal launch does not use it.
///
/// - `create-root <root>`: create a new marked disposable root.
/// - `create-note <root> --operation <uuid> [--pause before-commit|after-commit] [--fail before-commit]`:
///   save the note body read from standard input while observing Notes.
/// - `edit-note <root> --id <uuid> --revision <n> [--pause …] [--fail …]`: replace the
///   body with standard input while observing the note.
/// - `pin-note <root> --id <uuid> --revision <n> --pinned true|false [--pause …] [--fail …]`:
///   pin or unpin the note while observing it.
/// - `archive-note|restore-note <root> --id <uuid> --revision <n> [--pause …] [--fail …]`:
///   archive or restore the note while observing it.
/// - `create-task <root> --operation <uuid> [--placement inbox|today] [--pause …] [--fail …]`:
///   save the task title read from standard input while observing its list.
/// - `edit-task <root> --id <uuid> --revision <n> [--pause …] [--fail …]`: replace the
///   title with standard input while observing the task.
/// - `move-task <root> --id <uuid> --revision <n> --to inbox|today [--pause …] [--fail …]`
/// - `complete-task|reopen-task|archive-task|restore-task <root> --id <uuid> --revision <n> [--pause …] [--fail …]`
/// - `reorder-task <root> --id <uuid> --in inbox|today [--after <uuid>] --expected <uuid,uuid,…> [--pause …] [--fail …]`:
///   move the task below `--after` (top when absent), given the list as last
///   seen, while observing the list until its committed order appears.
/// - `read <root> [--query notes|archive|all|search|search-archived|inbox|today|completed|archived-tasks|task-search|task-search-all]`:
///   summarize active Notes (default), note Archive, every record (notes and
///   tasks), the note Search projection, a task view, or the task Search
///   projection (`task-search-all` includes completed and archived tasks).
/// - `runtime-report <root>`: linked SQLite identity and effective settings.
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
                                     faults: faults(pause: options["--pause"], fail: options["--fail"]))
            case "edit-note":
                try await changeNote(at: root, options) { .editNote($0, expectedRevision: $1, body: readStandardInput()) }
            case "pin-note":
                guard let pinned = options["--pinned"].flatMap({ Bool($0) }) else { throw Usage() }
                try await changeNote(at: root, options) { .setNotePinned($0, pinned, expectedRevision: $1) }
            case "archive-note":
                try await changeNote(at: root, options) { .archiveNote($0, expectedRevision: $1) }
            case "restore-note":
                try await changeNote(at: root, options) { .restoreNote($0, expectedRevision: $1) }
            case "create-task":
                guard let operation = options["--operation"].flatMap(UUID.init(uuidString:)),
                      let placement = TaskPlacement(rawValue: options["--placement"] ?? "inbox")
                else { throw Usage() }
                try await createTask(at: try CollectionLocation.fixture(root), operation: operation, placement: placement,
                                     faults: faults(pause: options["--pause"], fail: options["--fail"]))
            case "edit-task":
                try await changeTask(at: root, options) { .editTaskTitle($0, expectedRevision: $1, title: readStandardInput()) }
            case "move-task":
                guard let placement = options["--to"].flatMap(TaskPlacement.init(rawValue:)) else { throw Usage() }
                try await changeTask(at: root, options) { .moveTask($0, to: placement, expectedRevision: $1) }
            case "complete-task":
                try await changeTask(at: root, options) { .completeTask($0, expectedRevision: $1) }
            case "reopen-task":
                try await changeTask(at: root, options) { .reopenTask($0, expectedRevision: $1) }
            case "archive-task":
                try await changeTask(at: root, options) { .archiveTask($0, expectedRevision: $1) }
            case "restore-task":
                try await changeTask(at: root, options) { .restoreTask($0, expectedRevision: $1) }
            case "reorder-task":
                guard let id = options["--id"].flatMap(UUID.init(uuidString:)),
                      let placement = options["--in"].flatMap(TaskPlacement.init(rawValue:)),
                      let expected = options["--expected"]?.split(separator: ",").map({ UUID(uuidString: String($0)) }),
                      !expected.contains(nil)
                else { throw Usage() }
                var predecessor: UUID?
                if let after = options["--after"] {
                    guard let parsed = UUID(uuidString: after) else { throw Usage() }
                    predecessor = parsed
                }
                try await reorderTask(at: try CollectionLocation.fixture(root),
                                      .reorderTask(id, in: placement, after: predecessor, expectedOrder: expected.compactMap { $0 }),
                                      placement: placement, faults: faults(pause: options["--pause"], fail: options["--fail"]))
            case "read":
                try await withStore(try CollectionLocation.fixture(root)) { try await read(options["--query"] ?? "notes", from: $0) }
            case "runtime-report":
                let report = try await withStore(try CollectionLocation.fixture(root)) { try await $0.runtimeReport() }
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

    private static func readStandardInput() -> String {
        String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
    }

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

    /// Opens a store for `body` and closes it afterwards, also when `body` throws.
    private static func withStore<Value>(_ location: CollectionLocation, faults: CollectionStore.Faults = .init(),
                                         _ body: (CollectionStore) async throws -> Value) async throws -> Value {
        let store = try await CollectionStore.open(location, faults: faults)
        do {
            let value = try await body(store)
            await store.close()
            return value
        } catch {
            await store.close()
            throw error
        }
    }

    private static func createNote(at location: CollectionLocation, operation: UUID, faults: CollectionStore.Faults) async throws {
        let body = readStandardInput()
        let fields = try await withStore(location, faults: faults) { store in
            var observed = store.observe(.notes, in: store.generation).makeAsyncIterator()
            let before = try await observed.next() ?? []
            let note = try await store.perform(.createNote(operation: operation, body: body), in: store.generation)
            var after = before
            // A retry returns the note as it stands now, possibly archived.
            while note.archivedAt == nil, !after.contains(where: { $0.id == note.id }),
                  let next = try await observed.next() { after = next }
            var fields = summary(note)
            fields["observedBefore"] = before.count
            fields["observedAfter"] = after.count
            return fields
        }
        emit("note.created", fields)
    }

    private static func createTask(at location: CollectionLocation, operation: UUID, placement: TaskPlacement,
                                   faults: CollectionStore.Faults) async throws {
        let title = readStandardInput()
        let fields = try await withStore(location, faults: faults) { store in
            var observed = store.observe(.tasks(in: placement), in: store.generation).makeAsyncIterator()
            let before = try await observed.next() ?? []
            let task = try await store.perform(.createTask(operation: operation, title: title, placement: placement),
                                               in: store.generation)
            var after = before
            // A retry returns the task as it stands now, possibly no longer in this list.
            while task.placement == placement, !after.contains(where: { $0.id == task.id }),
                  let next = try await observed.next() { after = next }
            var fields = summary(task)
            fields["observedBefore"] = before.count
            fields["observedAfter"] = after.count
            return fields
        }
        emit("task.created", fields)
    }

    private static func reorderTask(at location: CollectionLocation, _ command: CollectionCommand<TaskItem>,
                                    placement: TaskPlacement, faults: CollectionStore.Faults) async throws {
        let fields = try await withStore(location, faults: faults) { store in
            var observed = store.observe(.tasks(in: placement), in: store.generation).makeAsyncIterator()
            let before = try await observed.next() ?? []
            let task = try await store.perform(command, in: store.generation)
            var after = before
            while !after.contains(task), let next = try await observed.next() { after = next }
            var fields: [String: Any] = ["count": after.count, "tasks": after.map(summary), "movedID": task.id.uuidString,
                                         "revision": task.revision]
            fields["observedBefore"] = before.map(\.id.uuidString)
            fields["observedAfter"] = after.map(\.id.uuidString)
            return fields
        }
        emit("tasks.reordered", fields)
    }

    private static func changeNote(at root: URL, _ options: [String: String],
                                   _ command: (UUID, Int64) -> CollectionCommand<Note>) async throws {
        try await change(at: root, options, command, query: CollectionQuery.note, revision: \.revision, summary: summary,
                         event: "note.changed")
    }

    private static func changeTask(at root: URL, _ options: [String: String],
                                   _ command: (UUID, Int64) -> CollectionCommand<TaskItem>) async throws {
        try await change(at: root, options, command, query: CollectionQuery.task, revision: \.revision, summary: summary,
                         event: "task.changed")
    }

    /// Performs the command for `--id`/`--revision` while observing the item
    /// until its committed result is observed.
    private static func change<Item: Sendable>(at root: URL, _ options: [String: String],
                                               _ command: (UUID, Int64) -> CollectionCommand<Item>,
                                               query: (UUID) -> CollectionQuery<Item?>, revision: KeyPath<Item, Int64>,
                                               summary: (Item) -> [String: Any], event: String) async throws {
        guard let id = options["--id"].flatMap(UUID.init(uuidString:)), let expected = options["--revision"].flatMap({ Int64($0) })
        else { throw Usage() }
        let command = command(id, expected)
        let faults = faults(pause: options["--pause"], fail: options["--fail"])
        let fields = try await withStore(try CollectionLocation.fixture(root), faults: faults) { store in
            var observed = store.observe(query(id), in: store.generation).makeAsyncIterator()
            let before = try await observed.next() ?? nil
            let item = try await store.perform(command, in: store.generation)
            var after = before
            while after?[keyPath: revision] != item[keyPath: revision], let next = try await observed.next() { after = next }
            var fields = summary(item)
            fields["observedBeforeRevision"] = before?[keyPath: revision] ?? NSNull()
            fields["observedAfterRevision"] = after?[keyPath: revision] ?? NSNull()
            return fields
        }
        emit(event, fields)
    }

    private static func read(_ query: String, from store: CollectionStore) async throws {
        switch query {
        case "notes": emitNotes(try await store.read(.notes, in: store.generation))
        case "archive": emitNotes(try await store.read(.archivedNotes, in: store.generation))
        case "all":
            let records = try await store.read(.allRecords, in: store.generation)
            emitNotes(records.notes)
            emitTasks(records.tasks)
        case "search", "search-archived":
            let entries = try await store.read(.noteSearchEntries(includingArchived: query == "search-archived"), in: store.generation)
            emit("search", ["count": entries.count, "entries": entries.map { entry in
                ["id": entry.id.uuidString, "titleSHA256": entry.title.map(sha256) ?? NSNull(),
                 "textSHA256": sha256(entry.text), "archived": entry.isArchived] as [String: Any]
            }])
        case "inbox": emitTasks(try await store.read(.inbox, in: store.generation))
        case "today": emitTasks(try await store.read(.today, in: store.generation))
        case "completed": emitTasks(try await store.read(.completedTasks, in: store.generation))
        case "archived-tasks": emitTasks(try await store.read(.archivedTasks, in: store.generation))
        case "task-search", "task-search-all":
            let all = query == "task-search-all"
            let entries = try await store.read(.taskSearchEntries(includingCompleted: all, includingArchived: all), in: store.generation)
            emit("task-search", ["count": entries.count, "entries": entries.map { entry in
                ["id": entry.id.uuidString, "titleSHA256": sha256(entry.title), "completed": entry.isCompleted,
                 "archived": entry.isArchived] as [String: Any]
            }])
        default: throw Usage()
        }
    }

    private static func emitTasks(_ tasks: [TaskItem]) {
        emit("tasks", ["count": tasks.count, "tasks": tasks.map(summary)])
    }

    private static func summary(_ task: TaskItem) -> [String: Any] {
        ["id": task.id.uuidString, "revision": task.revision, "titleBytes": task.title.utf8.count,
         "titleSHA256": sha256(task.title), "createdAt": CollectionStore.milliseconds(task.createdAt),
         "contentEditedAt": CollectionStore.milliseconds(task.contentEditedAt),
         "updatedAt": CollectionStore.milliseconds(task.updatedAt),
         "completedAt": task.completedAt.map(CollectionStore.milliseconds) ?? NSNull(),
         "archivedAt": task.archivedAt.map(CollectionStore.milliseconds) ?? NSNull(),
         "placement": task.placement?.rawValue ?? NSNull(), "orderKey": task.orderKey ?? NSNull()]
    }

    private static func emitNotes(_ notes: [Note]) {
        emit("notes", ["count": notes.count, "notes": notes.map(summary)])
    }

    private static func summary(_ note: Note) -> [String: Any] {
        return ["id": note.id.uuidString, "revision": note.revision, "bodyBytes": note.body.utf8.count,
                "bodySHA256": sha256(note.body), "titleSHA256": note.title.map(sha256) ?? NSNull(),
                "createdAt": CollectionStore.milliseconds(note.createdAt),
                "contentEditedAt": CollectionStore.milliseconds(note.contentEditedAt),
                "updatedAt": CollectionStore.milliseconds(note.updatedAt),
                "pinned": note.isPinned, "archived": note.archivedAt != nil]
    }

    private static func sha256(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Error names only; never descriptions that could carry content or paths.
    private static func describe(_ error: any Error) -> String {
        switch error {
        case let error as CollectionStoreError:
            if case .unsupportedSchema(let version) = error { return "unsupportedSchema(\(version))" }
            if case .storageFailure(let code) = error { return "storageFailure(\(code))" }
            return "\(error)"
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
