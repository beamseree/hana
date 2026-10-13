import CryptoKit
import Foundation
import GRDB
import SQLite3
import Synchronization

/// A committed, immutable note value. Never a live database row.
struct Note: Identifiable, Sendable {
    let id: UUID
    let body: String
    let createdAt: Date
    let contentEditedAt: Date
    let updatedAt: Date
    let revision: Int64
    let isPinned: Bool
    let archivedAt: Date?

    /// The first nonempty line, trimmed; nil when the body has no visible text.
    var title: String? {
        body.split(whereSeparator: \.isNewline).lazy
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty }
    }

    static func isNonblank(_ body: String) -> Bool {
        body.unicodeScalars.contains { !CharacterSet.whitespacesAndNewlines.contains($0) }
    }
}

extension Note: Equatable {
    /// Bodies compare by exact UTF-8 bytes, not canonical equivalence.
    static func == (a: Note, b: Note) -> Bool {
        a.id == b.id && a.body.utf8.elementsEqual(b.body.utf8) && a.createdAt == b.createdAt
            && a.contentEditedAt == b.contentEditedAt && a.updatedAt == b.updatedAt && a.revision == b.revision
            && a.isPinned == b.isPinned && a.archivedAt == b.archivedAt
    }
}

/// Identifies one open store session. Every open rotates it; work carrying an
/// older generation is rejected before it can look anything up.
struct StoreGeneration: Hashable, Sendable {
    fileprivate let id = UUID()
}

/// Typed failures. None carries note content, SQL or personal paths.
enum CollectionStoreError: Error, Equatable, Sendable {
    case fixtureRootUnavailable
    case liveRootRefused
    case notDisposableFixture
    case alreadyOwned
    case insecureStorage
    case missingCollection
    case unreadableCollection
    case notHanaCollection
    case unsupportedSchema(version: Int)
    case staleGeneration
    case closed
    case operationReused
    case blankNote
    /// The primary SQLite result code of a failed storage operation.
    case storageFailure(code: Int32)
}

struct CollectionQuery<Value: Sendable>: Sendable {
    fileprivate let fetch: @Sendable (Database) throws -> Value
}

extension CollectionQuery where Value == Note? {
    static func note(_ id: UUID) -> Self {
        Self { db in try NoteRow.fetch(db, where: "id = ?", [id.uuidString]).first }
    }
}

extension CollectionQuery where Value == [Note] {
    /// Active Notes: pinned first, then most recently content-edited, then stable ID.
    static var notes: Self {
        Self { db in
            try NoteRow.fetch(db, where: "archived_at IS NULL", [],
                              order: "pinned DESC, content_edited_at DESC, id ASC")
        }
    }
}

struct CollectionCommand<Result: Sendable>: Sendable {
    struct Context { let now: Int64 }
    fileprivate let apply: @Sendable (Database, Context) throws -> Result
}

extension CollectionCommand where Result == Note {
    /// Idempotent under `operation`: an identical retry returns the item created
    /// first (in its current committed state); a different payload fails.
    static func createNote(operation: UUID, body: String) -> Self {
        let payload = Data(body.utf8)
        let digest = Data(SHA256.hash(data: Data("note\u{0}".utf8) + payload))
        return Self { db, context in
            if let receipt = try Row.fetchOne(db, sql: """
                SELECT note_id, payload_sha256 FROM creation_receipt WHERE operation_id = ?
                """, arguments: [operation.uuidString]) {
                guard let noteID = receipt["note_id"] as String?, receipt["payload_sha256"] as Data? == digest,
                      let note = try NoteRow.fetch(db, where: "id = ?", [noteID]).first
                else { throw CollectionStoreError.operationReused }
                return note
            }
            guard Note.isNonblank(body) else { throw CollectionStoreError.blankNote }
            let id = UUID().uuidString
            try db.execute(sql: """
                INSERT INTO note (id, body, created_at, content_edited_at, updated_at, revision, pinned, archived_at)
                VALUES (?, CAST(? AS TEXT), ?, ?, ?, 1, 0, NULL)
                """, arguments: [id, payload, context.now, context.now, context.now])
            try db.execute(sql: """
                INSERT INTO creation_receipt (operation_id, note_id, task_id, payload_sha256, committed_at)
                VALUES (?, ?, NULL, ?, ?)
                """, arguments: [operation.uuidString, id, digest, context.now])
            return try NoteRow.fetch(db, where: "id = ?", [id])[0]
        }
    }
}

/// The single writing authority for one collection root.
final class CollectionStore: Sendable {
    /// Internal fault controls for tests and the fixture harness only.
    struct Faults: Sendable {
        var beforeCommit: (@Sendable (Database) throws -> Void)?
        var afterCommit: (@Sendable () throws -> Void)?
    }

    let generation = StoreGeneration()
    let location: CollectionLocation
    private let pool: DatabasePool
    private let clock: @Sendable () -> Date
    private let faults: Faults
    private struct State {
        var owner: OwnerLock?
        var lingeringOwner: OwnerLock?
        var observers: [UUID: @Sendable (any Error) -> Void] = [:]
    }
    private let observationQueue = DispatchQueue(label: "Hana.Collection.observation")
    private let state: Mutex<State>

