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
        var start = body.startIndex
        while start < body.endIndex {
            let end = body[start...].firstIndex(where: \.isNewline) ?? body.endIndex
            let line = body[start..<end].trimmingCharacters(in: .whitespaces)
            if !line.isEmpty { return line }
            guard end < body.endIndex else { return nil }
            start = body.index(after: end)
        }
        return nil
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

/// An active unfinished task's list.
enum TaskPlacement: String, Sendable, CaseIterable {
    case inbox, today
}

/// A committed, immutable task value. Named to stay clear of Swift's `Task`.
struct TaskItem: Identifiable, Sendable {
    let id: UUID
    /// Exactly as submitted: nonblank, one line, never trimmed or flattened.
    let title: String
    let createdAt: Date
    let contentEditedAt: Date
    let updatedAt: Date
    let revision: Int64
    let completedAt: Date?
    let archivedAt: Date?
    /// Present exactly when the task is neither completed nor archived.
    let placement: TaskPlacement?
    /// Present exactly when `placement` is; lower keys come first.
    let orderKey: Int64?

    /// Every Unicode mandatory line break: LF, VT, FF, CR, NEL, LINE and
    /// PARAGRAPH SEPARATOR. The schema checks the subset LF, CR, NEL, LS, PS.
    private static let lineBreaks: Set<UInt32> = [0x0A, 0x0B, 0x0C, 0x0D, 0x85, 0x2028, 0x2029]

    /// Whether the text has a line break by the single-line rule. Soft wrapping is layout, not text.
    static func isMultiline(_ title: String) -> Bool {
        title.unicodeScalars.contains { lineBreaks.contains($0.value) }
    }

    /// Accepts a title only as it stands; nothing is trimmed or flattened.
    static func validate(title: String) throws {
        guard !isMultiline(title) else { throw CollectionStoreError.multilineTaskTitle }
        guard Note.isNonblank(title) else { throw CollectionStoreError.blankTaskTitle }
    }
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

/// A note's committed title and text for Search. Archived notes are
/// eligible only when a query asks for them.
struct NoteSearchEntry: Equatable, Sendable {
    let id: UUID
    let title: String?
    let text: String
    let isArchived: Bool
}

/// A task's committed title for Search. Completed and archived tasks are
/// each eligible only when a query asks for them.
struct TaskSearchEntry: Equatable, Sendable {
    let id: UUID
    let title: String
    let isCompleted: Bool
    let isArchived: Bool
}

/// Every saved record from one committed state, archived notes included.
struct CollectionRecords: Equatable, Sendable {
    let collectionID: UUID
    /// Ordered by ID.
    let notes: [Note]
    /// Ordered by ID.
    let tasks: [TaskItem]
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
    case noteNotFound
    /// The note changed since the revision the command was based on.
    case staleRevision
    /// The note was archived; restore it before changing its body or pin.
    case archivedNote
    case taskNotFound
    /// The task was archived; restore it before editing, completing, reopening, moving or reordering it.
    case archivedTask
    /// A completed task has no list; reopen it before moving or reordering it.
    case completedTask
    /// The list changed since the order the reorder was based on.
    case staleList
    /// A reorder naming a task or predecessor outside its own expected order,
    /// or the task as its own predecessor.
    case invalidReorder
    case blankTaskTitle
    /// Task titles are one line; a title containing any line break is refused whole.
    case multilineTaskTitle
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

    /// Archived notes: most recently archived first, then stable ID.
    static var archivedNotes: Self {
        Self { db in
            try NoteRow.fetch(db, where: "archived_at IS NOT NULL", [], order: "archived_at DESC, id ASC")
        }
    }
}

extension CollectionQuery where Value == TaskItem? {
    static func task(_ id: UUID) -> Self {
        Self { db in try TaskRow.fetch(db, where: "id = ?", [id.uuidString]).first }
    }
}

extension CollectionQuery where Value == [TaskItem] {
    /// Inbox in manual order: ascending order key, then stable ID.
    static var inbox: Self { tasks(in: .inbox) }

    /// Today in manual order: ascending order key, then stable ID.
    static var today: Self { tasks(in: .today) }

    /// Completed, unarchived tasks: most recently completed first, then stable ID.
    static var completedTasks: Self {
        Self { db in
            try TaskRow.fetch(db, where: "completed_at IS NOT NULL AND archived_at IS NULL", [],
                              order: "completed_at DESC, id ASC")
        }
    }

