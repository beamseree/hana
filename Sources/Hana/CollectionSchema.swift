import Foundation
import GRDB

/// Initial schema, connection settings, new-store initialization and
/// existing-store validation. Only schema version 1 exists; any other history
/// is refused without modifying the store.
enum CollectionSchema {
    static let version = 1
    /// `PRAGMA application_id` for Hana collections: ASCII "Hana".
    static let applicationID = 0x4861_6E61

    /// WAL with `synchronous=FULL` and macOS full-sync on every connection.
    /// Pool readers are opened read-only by GRDB, so only the single writer
    /// connection ever writes or checkpoints.
    static var configuration: Configuration {
        var configuration = Configuration()
        configuration.label = "Hana.Collection"
        configuration.foreignKeysEnabled = true
        configuration.prepareDatabase { db in
            try db.execute(sql: "PRAGMA synchronous = FULL; PRAGMA fullfsync = ON; PRAGMA checkpoint_fullfsync = ON")
        }
        return configuration
    }

    /// Opens the pool and re-asserts `synchronous=FULL` on its writer: GRDB's
    /// WAL setup sets the writer to NORMAL after `prepareDatabase` runs.
    static func openPool(_ database: URL) throws -> DatabasePool {
        let pool = try DatabasePool(path: database.path, configuration: configuration)
        let synchronous = try pool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA synchronous = FULL")
            return try Int.fetchOne(db, sql: "PRAGMA synchronous")
        }
        guard synchronous == 2 else { throw CollectionStoreError.storageFailure(code: ResultCode.SQLITE_MISUSE.rawValue) }
        return pool
    }

    private static let statements = """
        CREATE TABLE schema_history (
            version INTEGER PRIMARY KEY NOT NULL,
            applied_at INTEGER NOT NULL,
            description TEXT NOT NULL
        ) STRICT;
        CREATE TABLE collection (
            singleton INTEGER PRIMARY KEY NOT NULL CHECK (singleton = 1),
            id TEXT NOT NULL CHECK (length(id) = 36),
            created_at INTEGER NOT NULL
        ) STRICT;
        CREATE TABLE note (
            id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
            body TEXT NOT NULL,
            created_at INTEGER NOT NULL,
            content_edited_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            revision INTEGER NOT NULL CHECK (revision >= 1),
            pinned INTEGER NOT NULL CHECK (pinned IN (0, 1)),
            archived_at INTEGER
        ) STRICT;
        CREATE INDEX note_active_order ON note (pinned DESC, content_edited_at DESC, id) WHERE archived_at IS NULL;
        CREATE TABLE task (
            id TEXT PRIMARY KEY NOT NULL CHECK (length(id) = 36),
            title TEXT NOT NULL CHECK (
                title <> '' AND instr(title, char(10)) = 0 AND instr(title, char(13)) = 0
                AND instr(title, char(133)) = 0 AND instr(title, char(8232)) = 0 AND instr(title, char(8233)) = 0),
            created_at INTEGER NOT NULL,
            content_edited_at INTEGER NOT NULL,
            updated_at INTEGER NOT NULL,
            revision INTEGER NOT NULL CHECK (revision >= 1),
            completed_at INTEGER,
            archived_at INTEGER,
            placement TEXT CHECK (placement IN ('inbox', 'today')),
            order_key INTEGER,
            CHECK ((completed_at IS NULL AND archived_at IS NULL) = (placement IS NOT NULL)),
            CHECK ((placement IS NULL) = (order_key IS NULL))
        ) STRICT;
        CREATE INDEX task_active_order ON task (placement, order_key, id) WHERE placement IS NOT NULL;
        CREATE TABLE creation_receipt (
            operation_id TEXT PRIMARY KEY NOT NULL CHECK (length(operation_id) = 36),
            note_id TEXT UNIQUE REFERENCES note (id),
            task_id TEXT UNIQUE REFERENCES task (id),
            payload_sha256 BLOB NOT NULL CHECK (length(payload_sha256) = 32),
            committed_at INTEGER NOT NULL,
            CHECK ((note_id IS NULL) <> (task_id IS NULL))
        ) STRICT;
        """

    /// Builds a complete store in a private staging directory and publishes it
    /// by renaming that directory into place, so an interrupted initialization
    /// never leaves a half-made collection at the real path.
    static func initialize(_ location: CollectionLocation, now: Int64) throws {
        let staging = location.root.appendingPathComponent(".Collection.initializing-\(UUID().uuidString)", isDirectory: true)
        guard mkdir(staging.path, 0o700) == 0 else { throw CollectionStoreError.insecureStorage }
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: staging) } }
        let database = staging.appendingPathComponent(location.databaseURL.lastPathComponent)
        guard FileManager.default.createFile(atPath: database.path, contents: nil, attributes: [.posixPermissions: 0o600])
        else { throw CollectionStoreError.insecureStorage }
        do {
            let pool = try openPool(database)
            try pool.write { db in
                try db.execute(sql: statements)
                try db.execute(sql: "INSERT INTO schema_history (version, applied_at, description) VALUES (1, ?, 'Initial collection')",
                               arguments: [now])
                try db.execute(sql: "INSERT INTO collection (singleton, id, created_at) VALUES (1, ?, ?)",
                               arguments: [UUID().uuidString, now])
                try db.execute(sql: "PRAGMA application_id = \(applicationID); PRAGMA user_version = \(version)")
            }
            _ = try pool.writeWithoutTransaction { try $0.checkpoint(.truncate) }
            try pool.close()
        } catch {
            throw CollectionStoreError.mapped(error)
        }
        try synchronize(database)
        try synchronize(staging)
        guard renamex_np(staging.path, location.collectionDirectory.path, UInt32(RENAME_EXCL)) == 0 else {
            // Another owner published first; its store is validated normally.
            guard errno == EEXIST else { throw CollectionStoreError.insecureStorage }
            return
        }
        published = true
        try synchronize(location.root)
    }

    /// Reads an existing store without writing to it. Anything other than a
    /// readable Hana collection at exactly the supported schema is refused.
    static func validate(_ database: URL) throws {
        guard FileManager.default.fileExists(atPath: database.path) else { throw CollectionStoreError.missingCollection }
        var configuration = Configuration()
        configuration.readonly = true
        do {
            let queue = try DatabaseQueue(path: database.path, configuration: configuration)
            defer { try? queue.close() }
            try queue.read { db in
                guard try Int.fetchOne(db, sql: "PRAGMA application_id") == applicationID
                else { throw CollectionStoreError.notHanaCollection }
                let found = try Int.fetchOne(db, sql: "PRAGMA user_version") ?? 0
                guard found == version else { throw CollectionStoreError.unsupportedSchema(version: found) }
                guard try Int.fetchAll(db, sql: "SELECT version FROM schema_history ORDER BY version") == [version]
                else { throw CollectionStoreError.unsupportedSchema(version: found) }
                guard try String.fetchAll(db, sql: "PRAGMA quick_check") == ["ok"],
                      try Int.fetchOne(db, sql: "SELECT count(*) FROM collection") == 1
                else { throw CollectionStoreError.unreadableCollection }
            }
        } catch let error as CollectionStoreError {
            throw error
        } catch {
            throw CollectionStoreError.unreadableCollection
        }
    }

    private static func synchronize(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw CollectionStoreError.insecureStorage }
        defer { close(descriptor) }
        guard fcntl(descriptor, F_FULLFSYNC) == 0 || fsync(descriptor) == 0 else { throw CollectionStoreError.insecureStorage }
    }
}
