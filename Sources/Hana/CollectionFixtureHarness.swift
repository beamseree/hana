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
/// - `read <root>`: summarize active Notes.
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
                                     pause: options["--pause"], fail: options["--fail"])
            case "read":
                let store = try await CollectionStore.open(try CollectionLocation.fixture(root))
                let notes = try await store.read(.notes, in: store.generation)
                await store.close()
                emit("notes", ["count": notes.count, "notes": notes.map(summary)])
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

    private static func createNote(at location: CollectionLocation, operation: UUID, pause: String?, fail: String?) async throws {
        let body = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        let holdForever: @Sendable (String) -> Void = { point in
            emit("paused", ["at": point])
            while true { sleep(60) }
        }
        let faults = CollectionStore.Faults(
            beforeCommit: { _ in
                if pause == "before-commit" { holdForever("before-commit") }
                if fail == "before-commit" { throw InjectedFailure() }
            },
            afterCommit: { if pause == "after-commit" { holdForever("after-commit") } })
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

    private static func summary(_ note: Note) -> [String: Any] {
        let body = Data(note.body.utf8)
        return ["id": note.id.uuidString, "revision": note.revision, "bodyBytes": body.count,
                "bodySHA256": SHA256.hash(data: body).map { String(format: "%02x", $0) }.joined(),
                "createdAt": CollectionStore.milliseconds(note.createdAt),
                "contentEditedAt": CollectionStore.milliseconds(note.contentEditedAt),
                "updatedAt": CollectionStore.milliseconds(note.updatedAt),
                "pinned": note.isPinned, "archived": note.archivedAt != nil]
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
