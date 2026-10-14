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
/// - `edit-note <root> --id <uuid> --revision <n> [--pause …] [--fail …]`: replace the
///   body with standard input while observing the note.
/// - `pin-note <root> --id <uuid> --revision <n> --pinned true|false [--pause …] [--fail …]`
/// - `archive-note|restore-note <root> --id <uuid> --revision <n> [--pause …] [--fail …]`
/// - `read <root> [--query notes|archive|all|search|search-archived]`: summarize
///   active Notes (default), Archive, every record, or the Search projection.
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
            case "edit-note", "pin-note", "archive-note", "restore-note":
                guard let id = options["--id"].flatMap(UUID.init(uuidString:)),
                      let revision = options["--revision"].flatMap({ Int64($0) })
                else { throw Usage() }
                let command: CollectionCommand<Note>
                switch arguments[0] {
                case "edit-note": command = .editNote(id, expectedRevision: revision, body: readStandardInput())
                case "pin-note":
                    guard let pinned = options["--pinned"].flatMap({ Bool($0) }) else { throw Usage() }
                    command = .setNotePinned(id, pinned, expectedRevision: revision)
                case "archive-note": command = .archiveNote(id, expectedRevision: revision)
                default: command = .restoreNote(id, expectedRevision: revision)
                }
                try await changeNote(id, with: command, at: try CollectionLocation.fixture(root),
                                     faults: faults(pause: options["--pause"], fail: options["--fail"]))
            case "read":
                let store = try await CollectionStore.open(try CollectionLocation.fixture(root))
                do {
                    try await read(options["--query"] ?? "notes", from: store)
                } catch {
                    await store.close()
                    throw error
                }
                await store.close()
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

    private static func createNote(at location: CollectionLocation, operation: UUID, faults: CollectionStore.Faults) async throws {
        let body = readStandardInput()
        let store = try await CollectionStore.open(location, faults: faults)
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

    /// Performs `command` while observing the note until its result is observed.
    private static func changeNote(_ id: UUID, with command: CollectionCommand<Note>, at location: CollectionLocation,
                                   faults: CollectionStore.Faults) async throws {
        let store = try await CollectionStore.open(location, faults: faults)
        var observed = store.observe(.note(id), in: store.generation).makeAsyncIterator()
        let before = try await observed.next() ?? nil
        let note: Note
        do {
            note = try await store.perform(command, in: store.generation)
        } catch {
            await store.close()
            throw error
        }
        var after = before
        while after?.revision != note.revision, let next = try await observed.next() { after = next }
        await store.close()
        var fields = summary(note)
        fields["observedBeforeRevision"] = before?.revision ?? NSNull()
        fields["observedAfterRevision"] = after?.revision ?? NSNull()
        emit("note.changed", fields)
    }

    private static func read(_ query: String, from store: CollectionStore) async throws {
        switch query {
        case "notes": emitNotes(try await store.read(.notes, in: store.generation))
        case "archive": emitNotes(try await store.read(.archivedNotes, in: store.generation))
        case "all": emitNotes(try await store.read(.allRecords, in: store.generation).notes)
        case "search", "search-archived":
            let entries = try await store.read(.noteSearchEntries(includingArchived: query == "search-archived"), in: store.generation)
            emit("search", ["count": entries.count, "entries": entries.map { entry in
                ["id": entry.id.uuidString, "titleSHA256": entry.title.map(sha256) ?? NSNull(),
                 "textSHA256": sha256(entry.text), "archived": entry.isArchived] as [String: Any]
            }])
        default: throw Usage()
        }
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