    private init(location: CollectionLocation, pool: DatabasePool, owner: OwnerLock,
                 clock: @escaping @Sendable () -> Date, faults: Faults) {
        self.location = location
        self.pool = pool
        self.clock = clock
        self.faults = faults
        state = Mutex(State(owner: owner))
    }

    static func open(_ location: CollectionLocation, clock: @escaping @Sendable () -> Date = { Date() },
                     faults: Faults = Faults()) async throws -> CollectionStore {
        let fileManager = FileManager.default
        if location.isFixture { _ = try CollectionLocation.fixture(location.root) }
        if !location.isFixture, !fileManager.fileExists(atPath: location.root.path) {
            guard mkdir(location.root.path, 0o700) == 0 || errno == EEXIST else { throw CollectionStoreError.insecureStorage }
        }
        try requireOwnerOnly(location.root, type: S_IFDIR)
        if !fileManager.fileExists(atPath: location.collectionDirectory.path) {
            // A root that once held a collection is never new again.
            guard !fileManager.fileExists(atPath: location.initializedMarkerURL.path) else { throw CollectionStoreError.missingCollection }
            try CollectionSchema.initialize(location, now: milliseconds(clock()))
        }
        try requireOwnerOnly(location.collectionDirectory, type: S_IFDIR)
        let owner = try OwnerLock(directory: location.collectionDirectory)
        if fileManager.fileExists(atPath: location.databaseURL.path) { try requireOwnerOnly(location.databaseURL, type: S_IFREG) }
        try CollectionSchema.validate(location.databaseURL)
        // Also completes an initialization interrupted after its publishing rename.
        try CollectionSchema.recordInitialized(location)
        do {
            let pool = try CollectionSchema.openPool(location.databaseURL)
            return CollectionStore(location: location, pool: pool, owner: owner, clock: clock, faults: faults)
        } catch {
            throw CollectionStoreError.mapped(error)
        }
    }

    func perform<Result>(_ command: CollectionCommand<Result>, in generation: StoreGeneration) async throws -> Result {
        try requireCurrent(generation)
        let now = Self.milliseconds(clock())
        let result: Result
        do {
            result = try await pool.write { db in
                // Checked again when the serialized write executes, before any receipt lookup.
                try self.requireCurrent(generation)
                let result = try command.apply(db, .init(now: now))
                try self.faults.beforeCommit?(db)
                return result
            }
        } catch {
            throw CollectionStoreError.mapped(error)
        }
        try faults.afterCommit?()
        return result
    }

    func read<Value>(_ query: CollectionQuery<Value>, in generation: StoreGeneration) async throws -> Value {
        try requireCurrent(generation)
        do {
            return try await pool.read { db in try query.fetch(db) }
        } catch {
            throw CollectionStoreError.mapped(error)
        }
    }

    /// Identity and effective settings of the SQLite actually linked into
    /// this process, from the writer and from a pool reader.
    struct RuntimeReport: Codable, Sendable {
        struct Settings: Codable, Sendable {
            let journalMode: String
            let synchronous: Int
            let fullfsync: Int
            let checkpointFullfsync: Int
            let foreignKeys: Int
            let walAutocheckpoint: Int
            let isReadOnly: Bool
            /// Result code of a passive checkpoint attempted on a pool reader;
            /// not probed on the writer.
            let checkpointResult: Int32?
        }
        let sqliteVersion: String
        let sqliteSourceID: String
        let writer: Settings
        let reader: Settings
    }

    func runtimeReport() async throws -> RuntimeReport {
        @Sendable func settings(_ db: Database, probeCheckpoint: Bool) throws -> RuntimeReport.Settings {
            let connection = db.sqliteConnection
            func pragma(_ name: String) throws -> Int { try Int.fetchOne(db, sql: "PRAGMA \(name)") ?? -1 }
            return RuntimeReport.Settings(
                journalMode: try String.fetchOne(db, sql: "PRAGMA journal_mode") ?? "",
                synchronous: try pragma("synchronous"), fullfsync: try pragma("fullfsync"),
                checkpointFullfsync: try pragma("checkpoint_fullfsync"), foreignKeys: try pragma("foreign_keys"),
                walAutocheckpoint: try pragma("wal_autocheckpoint"),
                isReadOnly: sqlite3_db_readonly(connection, "main") == 1,
                checkpointResult: probeCheckpoint ? sqlite3_wal_checkpoint_v2(connection, "main", SQLITE_CHECKPOINT_PASSIVE, nil, nil) : nil)
        }
        do {
            let writer = try await pool.writeWithoutTransaction { try settings($0, probeCheckpoint: false) }
            let reader = try await pool.unsafeRead { try settings($0, probeCheckpoint: true) }
            return RuntimeReport(sqliteVersion: String(cString: sqlite3_libversion()),
                                 sqliteSourceID: String(cString: sqlite3_sourceid()), writer: writer, reader: reader)
        } catch {
            throw CollectionStoreError.mapped(error)
        }
    }

