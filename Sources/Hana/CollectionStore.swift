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

/// Where an active unfinished task lives.
enum TaskPlacement: String, Sendable, CaseIterable {
    case inbox, today
}

/// A committed, immutable task value. Never a live database row. (Named to
/// stay clear of Swift's concurrency `Task`.)
struct TaskItem: Identifiable, Sendable {
    let id: UUID
    let title: String
    let createdAt: Date
    let contentEditedAt: Date
    let updatedAt: Date
    let revision: Int64
    let completedAt: Date?
    let archivedAt: Date?
    /// Inbox or Today for exactly the unarchived unfinished tasks; nil otherwise.
    let placement: TaskPlacement?
    /// Position within `placement`, ascending from the top; nil when not placed.
    let orderKey: Int64?

    var isCompleted: Bool { completedAt != nil }

    /// Nonblank, with no line break of any kind: CR, LF, VT, FF, NEL, U+2028
    /// or U+2029. Titles are never trimmed or flattened.
    static func isValidTitle(_ title: String) -> Bool {
        Note.isNonblank(title) && !title.unicodeScalars.contains { lineBreaks.contains($0.value) }
    }

    private static let lineBreaks: Set<UInt32> = [0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029]
}

extension TaskItem: Equatable {
    /// Titles compare by exact UTF-8 bytes, not canonical equivalence.
    static func == (a: TaskItem, b: TaskItem) -> Bool {
        a.id == b.id && a.title.utf8.elementsEqual(b.title.utf8) && a.createdAt == b.createdAt
            && a.contentEditedAt == b.contentEditedAt && a.updatedAt == b.updatedAt && a.revision == b.revision
            && a.completedAt == b.completedAt && a.archivedAt == b.archivedAt && a.placement == b.placement
            && a.orderKey == b.orderKey
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
    /// No item has this ID.
    case notFound
    /// The item changed since the caller read the revision it supplied.
    case staleRevision
    /// The item is archived; restore it before changing it.
    case archived
    /// The task is completed; reopen it before moving it.
    case completed
    /// A task title is blank or contains a line break.
    case invalidTitle
    /// The list changed since the caller read the order it supplied.
    case staleList
    /// The requested position is outside the list.
    case invalidPosition
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

    /// Archived notes, most recently archived first, then stable ID.
    static var archivedNotes: Self {
        Self { db in
            try NoteRow.fetch(db, where: "archived_at IS NOT NULL", [], order: "archived_at DESC, id ASC")
        }
    }

    /// Every note record, active and archived, by ID.
    static var allNotes: Self {
        Self { db in try NoteRow.fetch(db, where: "1", []) }
    }
}

/// The committed title and text of an owned item, for future Search. Nothing
/// in the Search bar reads it yet.
struct OwnedItemText: Equatable, Sendable {
    enum Kind: String, Sendable { case note, task }
    let kind: Kind
    let id: UUID
    let title: String
    let text: String
    let isArchived: Bool
    /// Always false for notes.
    let isCompleted: Bool
    let contentEditedAt: Date
}

/// Which owned items Search may see. Archived items and completed tasks are
/// excluded unless explicitly included.
struct SearchEligibility: Equatable, Sendable {
    var includesArchived = false
    var includesCompleted = false
}

extension CollectionQuery where Value == [OwnedItemText] {
    /// Eligible notes and tasks, most recently content-edited first, then stable ID.
    static func searchText(_ eligibility: SearchEligibility = SearchEligibility()) -> Self {
        Self { db in
            let archive = eligibility.includesArchived ? "1" : "archived_at IS NULL"
            let completion = eligibility.includesCompleted ? "1" : "completed_at IS NULL"
            let notes = try NoteRow.fetch(db, where: archive, []).map { note in
                OwnedItemText(kind: .note, id: note.id, title: note.title ?? "", text: note.body,
                              isArchived: note.archivedAt != nil, isCompleted: false, contentEditedAt: note.contentEditedAt)
            }
            let tasks = try TaskRow.fetch(db, where: "\(archive) AND \(completion)", []).map { task in
                OwnedItemText(kind: .task, id: task.id, title: task.title, text: task.title,
                              isArchived: task.archivedAt != nil, isCompleted: task.isCompleted,
                              contentEditedAt: task.contentEditedAt)
            }
            return (notes + tasks).sorted {
                ($0.contentEditedAt, $1.id.uuidString) > ($1.contentEditedAt, $0.id.uuidString)
            }
        }
    }
}

extension CollectionQuery where Value == TaskItem? {
    static func task(_ id: UUID) -> Self {
        Self { db in try TaskRow.fetch(db, where: "id = ?", [id.uuidString]).first }
    }
}

extension CollectionQuery where Value == [TaskItem] {
    /// One active list, top first: ascending order key, then stable ID.
    static func tasks(in placement: TaskPlacement) -> Self {
        Self { db in
            try TaskRow.fetch(db, where: "placement = ?", [placement.rawValue], order: "order_key ASC, id ASC")
        }
    }