    /// Archived tasks, finished or not: most recently archived first, then stable ID.
    static var archivedTasks: Self {
        Self { db in
            try TaskRow.fetch(db, where: "archived_at IS NOT NULL", [], order: "archived_at DESC, id ASC")
        }
    }

    /// Inbox or Today in manual order: ascending order key, then stable ID.
    static func tasks(in placement: TaskPlacement) -> Self {
        Self { db in
            try TaskRow.fetch(db, where: "placement = ?", [placement.rawValue], order: "order_key ASC, id ASC")
        }
    }
}

extension CollectionQuery where Value == [NoteSearchEntry] {
    /// Ordered by ID; Search does its own ranking.
    static func noteSearchEntries(includingArchived: Bool = false) -> Self {
        Self { db in
            try NoteRow.fetch(db, where: includingArchived ? "1" : "archived_at IS NULL", []).map {
                NoteSearchEntry(id: $0.id, title: $0.title, text: $0.body, isArchived: $0.archivedAt != nil)
            }
        }
    }
}

extension CollectionQuery where Value == [TaskSearchEntry] {
    /// Ordered by ID; Search does its own ranking. Each flag lifts one
    /// exclusion, so an archived completed task needs both.
    static func taskSearchEntries(includingCompleted: Bool = false, includingArchived: Bool = false) -> Self {
        Self { db in
            try TaskRow.fetch(db, where: "(? OR completed_at IS NULL) AND (? OR archived_at IS NULL)",
                              [includingCompleted, includingArchived]).map {
                TaskSearchEntry(id: $0.id, title: $0.title, isCompleted: $0.completedAt != nil, isArchived: $0.archivedAt != nil)
            }
        }
    }
}

extension CollectionQuery where Value == CollectionRecords {
    static var allRecords: Self {
        Self { db in
            guard let id = try String.fetchOne(db, sql: "SELECT id FROM collection").flatMap(UUID.init(uuidString:))
            else { throw CollectionStoreError.unreadableCollection }
            return CollectionRecords(collectionID: id, notes: try NoteRow.fetch(db, where: "1", []),
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

    // Note changes check, in order: existence, the expected revision (stale
    // fails even when the change already holds), archive state, the payload.
    // A current command whose result already holds is a no-op.

    /// Replaces the body exactly; advances content-edited time and revision.
    static func editNote(_ id: UUID, expectedRevision: Int64, body: String) -> Self {
        let payload = Data(body.utf8)
        return Self { db, context in
            let note = try NoteRow.current(db, id, expectedRevision: expectedRevision, requireUnarchived: true)
            guard Note.isNonblank(body) else { throw CollectionStoreError.blankNote }
            guard !note.body.utf8.elementsEqual(payload) else { return note }
            return try NoteRow.update(db, id, "body = CAST(? AS TEXT), content_edited_at = ?", [payload, context.now], now: context.now)
        }
    }

    /// Organization only: content-edited time is preserved.
    static func setNotePinned(_ id: UUID, _ pinned: Bool, expectedRevision: Int64) -> Self {
        Self { db, context in
            let note = try NoteRow.current(db, id, expectedRevision: expectedRevision, requireUnarchived: true)
            guard note.isPinned != pinned else { return note }
            return try NoteRow.update(db, id, "pinned = ?", [pinned], now: context.now)
        }
    }

    /// Hides the note from Notes; body, pin and content-edited time are kept.
    static func archiveNote(_ id: UUID, expectedRevision: Int64) -> Self {
        Self { db, context in
            let note = try NoteRow.current(db, id, expectedRevision: expectedRevision, requireUnarchived: false)
            guard note.archivedAt == nil else { return note }
            return try NoteRow.update(db, id, "archived_at = ?", [context.now], now: context.now)
        }
    }

    /// Returns an archived note to Notes with its body, pin and content-edited time.
    static func restoreNote(_ id: UUID, expectedRevision: Int64) -> Self {
        Self { db, context in
            let note = try NoteRow.current(db, id, expectedRevision: expectedRevision, requireUnarchived: false)
            guard note.archivedAt != nil else { return note }
            return try NoteRow.update(db, id, "archived_at = NULL", [], now: context.now)
        }
    }
}

extension CollectionCommand where Result == TaskItem {
    /// Idempotent under `operation`: an identical retry returns the task created
    /// first (in its current committed state); a different title or placement fails.
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
            try TaskItem.validate(title: title)
            let id = UUID().uuidString
            try db.execute(sql: """
                INSERT INTO task (id, title, created_at, content_edited_at, updated_at, revision,
                                  completed_at, archived_at, placement, order_key)
                VALUES (?, CAST(? AS TEXT), ?, ?, ?, 1, NULL, NULL, ?, ?)
                """, arguments: [id, payload, context.now, context.now, context.now, placement.rawValue,
                                 try TaskRow.claimTopKey(db, placement)])
            try db.execute(sql: """
                INSERT INTO creation_receipt (operation_id, note_id, task_id, payload_sha256, committed_at)
                VALUES (?, NULL, ?, ?, ?)
                """, arguments: [operation.uuidString, id, digest, context.now])
            return try TaskRow.fetch(db, where: "id = ?", [id])[0]
        }
    }

    // Task changes check, in order: existence, the expected revision (stale
    // fails even when the change already holds), archive state (only restore
    // and archive accept an archived task), then the command's own state and
    // payload. A current command whose result already holds is a no-op.

    /// Replaces the title exactly; advances content-edited time and revision.
    /// Completed tasks may be renamed; archived ones must be restored first.
    static func editTaskTitle(_ id: UUID, expectedRevision: Int64, title: String) -> Self {
        let payload = Data(title.utf8)
        return Self { db, context in
            let task = try TaskRow.current(db, id, expectedRevision: expectedRevision, requireUnarchived: true)
            try TaskItem.validate(title: title)
            guard !task.title.utf8.elementsEqual(payload) else { return task }
            return try TaskRow.update(db, id, "title = CAST(? AS TEXT), content_edited_at = ?", [payload, context.now],
                                      now: context.now)
        }
    }

    /// Moves an active unfinished task to the top of the other list.
    static func moveTask(_ id: UUID, to placement: TaskPlacement, expectedRevision: Int64) -> Self {
        Self { db, context in
            let task = try TaskRow.current(db, id, expectedRevision: expectedRevision, requireUnarchived: true)
            guard task.completedAt == nil else { throw CollectionStoreError.completedTask }
            guard task.placement != placement else { return task }
            return try TaskRow.update(db, id, "placement = ?, order_key = ?",
                                      [placement.rawValue, try TaskRow.claimTopKey(db, placement)], now: context.now)
        }
    }

    /// Moves an active unfinished task within its list to just below
    /// `predecessor`, or to the top when it is nil.
    static func reorderTask(_ id: UUID, in placement: TaskPlacement, after predecessor: UUID?,
                            expectedOrder: [UUID]) -> Self {
        Self { db, context in
            guard let task = try TaskRow.fetch(db, where: "id = ?", [id.uuidString]).first
            else { throw CollectionStoreError.taskNotFound }
            guard task.archivedAt == nil else { throw CollectionStoreError.archivedTask }
            guard task.completedAt == nil else { throw CollectionStoreError.completedTask }
            guard expectedOrder.contains(id), predecessor != id, predecessor.map(expectedOrder.contains) ?? true
            else { throw CollectionStoreError.invalidReorder }
            var list = try TaskRow.fetch(db, where: "placement = ?", [placement.rawValue], order: "order_key ASC, id ASC")
            guard list.map(\.id) == expectedOrder else { throw CollectionStoreError.staleList }
            // The list matches `expectedOrder`, so it holds the task and the predecessor.
            let current = list.firstIndex { $0.id == id }!
            list.remove(at: current)
            let position = predecessor.map { p in list.firstIndex { $0.id == p }! + 1 } ?? 0
            guard position != current else { return task }
            var key = TaskRow.key(between: position > 0 ? list[position - 1].orderKey : nil,
                                  and: position < list.count ? list[position].orderKey : nil)
            if key == nil {
                // No integer fits: renumber the list in its new order, in this transaction.
                try TaskRow.renumber(db, list.map(\.id), leavingGapAt: position)
                key = Int64(position)
            }
            return try TaskRow.update(db, id, "order_key = ?", [key], now: context.now)
        }
    }

    /// Records completion and takes the task out of its list.
    static func completeTask(_ id: UUID, expectedRevision: Int64) -> Self {
        Self { db, context in
            let task = try TaskRow.current(db, id, expectedRevision: expectedRevision, requireUnarchived: true)
            guard task.completedAt == nil else { return task }
            return try TaskRow.update(db, id, "completed_at = ?, placement = NULL, order_key = NULL", [context.now],
                                      now: context.now)
        }
    }

    /// Clears completion and returns the task to the top of Inbox, never to
    /// the list it was completed from.
    static func reopenTask(_ id: UUID, expectedRevision: Int64) -> Self {
        Self { db, context in
            let task = try TaskRow.current(db, id, expectedRevision: expectedRevision, requireUnarchived: true)
            guard task.completedAt != nil else { return task }
            return try TaskRow.update(db, id, "completed_at = NULL, placement = ?, order_key = ?",
                                      [TaskPlacement.inbox.rawValue, try TaskRow.claimTopKey(db, .inbox)], now: context.now)
        }
    }

    /// Hides the task in Archive, keeping whether it was completed.
    static func archiveTask(_ id: UUID, expectedRevision: Int64) -> Self {
        Self { db, context in
            let task = try TaskRow.current(db, id, expectedRevision: expectedRevision, requireUnarchived: false)
            guard task.archivedAt == nil else { return task }
            return try TaskRow.update(db, id, "archived_at = ?, placement = NULL, order_key = NULL", [context.now],
                                      now: context.now)
        }
    }

    /// Returns an unfinished task to the top of Inbox, or a completed one to Completed.
    static func restoreTask(_ id: UUID, expectedRevision: Int64) -> Self {
        Self { db, context in
            let task = try TaskRow.current(db, id, expectedRevision: expectedRevision, requireUnarchived: false)
            guard task.archivedAt != nil else { return task }
            if task.completedAt != nil { return try TaskRow.update(db, id, "archived_at = NULL", [], now: context.now) }
            return try TaskRow.update(db, id, "archived_at = NULL, placement = ?, order_key = ?",
                                      [TaskPlacement.inbox.rawValue, try TaskRow.claimTopKey(db, .inbox)], now: context.now)
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
        let cancelled = Mutex(false)
        do {
            result = try await withTaskCancellationHandler {
                try Task.checkCancellation()
                return try await pool.write { db in
                    // Rechecked when the serialized write executes, before any
                    // receipt lookup, and at the transaction's final boundary.
                    try self.requireCurrent(generation)
                    guard !cancelled.withLock({ $0 }) else { throw CancellationError() }
                    let result = try command.apply(db, .init(now: now))
                    try self.faults.beforeCommit?(db)
                    try self.requireCurrent(generation)
                    guard !cancelled.withLock({ $0 }) else { throw CancellationError() }
                    return result
                }
            } onCancel: {
                cancelled.withLock { $0 = true }
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

    /// Recovery's internal capture: the existing writer queue is a barrier.
    /// No command can commit between the capture timestamp, online backup and
    /// record read. No additional writable source connection is opened.
    struct SnapshotCapture: Sendable {
        let capturedAt: Date
        let records: CollectionRecords
    }

    func captureSnapshot(to database: URL, in generation: StoreGeneration,
                         atBarrier: (@Sendable () throws -> Void)? = nil,
                         beforeClose: (@Sendable () throws -> Void)? = nil) async throws -> SnapshotCapture {
        try requireCurrent(generation)
        return try await pool.writeWithoutTransaction { source in
            try self.requireCurrent(generation)
            let capturedAt = Date()
            try atBarrier?()
            let destination = try DatabaseQueue(path: database.path, configuration: CollectionSchema.configuration)
            do {
                try destination.writeWithoutTransaction { target in
                    try source.backup(to: target)
                    // A standalone closed file, with no WAL dependency, also
                    // lets inspection use a read-only connection without sidecars.
                    try target.execute(sql: "PRAGMA journal_mode = DELETE")
                }
                try beforeClose?()
                try destination.close()
                // SQLite can leave an orphan SHM index after switching the
                // backup from WAL to DELETE. All destination handles are closed;
                // the committed data must already be in the standalone file.
                let wal = URL(fileURLWithPath: database.path + "-wal")
                if FileManager.default.fileExists(atPath: wal.path) {
                    guard try Data(contentsOf: wal).isEmpty else { throw CollectionStoreError.unreadableCollection }
                    try FileManager.default.removeItem(at: wal)
                }
                let shm = URL(fileURLWithPath: database.path + "-shm")
                if FileManager.default.fileExists(atPath: shm.path) { try FileManager.default.removeItem(at: shm) }
            } catch {
                try? destination.close()
                throw CollectionStoreError.mapped(error)
            }
            return SnapshotCapture(capturedAt: capturedAt, records: try CollectionQuery.allRecords.fetch(source))
        }
    }

    /// Read-only validation of a closed, standalone backup before publication
    /// and again before disposable reopening. Database handles stay in Store.
    static func validatedSnapshotRecords(at database: URL) throws -> CollectionRecords {
        try CollectionSchema.validate(database)
        var configuration = Configuration()
        configuration.readonly = true
        let queue = try DatabaseQueue(path: database.path, configuration: configuration)
        do {
            let records = try queue.read { db in
                try CollectionSchema.validateSnapshotStructure(db)
                guard try String.fetchOne(db, sql: "PRAGMA journal_mode") == "delete",
                      try String.fetchAll(db, sql: "PRAGMA integrity_check") == ["ok"],
                      try Row.fetchAll(db, sql: "PRAGMA foreign_key_check").isEmpty
                else { throw CollectionStoreError.unreadableCollection }
                // Validate types before the typed row decoder; a damaged or
                // fabricated schema must produce an error, never a conversion trap.
                for (table, textColumn) in [("note", "body"), ("task", "title")] {
                    for row in try Row.fetchAll(db, sql: "SELECT * FROM \(table)") {
                        for column in ["created_at", "content_edited_at", "updated_at", "revision"] {
                            guard case .int64 = (row[column] as DatabaseValue).storage
                            else { throw CollectionStoreError.unreadableCollection }
                        }
                        for column in table == "note" ? ["archived_at"] : ["archived_at", "completed_at", "order_key"] {
                            switch (row[column] as DatabaseValue).storage {
                            case .null, .int64: break
                            default: throw CollectionStoreError.unreadableCollection
                            }
                        }
                        guard case let .string(id) = (row["id"] as DatabaseValue).storage,
                              // Store queries bind uuidString against case-sensitive TEXT IDs.
                              UUID(uuidString: id)?.uuidString == id,
                              case .string = (row[textColumn] as DatabaseValue).storage
                        else { throw CollectionStoreError.unreadableCollection }
                        if table == "note" {
                            guard case let .int64(pin) = (row["pinned"] as DatabaseValue).storage, pin == 0 || pin == 1
                            else { throw CollectionStoreError.unreadableCollection }
                        } else {
                            switch (row["placement"] as DatabaseValue).storage {
                            case .null: break
                            case let .string(value) where TaskPlacement(rawValue: value) != nil: break
                            default: throw CollectionStoreError.unreadableCollection
                            }
                        }
                    }
                    // Read raw bytes, because Swift's repairing UTF-8 initializer
                    // would hide invalid SQLite TEXT and lose exact note bytes.
                    for bytes in try Data.fetchAll(db, sql: "SELECT CAST(\(textColumn) AS BLOB) FROM \(table)") {
                        guard let text = String(data: bytes, encoding: .utf8), Note.isNonblank(text)
                        else { throw CollectionStoreError.unreadableCollection }
                        if table == "task" { try TaskItem.validate(title: text) }
                    }
                }
                let records = try CollectionQuery.allRecords.fetch(db)
                guard Set(records.notes.map(\.id) + records.tasks.map(\.id)).count == records.notes.count + records.tasks.count,
                      records.notes.allSatisfy({ $0.revision >= 1 }),
                      records.tasks.allSatisfy({ task in
                          task.revision >= 1 && ((task.archivedAt == nil && task.completedAt == nil) == (task.placement != nil))
                              && ((task.placement == nil) == (task.orderKey == nil))
                      })
                else { throw CollectionStoreError.unreadableCollection }
                return records
            }
            try queue.close()
            return records
        } catch {
            try? queue.close()
            throw error
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
    /// The note as it stands when the command executes, if `expectedRevision`
    /// is current and, when `requireUnarchived`, the note is not archived.
    static func current(_ db: Database, _ id: UUID, expectedRevision: Int64, requireUnarchived: Bool) throws -> Note {
        guard let note = try fetch(db, where: "id = ?", [id.uuidString]).first else { throw CollectionStoreError.noteNotFound }
        guard note.revision == expectedRevision else { throw CollectionStoreError.staleRevision }
        guard !requireUnarchived || note.archivedAt == nil else { throw CollectionStoreError.archivedNote }
        return note
    }

    /// Applies `assignment`, advancing updated time and revision.
    static func update(_ db: Database, _ id: UUID, _ assignment: String, _ arguments: StatementArguments,
                       now: Int64) throws -> Note {
        try db.execute(sql: "UPDATE note SET \(assignment), updated_at = ?, revision = revision + 1 WHERE id = ?",
                       arguments: arguments + [now, id.uuidString])
        return try fetch(db, where: "id = ?", [id.uuidString])[0]
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
    /// The task as it stands when the command executes, if `expectedRevision`
    /// is current and, when `requireUnarchived`, the task is not archived.
    static func current(_ db: Database, _ id: UUID, expectedRevision: Int64, requireUnarchived: Bool) throws -> TaskItem {
        guard let task = try fetch(db, where: "id = ?", [id.uuidString]).first else { throw CollectionStoreError.taskNotFound }
        guard task.revision == expectedRevision else { throw CollectionStoreError.staleRevision }
        guard !requireUnarchived || task.archivedAt == nil else { throw CollectionStoreError.archivedTask }
        return task
    }

    /// Applies `assignment`, advancing updated time and revision.
    static func update(_ db: Database, _ id: UUID, _ assignment: String, _ arguments: StatementArguments,
                       now: Int64) throws -> TaskItem {
        try db.execute(sql: "UPDATE task SET \(assignment), updated_at = ?, revision = revision + 1 WHERE id = ?",
                       arguments: arguments + [now, id.uuidString])
        return try fetch(db, where: "id = ?", [id.uuidString])[0]
    }

    /// The key that places a task above every task now in `placement`. When
    /// the lowest key is already `Int64.min`, the list is first renumbered
    /// 0, 1, 2… in its current order (key, then ID) inside the caller's
    /// transaction. Renumbering changes no revision or updated time: the
    /// tasks' order and facts are the same.
    static func claimTopKey(_ db: Database, _ placement: TaskPlacement) throws -> Int64 {
        guard let first = try Int64.fetchOne(db, sql: "SELECT min(order_key) FROM task WHERE placement = ?",
                                             arguments: [placement.rawValue])
        else { return 0 }
        guard first == .min else { return first - 1 }
        try renumber(db, try fetch(db, where: "placement = ?", [placement.rawValue], order: "order_key ASC, id ASC").map(\.id))
        return -1
    }

    /// Gives `ids` the keys 0, 1, 2… in the order given, leaving the key
    /// `gap` unused for the caller. Changes no revision or updated time.
    static func renumber(_ db: Database, _ ids: [UUID], leavingGapAt gap: Int? = nil) throws {
        for (offset, id) in ids.enumerated() {
            let key = Int64(gap.map { offset >= $0 ? offset + 1 : offset } ?? offset)
            try db.execute(sql: "UPDATE task SET order_key = ? WHERE id = ?", arguments: [key, id.uuidString])
        }
    }

    /// A key strictly between two neighbouring keys (nil for a list end), or
    /// nil when no integer fits there.
    static func key(between previous: Int64?, and next: Int64?) -> Int64? {
        switch (previous, next) {
        case (nil, nil): 0
        case (nil, let next?): next == .min ? nil : next - 1
        case (let previous?, nil): previous == .max ? nil : previous + 1
        case (let previous?, let next?): midpoint(previous, next)
        }
    }

    /// Computed without overflow: neighbours are sorted, so the wrapped
    /// difference read as unsigned is the true gap, and half of it fits.
    private static func midpoint(_ previous: Int64, _ next: Int64) -> Int64? {
        let gap = UInt64(bitPattern: next &- previous)
        return gap < 2 ? nil : previous &+ Int64(gap / 2)
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
final class OwnerLock: Sendable {
    private let descriptor: Int32

    /// How long a held lock may be retried before it counts as owned. A child
    /// process mid-spawn shares every file description until its exec closes
    /// close-on-exec ones, so a just-released lock can stay held for
    /// milliseconds (up to ~2 ms measured). A real owner holds it far longer.
    static let releaseGrace: Duration = .milliseconds(100)

    init(directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CollectionStoreError.missingCollection }
        let deadline = ContinuousClock.now + Self.releaseGrace
        while flock(descriptor, LOCK_EX | LOCK_NB) != 0 {
            let failure = errno
            if failure == EWOULDBLOCK, ContinuousClock.now < deadline {
                usleep(1000)
                continue
            }
            Darwin.close(descriptor)
            throw failure == EWOULDBLOCK ? CollectionStoreError.alreadyOwned : CollectionStoreError.storageFailure(code: ResultCode.SQLITE_CANTOPEN.rawValue)
        }
        self.descriptor = descriptor
    }

    deinit { Darwin.close(descriptor) }
}