    /// Committed values of `query`: the current state first, then the latest
    /// state after commits. Intermediate commits may coalesce; rolled-back work
    /// never appears. The stream ends with `.closed` when this generation ends.
    func observe<Value>(_ query: CollectionQuery<Value>, in generation: StoreGeneration) -> AsyncThrowingStream<Value, any Error> {
        let (values, output) = AsyncThrowingStream<Value, any Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let key = UUID()
        do {
            try requireCurrent(generation)
            try state.withLock { state in
                guard state.owner != nil else { throw CollectionStoreError.closed }
                state.observers[key] = { output.finish(throwing: $0) }
            }
        } catch {
            output.finish(throwing: error)
            return values
        }
        // Installed before starting, so a close that finishes the stream in
        // between still cancels the database observation.
        let cancellation = ObservationCancellation()
        output.onTermination = { [weak self] _ in
            cancellation.cancel()
            _ = self?.state.withLock { $0.observers.removeValue(forKey: key) }
        }
        cancellation.attach(ValueObservation.tracking { db in try query.fetch(db) }
            .start(in: pool, scheduling: .async(onQueue: observationQueue),
                   onError: { output.finish(throwing: CollectionStoreError.mapped($0)) },
                   onChange: { output.yield($0) }))
        return values
    }

    /// Ends this generation: later work fails, observations end with `.closed`,
    /// the WAL is checkpointed and the owner lock is released.
    func close() async {
        let (owner, observers) = state.withLock { state in
            defer { state.owner = nil; state.observers = [:] }
            return (state.owner, state.observers)
        }
        guard let owner else { return }
        for finish in observers.values { finish(CollectionStoreError.closed) }
        _ = try? await pool.writeWithoutTransaction { try $0.checkpoint(.truncate) }
        do {
            try pool.close()
        } catch {
            // Connections may still be open: keep ownership until this store is
            // deallocated rather than let a second writer in alongside them.
            state.withLock { $0.lingeringOwner = owner }
        }
    }

    private func requireCurrent(_ generation: StoreGeneration) throws {
        guard generation == self.generation else { throw CollectionStoreError.staleGeneration }
        guard state.withLock({ $0.owner != nil }) else { throw CollectionStoreError.closed }
    }

    static func milliseconds(_ date: Date) -> Int64 { Int64((date.timeIntervalSince1970 * 1000).rounded()) }
    static func date(_ milliseconds: Int64) -> Date { Date(timeIntervalSince1970: Double(milliseconds) / 1000) }

    private static func requireOwnerOnly(_ url: URL, type: mode_t) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == type, info.st_uid == geteuid(),
              info.st_mode & 0o077 == 0
        else { throw CollectionStoreError.insecureStorage }
    }
}

extension CollectionStoreError {
    static func mapped(_ error: any Error) -> any Error {
        if let error = error as? DatabaseError {
            return CollectionStoreError.storageFailure(code: error.resultCode.primaryResultCode.rawValue)
        }
        return error
    }
}

private enum NoteRow {
    static func fetch(_ db: Database, where condition: String, _ arguments: StatementArguments,
                      order: String = "id ASC") throws -> [Note] {
        try Row.fetchAll(db, sql: """
            SELECT id, CAST(body AS BLOB) AS body, created_at, content_edited_at, updated_at, revision, pinned, archived_at
            FROM note WHERE \(condition) ORDER BY \(order)
            """, arguments: arguments).map { row in
            guard let id = UUID(uuidString: row["id"]) else { throw CollectionStoreError.unreadableCollection }
            return Note(id: id,
                 body: String(decoding: row["body"] as Data? ?? Data(), as: UTF8.self),
                 createdAt: CollectionStore.date(row["created_at"]),
                 contentEditedAt: CollectionStore.date(row["content_edited_at"]),
                 updatedAt: CollectionStore.date(row["updated_at"]),
                 revision: row["revision"],
                 isPinned: row["pinned"],
                 archivedAt: (row["archived_at"] as Int64?).map(CollectionStore.date))
        }
    }
}

private final class ObservationCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancellable: AnyDatabaseCancellable?
    private var isCancelled = false

    func attach(_ cancellable: AnyDatabaseCancellable) {
        let cancelNow = lock.withLock {
            self.cancellable = cancellable
            return isCancelled
        }
        if cancelNow { cancellable.cancel() }
    }

    func cancel() {
        let cancellable = lock.withLock {
            isCancelled = true
            return self.cancellable
        }
        cancellable?.cancel()
    }
}

/// Process-lifetime exclusive ownership of a collection directory. The kernel
/// releases the lock when the descriptor closes, including on process death.
private final class OwnerLock: Sendable {
    private let descriptor: Int32

    init(directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CollectionStoreError.missingCollection }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            let failure = errno
            Darwin.close(descriptor)
            throw failure == EWOULDBLOCK ? CollectionStoreError.alreadyOwned : CollectionStoreError.storageFailure(code: ResultCode.SQLITE_CANTOPEN.rawValue)
        }
        self.descriptor = descriptor
    }

    deinit { Darwin.close(descriptor) }
}