    static var inbox: Self { tasks(in: .inbox) }
    static var today: Self { tasks(in: .today) }

    /// Completed tasks that are not archived, most recently completed first, then stable ID.
    static var completedTasks: Self {
        Self { db in
            try TaskRow.fetch(db, where: "completed_at IS NOT NULL AND archived_at IS NULL", [],
                              order: "completed_at DESC, id ASC")
        }
    }

    /// Archived tasks, completed or not, most recently archived first, then stable ID.
    static var archivedTasks: Self {
        Self { db in
            try TaskRow.fetch(db, where: "archived_at IS NOT NULL", [], order: "archived_at DESC, id ASC")
        }
    }

    /// Every task record by ID.
    static var allTasks: Self {
        Self { db in try TaskRow.fetch(db, where: "1", []) }
    }
}

/// Every committed domain fact, read in one transaction: a single coherent
/// committed state even while later writes commit. Notes and tasks by ID.
struct CollectionContents: Equatable, Sendable {
    let collectionID: UUID
    let schemaVersion: Int
    let notes: [Note]
    let tasks: [TaskItem]

    /// The latest updated time of any item; nil for an empty collection.
    var latestUpdatedAt: Date? {
        (notes.map(\.updatedAt) + tasks.map(\.updatedAt)).max()
    }
}

extension CollectionQuery where Value == CollectionContents {
    static var contents: Self {
        Self { db in
            guard let id = try String.fetchOne(db, sql: "SELECT id FROM collection WHERE singleton = 1").flatMap(UUID.init(uuidString:))
            else { throw CollectionStoreError.unreadableCollection }
            return CollectionContents(collectionID: id, schemaVersion: CollectionSchema.version,
                                      notes: try NoteRow.fetch(db, where: "1", []),
                                      tasks: try TaskRow.fetch(db, where: "1", []))
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

    /// Replaces the body. Changes content-edited and updated time and the
    /// revision; an identical body is a no-op. Archived notes are refused.
    static func editNote(_ id: UUID, expectedRevision: Int64, body: String) -> Self {
        let payload = Data(body.utf8)
        return Self { db, context in
            let note = try NoteRow.current(db, id, expectedRevision: expectedRevision)
            guard note.archivedAt == nil else { throw CollectionStoreError.archived }
            guard Note.isNonblank(body) else { throw CollectionStoreError.blankNote }
            guard !note.body.utf8.elementsEqual(payload) else { return note }
            try db.execute(sql: """
                UPDATE note SET body = CAST(? AS TEXT), content_edited_at = ?, updated_at = ?, revision = revision + 1
                WHERE id = ?
                """, arguments: [payload, context.now, context.now, id.uuidString])
            return try NoteRow.current(db, id, expectedRevision: expectedRevision + 1)
        }
    }

    /// Pins or unpins without changing content-edited time. Archived notes are
    /// refused; the current pin state is a no-op.
    static func setNotePinned(_ id: UUID, _ isPinned: Bool, expectedRevision: Int64) -> Self {
        Self { db, context in
            let note = try NoteRow.current(db, id, expectedRevision: expectedRevision)
            guard note.archivedAt == nil else { throw CollectionStoreError.archived }
            guard note.isPinned != isPinned else { return note }
            try db.execute(sql: "UPDATE note SET pinned = ?, updated_at = ?, revision = revision + 1 WHERE id = ?",
                           arguments: [isPinned, context.now, id.uuidString])
            return try NoteRow.current(db, id, expectedRevision: expectedRevision + 1)
        }
    }

    /// Moves the note to Archive, preserving body, pin and content-edited
    /// time. An archived note is a no-op.
    static func archiveNote(_ id: UUID, expectedRevision: Int64) -> Self {
        Self { db, context in
            let note = try NoteRow.current(db, id, expectedRevision: expectedRevision)
            guard note.archivedAt == nil else { return note }
            try db.execute(sql: "UPDATE note SET archived_at = ?, updated_at = ?, revision = revision + 1 WHERE id = ?",
                           arguments: [context.now, context.now, id.uuidString])
            return try NoteRow.current(db, id, expectedRevision: expectedRevision + 1)
        }
    }

    /// Returns an archived note to Notes, preserving body, pin and
    /// content-edited time. An active note is a no-op.
    static func restoreNote(_ id: UUID, expectedRevision: Int64) -> Self {
        Self { db, context in
            let note = try NoteRow.current(db, id, expectedRevision: expectedRevision)
            guard note.archivedAt != nil else { return note }
            try db.execute(sql: "UPDATE note SET archived_at = NULL, updated_at = ?, revision = revision + 1 WHERE id = ?",
                           arguments: [context.now, id.uuidString])
            return try NoteRow.current(db, id, expectedRevision: expectedRevision + 1)
        }
    }
}

extension CollectionCommand where Result == TaskItem {
    /// Idempotent under `operation`: an identical retry (same title bytes and
    /// placement) returns the task created first, in its current committed
    /// state; a different payload fails. New tasks go to the top of `placement`.
    static func createTask(operation: UUID, title: String, placement: TaskPlacement = .inbox) -> Self {
        let payload = Data(title.utf8)
        let digest = Data(SHA256.hash(data: Data("task\u{0}\(placement.rawValue)\u{0}".utf8) + payload))
        return Self { db, context in
            if let receipt = try Row.fetchOne(db, sql: """
                SELECT task_id, payload_sha256 FROM creation_receipt WHERE operation_id = ?
                """, arguments: [operation.uuidString]) {
                guard let taskID = receipt["task_id"] as String?, receipt["payload_sha256"] as Data? == digest,
                      let task = try TaskRow.fetch(db, where: "id = ?", [taskID]).first
                else { throw CollectionStoreError.operationReused }
                return task
            }
            guard TaskItem.isValidTitle(title) else { throw CollectionStoreError.invalidTitle }
            let id = UUID().uuidString
            let key = try TaskOrder.topKey(db, placement)
            try db.execute(sql: """
                INSERT INTO task (id, title, created_at, content_edited_at, updated_at, revision,
                                  completed_at, archived_at, placement, order_key)
                VALUES (?, CAST(? AS TEXT), ?, ?, ?, 1, NULL, NULL, ?, ?)
                """, arguments: [id, payload, context.now, context.now, context.now, placement.rawValue, key])
            try db.execute(sql: """
                INSERT INTO creation_receipt (operation_id, note_id, task_id, payload_sha256, committed_at)
                VALUES (?, NULL, ?, ?, ?)
                """, arguments: [operation.uuidString, id, digest, context.now])
            return try TaskRow.fetch(db, where: "id = ?", [id])[0]
        }
    }

    /// Replaces the title of an unarchived task, completed or not. Changes
    /// content-edited and updated time; an identical title is a no-op.
    static func editTaskTitle(_ id: UUID, expectedRevision: Int64, title: String) -> Self {
        let payload = Data(title.utf8)
        return Self { db, context in
            let task = try TaskRow.current(db, id, expectedRevision: expectedRevision)
            guard task.archivedAt == nil else { throw CollectionStoreError.archived }
            guard TaskItem.isValidTitle(title) else { throw CollectionStoreError.invalidTitle }
            guard !task.title.utf8.elementsEqual(payload) else { return task }
            try db.execute(sql: """
                UPDATE task SET title = CAST(? AS TEXT), content_edited_at = ?, updated_at = ?, revision = revision + 1
                WHERE id = ?
                """, arguments: [payload, context.now, context.now, id.uuidString])
            return try TaskRow.current(db, id, expectedRevision: expectedRevision + 1)
        }
    }

    /// Moves an active unfinished task to the top of `placement`. A task
    /// already there stays where it is.
    static func moveTask(_ id: UUID, to placement: TaskPlacement, expectedRevision: Int64) -> Self {
        Self { db, context in
            let task = try TaskRow.current(db, id, expectedRevision: expectedRevision)
            guard task.archivedAt == nil else { throw CollectionStoreError.archived }
            guard !task.isCompleted else { throw CollectionStoreError.completed }
            guard task.placement != placement else { return task }
            try TaskRow.place(db, id, placement, now: context.now)
            return try TaskRow.current(db, id, expectedRevision: expectedRevision + 1)
        }
    }

    /// Moves an active task to `index` (0 is the top) within `placement`,
    /// given that list exactly as the caller last read it. Any concurrent
    /// insertion, move, completion, archive or reorder in the list makes
    /// `expectedOrder` obsolete and the command fails with `staleList` rather
    /// than overwrite it. The current position is a no-op.
    static func reorderTask(_ id: UUID, expectedRevision: Int64, in placement: TaskPlacement,
                            expectedOrder: [UUID], toIndex index: Int) -> Self {
        Self { db, context in
            let task = try TaskRow.current(db, id, expectedRevision: expectedRevision)
            guard task.archivedAt == nil else { throw CollectionStoreError.archived }
            guard !task.isCompleted else { throw CollectionStoreError.completed }
            let current = try TaskOrder.currentOrder(db, placement)
            guard task.placement == placement, current == expectedOrder.map(\.uuidString),
                  let from = current.firstIndex(of: id.uuidString)
            else { throw CollectionStoreError.staleList }
            guard current.indices.contains(index) else { throw CollectionStoreError.invalidPosition }
            guard from != index else { return task }
            var order = current
            order.remove(at: from)
            order.insert(id.uuidString, at: index)
            let key = try TaskOrder.key(db, placement, at: index, in: order)
            try db.execute(sql: "UPDATE task SET order_key = ?, updated_at = ?, revision = revision + 1 WHERE id = ?",
                           arguments: [key, context.now, id.uuidString])
            return try TaskRow.current(db, id, expectedRevision: expectedRevision + 1)
        }
    }

    /// Completes an unarchived task, clearing its placement and order. A
    /// completed task is a no-op.
    static func completeTask(_ id: UUID, expectedRevision: Int64) -> Self {
        Self { db, context in
            let task = try TaskRow.current(db, id, expectedRevision: expectedRevision)
            guard task.archivedAt == nil else { throw CollectionStoreError.archived }
            guard !task.isCompleted else { return task }
            try db.execute(sql: """
                UPDATE task SET completed_at = ?, placement = NULL, order_key = NULL, updated_at = ?, revision = revision + 1
                WHERE id = ?
                """, arguments: [context.now, context.now, id.uuidString])
            return try TaskRow.current(db, id, expectedRevision: expectedRevision + 1)
        }
    }

    /// Reopens a completed unarchived task at the top of Inbox, never its
    /// earlier Today placement. An unfinished task is a no-op.
    static func reopenTask(_ id: UUID, expectedRevision: Int64) -> Self {
        Self { db, context in
            let task = try TaskRow.current(db, id, expectedRevision: expectedRevision)
            guard task.archivedAt == nil else { throw CollectionStoreError.archived }
            guard task.isCompleted else { return task }
            try TaskRow.place(db, id, .inbox, now: context.now)
            return try TaskRow.current(db, id, expectedRevision: expectedRevision + 1)
        }
    }

    /// Archives a task, preserving its completion time and clearing placement
    /// and order. An archived task is a no-op.
    static func archiveTask(_ id: UUID, expectedRevision: Int64) -> Self {
        Self { db, context in
            let task = try TaskRow.current(db, id, expectedRevision: expectedRevision)
            guard task.archivedAt == nil else { return task }
            try db.execute(sql: """
                UPDATE task SET archived_at = ?, placement = NULL, order_key = NULL, updated_at = ?, revision = revision + 1
                WHERE id = ?
                """, arguments: [context.now, context.now, id.uuidString])
            return try TaskRow.current(db, id, expectedRevision: expectedRevision + 1)
        }
    }

    /// Restores an archived task: unfinished to the top of Inbox (even if it
    /// was in Today), completed to Completed with its completion time. An
    /// unarchived task is a no-op.
    static func restoreTask(_ id: UUID, expectedRevision: Int64) -> Self {
        Self { db, context in
            let task = try TaskRow.current(db, id, expectedRevision: expectedRevision)
            guard task.archivedAt != nil else { return task }
            if task.isCompleted {
                try db.execute(sql: "UPDATE task SET archived_at = NULL, updated_at = ?, revision = revision + 1 WHERE id = ?",
                               arguments: [context.now, id.uuidString])
            } else {
                try TaskRow.place(db, id, .inbox, now: context.now)
            }
            return try TaskRow.current(db, id, expectedRevision: expectedRevision + 1)
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
    /// The note as committed, provided it is still at `expectedRevision`.
    /// Checked inside the serialized write, so a competing command that
    /// committed first makes this one fail rather than overwrite it.
    static func current(_ db: Database, _ id: UUID, expectedRevision: Int64) throws -> Note {
        guard let note = try fetch(db, where: "id = ?", [id.uuidString]).first else { throw CollectionStoreError.notFound }
        guard note.revision == expectedRevision else { throw CollectionStoreError.staleRevision }
        return note
    }

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

private enum TaskRow {
    /// The task as committed, provided it is still at `expectedRevision`.
    static func current(_ db: Database, _ id: UUID, expectedRevision: Int64) throws -> TaskItem {
        guard let task = try fetch(db, where: "id = ?", [id.uuidString]).first else { throw CollectionStoreError.notFound }
        guard task.revision == expectedRevision else { throw CollectionStoreError.staleRevision }
        return task
    }

    /// Puts the task unarchived and unfinished at the top of `placement`,
    /// preserving its creation and content-edited times.
    static func place(_ db: Database, _ id: UUID, _ placement: TaskPlacement, now: Int64) throws {
        let key = try TaskOrder.topKey(db, placement)
        try db.execute(sql: """
            UPDATE task SET completed_at = NULL, archived_at = NULL, placement = ?, order_key = ?, updated_at = ?,
                            revision = revision + 1
            WHERE id = ?
            """, arguments: [placement.rawValue, key, now, id.uuidString])
    }

    static func fetch(_ db: Database, where condition: String, _ arguments: StatementArguments,
                      order: String = "id ASC") throws -> [TaskItem] {
        try Row.fetchAll(db, sql: """
            SELECT id, CAST(title AS BLOB) AS title, created_at, content_edited_at, updated_at, revision,
                   completed_at, archived_at, placement, order_key
            FROM task WHERE \(condition) ORDER BY \(order)
            """, arguments: arguments).map { row in
            guard let id = UUID(uuidString: row["id"]) else { throw CollectionStoreError.unreadableCollection }
            let placement: TaskPlacement?
            if let raw = row["placement"] as String? {
                guard let known = TaskPlacement(rawValue: raw) else { throw CollectionStoreError.unreadableCollection }
                placement = known
            } else {
                placement = nil
            }
            return TaskItem(id: id,
                            title: String(decoding: row["title"] as Data? ?? Data(), as: UTF8.self),
                            createdAt: CollectionStore.date(row["created_at"]),
                            contentEditedAt: CollectionStore.date(row["content_edited_at"]),
                            updatedAt: CollectionStore.date(row["updated_at"]),
                            revision: row["revision"],
                            completedAt: (row["completed_at"] as Int64?).map(CollectionStore.date),
                            archivedAt: (row["archived_at"] as Int64?).map(CollectionStore.date),
                            placement: placement,
                            orderKey: row["order_key"])
        }
    }
}

/// Integer order keys within each active list: ascending from the top, ties
/// broken by ID. Keys are list positions, not item facts: renumbering
/// rewrites them in one transaction, preserving relative order, without
/// changing the other tasks' revisions or updated times.
enum TaskOrder {
    /// Spacing used when a list is renumbered, leaving room on both sides of
    /// every key for later insertions.
    static let spacing: Int64 = 1 << 20

    /// A key above every task currently in `placement`; renumbers the list
    /// first when the smallest key is already `Int64.min`.
    static func topKey(_ db: Database, _ placement: TaskPlacement) throws -> Int64 {
        guard let first = try Int64.fetchOne(db, sql: "SELECT min(order_key) FROM task WHERE placement = ?",
                                             arguments: [placement.rawValue])
        else { return 0 }
        if first > Int64.min { return first - 1 }
        try renumber(db, placement, order: currentOrder(db, placement))
        return -spacing
    }

    /// The IDs in `placement`, top first.
    static func currentOrder(_ db: Database, _ placement: TaskPlacement) throws -> [String] {
        try String.fetchAll(db, sql: "SELECT id FROM task WHERE placement = ? ORDER BY order_key ASC, id ASC",
                            arguments: [placement.rawValue])
    }

    /// Assigns `0, spacing, 2 × spacing, …` to `order`, top first.
    static func renumber(_ db: Database, _ placement: TaskPlacement, order: [String]) throws {
        for (index, id) in order.enumerated() {
            try db.execute(sql: "UPDATE task SET order_key = ? WHERE id = ? AND placement = ?",
                           arguments: [Int64(index) * spacing, id, placement.rawValue])
        }
    }

    /// A key for the task at `index` of the desired `order` that sorts it
    /// between its new neighbours: just above the one below at the top, just
    /// below the one above at the bottom, otherwise the midpoint. When the
    /// neighbours leave no room, renumbers the whole list into `order` first
    /// (which already places the task) and returns its new key.
    static func key(_ db: Database, _ placement: TaskPlacement, at index: Int, in order: [String]) throws -> Int64 {
        func existingKey(_ id: String) throws -> Int128 {
            guard let key = try Int64.fetchOne(db, sql: "SELECT order_key FROM task WHERE id = ?", arguments: [id])
            else { throw CollectionStoreError.unreadableCollection }
            return Int128(key)
        }
        // Int128 so neighbour arithmetic cannot overflow.
        let above: Int128? = try index > 0 ? existingKey(order[index - 1]) : nil
        let below: Int128? = try index + 1 < order.count ? existingKey(order[index + 1]) : nil
        let candidate: Int128?
        switch (above, below) {
        case let (upper?, lower?): candidate = lower - upper >= 2 ? (upper + lower) / 2 : nil
        case let (nil, lower?): candidate = lower - 1
        case let (upper?, nil): candidate = upper + 1
        case (nil, nil): candidate = 0
        }
        if let candidate, let key = Int64(exactly: candidate) { return key }
        try renumber(db, placement, order: order)
        return Int64(index) * spacing
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
