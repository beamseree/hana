import CryptoKit
import Foundation

/// Typed Collection Recovery failures. None carries note or task content.
enum CollectionRecoveryError: Error, Equatable, Sendable {
    /// The destination is missing or not a directory.
    case destinationUnavailable
    /// The destination is inside a collection root.
    case destinationInsideCollection
    case readOnlyDestination
    case insufficientSpace
    /// Another write failure, by `errno`.
    case writeFailed(code: Int32)
    /// The finished package could not be published under its new name.
    case publicationFailed(code: Int32)
    /// The package's format version is not one this build reads.
    case unsupportedFormat(version: Int)
    /// A snapshot database at a schema version this build does not read.
    case unsupportedSchema(version: Int)
    case invalidPackage(InvalidPackage)

    enum InvalidPackage: String, Equatable, Sendable {
        case missingFile, unexpectedFile, hashMismatch, countMismatch, malformed, domainViolation, contentMismatch
        /// A snapshot database that is not an intact Hana collection.
        case corruptDatabase
        /// A snapshot whose creation never finished.
        case incomplete
    }

    static func writing(_ code: Int32) -> Self {
        switch code {
        case EROFS, EACCES, EPERM: .readOnlyDestination
        case ENOSPC, EDQUOT: .insufficientSpace
        default: .writeFailed(code: code)
        }
    }
}

/// A full export package as read back and validated: every domain fact.
struct ExportedCollection: Equatable, Sendable {
    let collectionID: UUID
    let schemaVersion: Int
    let exportedAt: Date
    let notes: [Note]
    let tasks: [TaskItem]
}

/// Full export of the collection and, later, snapshots. Works from one
/// committed Store snapshot; never writes inside a collection root.
///
/// A full export is a new directory named `hana-export-<UTC time>-<id>`:
///
/// - `manifest.json`: format and version, collection ID, schema version,
///   export and latest-update times, counts, every other file's size and
///   SHA-256, and per-note metadata (ID, path, derived title, pin, times,
///   archive time, revision).
/// - `notes/<UUID>.md`: each note's exact UTF-8 bytes. Paths come only from
///   IDs, never titles.
/// - `tasks.json`: format and version, collection ID and every task's ID,
///   exact title, times, revision, completion and archive times, placement
///   and order key.
///
/// Times are integer UTC milliseconds since 1970. Absent facts are explicit
/// `null`s. Unsaved buffers, creation receipts and external app/file
/// references are not collection content and are never exported.
///
/// Future editors must flush pending edits before calling `export`; if a
/// flush fails, the export must not start.
enum CollectionRecovery {
    /// Internal fault controls for tests and the fixture harness only.
    struct Faults: Sendable {
        /// Called before each staged file is written, with its
        /// package-relative path; a returned `errno` fails that write.
        var failWrite: (@Sendable (String) -> Int32?)?
        /// Called after validation, just before publication.
        var beforePublish: (@Sendable () throws -> Void)?
    }

    struct ExportResult: Equatable, Sendable {
        let package: URL
        let collectionID: UUID
        let exportedAt: Date
        let noteCount: Int
        let taskCount: Int
        let manifestSHA256: String
    }

    static let manifestName = "manifest.json"
    static let tasksName = "tasks.json"
    static let notesDirectory = "notes"

    static func notePath(_ id: UUID) -> String { "\(notesDirectory)/\(id.uuidString).md" }

    /// Exports every note and task from one committed snapshot of `store`.
    /// Stages a fresh package on the destination volume, validates it by
    /// reading it back, then publishes it under a new name. Earlier exports are
    /// never touched; on failure nothing is published and staging is removed.
    static func export(_ store: CollectionStore, in generation: StoreGeneration, to destination: URL,
                       clock: @Sendable () -> Date = { Date() }, faults: Faults = Faults()) async throws -> ExportResult {
        try requireDestination(destination, outside: [store.location.root, CollectionLocation.defaultLiveRoot])
        let contents = try await store.read(.contents, in: generation)
        let exportedAt = CollectionStore.milliseconds(clock())
        let files = try encode(contents, exportedAt: exportedAt)

        let staging = destination.appendingPathComponent(".hana-export-\(UUID().uuidString).partial", isDirectory: true)
        try makeDirectory(staging)
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: staging) } }
        try makeDirectory(staging.appendingPathComponent(notesDirectory, isDirectory: true))
        for (path, data) in files.sorted(by: { $0.key < $1.key }) {
            if let code = faults.failWrite?(path) { throw CollectionRecoveryError.writing(code) }
            try writeFile(data, to: staging.appendingPathComponent(path))
        }
        try synchronize(staging.appendingPathComponent(notesDirectory))
        try synchronize(staging)

        let readBack = try readExport(staging)
        guard readBack.collectionID == contents.collectionID, readBack.notes == contents.notes, readBack.tasks == contents.tasks
        else { throw CollectionRecoveryError.invalidPackage(.contentMismatch) }

        let package = destination.appendingPathComponent(packageName(exportedAt), isDirectory: true)
        try faults.beforePublish?()
        guard renamex_np(staging.path, package.path, UInt32(RENAME_EXCL)) == 0
        else { throw CollectionRecoveryError.publicationFailed(code: errno) }
        published = true
        try synchronize(destination)
        return ExportResult(package: package, collectionID: contents.collectionID, exportedAt: CollectionStore.date(exportedAt),
                            noteCount: contents.notes.count, taskCount: contents.tasks.count,
                            manifestSHA256: hex(SHA256.hash(data: files[manifestName]!)))
    }

    /// Reads and fully validates a package: format version, exactly the
    /// listed files with matching sizes and hashes, counts, paths, IDs, titles
    /// and domain invariants. Anything else is refused.
    static func readExport(_ package: URL) throws -> ExportedCollection {
        let manifestData = try readFile(package.appendingPathComponent(manifestName))
        let manifest: ExportManifest = try decode(manifestData, format: ExportManifest.format)
        guard let collectionID = UUID(uuidString: manifest.collectionID), manifest.schemaVersion == CollectionSchema.version
        else { throw CollectionRecoveryError.invalidPackage(.malformed) }

        // Exactly the manifest, the listed files and the notes directory.
        var expected = Set(manifest.files.keys)
        expected.insert(manifestName)
        guard !expected.contains(where: { $0.contains("..") }) else { throw CollectionRecoveryError.invalidPackage(.malformed) }
        let found = try packageEntries(package)
        guard found.directories.subtracting([notesDirectory]).isEmpty, found.others.isEmpty
        else { throw CollectionRecoveryError.invalidPackage(.unexpectedFile) }
        guard expected.isSubset(of: found.files) else { throw CollectionRecoveryError.invalidPackage(.missingFile) }
        guard found.files.isSubset(of: expected) else { throw CollectionRecoveryError.invalidPackage(.unexpectedFile) }
        var contents: [String: Data] = [:]
        for (path, entry) in manifest.files {
            let data = try readFile(package.appendingPathComponent(path))
            guard data.count == entry.bytes, hex(SHA256.hash(data: data)) == entry.sha256
            else { throw CollectionRecoveryError.invalidPackage(.hashMismatch) }
            contents[path] = data
        }

        guard let tasksData = contents[tasksName] else { throw CollectionRecoveryError.invalidPackage(.missingFile) }
        let taskFile: ExportTasks = try decode(tasksData, format: ExportTasks.format)
        guard taskFile.collectionID == manifest.collectionID else { throw CollectionRecoveryError.invalidPackage(.malformed) }
        guard manifest.counts.notes == manifest.notes.count, manifest.counts.tasks == taskFile.tasks.count,
              manifest.files.count == manifest.notes.count + 1
        else { throw CollectionRecoveryError.invalidPackage(.countMismatch) }

        var notes: [Note] = []
        for entry in manifest.notes {
            guard let id = UUID(uuidString: entry.id), entry.path == notePath(id), let data = contents[entry.path]
            else { throw CollectionRecoveryError.invalidPackage(.malformed) }
            guard let body = String(validating: data, as: UTF8.self) else { throw CollectionRecoveryError.invalidPackage(.malformed) }
            let note = Note(id: id, body: body, createdAt: CollectionStore.date(entry.createdAt),
                            contentEditedAt: CollectionStore.date(entry.contentEditedAt), updatedAt: CollectionStore.date(entry.updatedAt),
                            revision: entry.revision, isPinned: entry.pinned, archivedAt: entry.archivedAt.map(CollectionStore.date))
            guard Note.isNonblank(body), note.revision >= 1, (note.title ?? "").utf8.elementsEqual(entry.title.utf8)
            else { throw CollectionRecoveryError.invalidPackage(.domainViolation) }
            notes.append(note)
        }
        var tasks: [TaskItem] = []
        for entry in taskFile.tasks {
            guard let id = UUID(uuidString: entry.id) else { throw CollectionRecoveryError.invalidPackage(.malformed) }
            let placement: TaskPlacement?
            if let raw = entry.placement {
                guard let known = TaskPlacement(rawValue: raw) else { throw CollectionRecoveryError.invalidPackage(.malformed) }
                placement = known
            } else {
                placement = nil
            }
            let task = TaskItem(id: id, title: entry.title, createdAt: CollectionStore.date(entry.createdAt),
                                contentEditedAt: CollectionStore.date(entry.contentEditedAt),
                                updatedAt: CollectionStore.date(entry.updatedAt), revision: entry.revision,
                                completedAt: entry.completedAt.map(CollectionStore.date),
                                archivedAt: entry.archivedAt.map(CollectionStore.date), placement: placement, orderKey: entry.orderKey)
            guard TaskItem.isValidTitle(task.title), task.revision >= 1,
                  (task.completedAt == nil && task.archivedAt == nil) == (task.placement != nil),
                  (task.placement == nil) == (task.orderKey == nil)
            else { throw CollectionRecoveryError.invalidPackage(.domainViolation) }
            tasks.append(task)
        }
        guard Set(notes.map(\.id)).count == notes.count, Set(tasks.map(\.id)).count == tasks.count
        else { throw CollectionRecoveryError.invalidPackage(.domainViolation) }
        return ExportedCollection(collectionID: collectionID, schemaVersion: manifest.schemaVersion,
                                  exportedAt: CollectionStore.date(manifest.exportedAt),
                                  notes: notes.sorted { $0.id.uuidString < $1.id.uuidString },
                                  tasks: tasks.sorted { $0.id.uuidString < $1.id.uuidString })
    }

    // MARK: Snapshots

    /// A validated, published snapshot.
    struct SnapshotInfo: Equatable, Sendable {
        let id: String
        let capturedAt: Date
        let collectionID: UUID
        let schemaVersion: Int
        let noteCount: Int
        let taskCount: Int
        /// The latest item update included; nil for an empty collection.
        let latestUpdatedAt: Date?
        let databaseBytes: Int
        let databaseSHA256: String
    }

    /// One entry of the snapshot directory: usable only when it validated.
    struct SnapshotListing: Equatable, Sendable {
        let id: String
        let result: Result<SnapshotInfo, CollectionRecoveryError>

        var isUsable: Bool { (try? result.get()) != nil }
    }

    static let snapshotsDirectory = "Snapshots"
    static let snapshotDatabaseName = "collection.sqlite"
    static let snapshotManifestName = "snapshot.json"
    private static let snapshotStagingPrefix = ".staging-"

    /// `<root>/Snapshots`, beside — never inside — the replaceable
    /// `Collection` directory.
    static func snapshotsURL(_ location: CollectionLocation) -> URL {
        location.root.appendingPathComponent(snapshotsDirectory, isDirectory: true)
    }

    /// Creates one snapshot of the committed collection with SQLite's online
    /// backup from a single Store read transaction (the capture point), off
    /// the main actor. The staged copy is closed, synchronized, reopened
    /// read-only and checked (schema, full integrity, foreign keys, domain
    /// invariants and equality with the captured contents) before its
    /// manifest is written and the directory is published under a new ID.
    /// Failures publish nothing and remove staging; existing snapshots and
    /// the live store are never modified. Retry is explicit.
    ///
    /// Fault names for `failWrite`: `collection.sqlite` (before the backup),
    /// `close` (after it), `snapshot.json`.
    static func createSnapshot(_ store: CollectionStore, in generation: StoreGeneration,
                               clock: @Sendable () -> Date = { Date() }, faults: Faults = Faults()) async throws -> SnapshotInfo {
        let directory = snapshotsURL(store.location)
        if mkdir(directory.path, 0o700) != 0, errno != EEXIST { throw CollectionRecoveryError.writing(errno) }
        var info = stat()
        guard lstat(directory.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o077 == 0
        else { throw CollectionRecoveryError.destinationUnavailable }

        let staging = directory.appendingPathComponent("\(snapshotStagingPrefix)\(UUID().uuidString)", isDirectory: true)
        try makeDirectory(staging)
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: staging) } }
        let database = staging.appendingPathComponent(snapshotDatabaseName)
        if let code = faults.failWrite?(snapshotDatabaseName) { throw CollectionRecoveryError.writing(code) }
        try writeFile(Data(), to: database)
        let captured: CollectionContents
        do {
            captured = try await store.backup(to: database, in: generation)
        } catch let error as CollectionStoreError {
            switch error {
            case .staleGeneration, .closed: throw error
            case .storageFailure(let code) where code == 13: throw CollectionRecoveryError.insufficientSpace  // SQLITE_FULL
            default: throw CollectionRecoveryError.writeFailed(code: EIO)
            }
        }
        let capturedAt = CollectionStore.milliseconds(clock())
        if let code = faults.failWrite?("close") { throw CollectionRecoveryError.writing(code) }
        try synchronize(database)

        let reread = try readSnapshotDatabase(database)
        guard reread == captured else { throw CollectionRecoveryError.invalidPackage(.contentMismatch) }
        let (bytes, digest) = try fileDigest(database)
        let id = snapshotID(capturedAt)
        let manifest = SnapshotManifest(
            format: SnapshotManifest.format, formatVersion: SnapshotManifest.formatVersion, id: id,
            capturedAt: capturedAt, capture: SnapshotManifest.captureMethod,
            collectionID: captured.collectionID.uuidString, schemaVersion: captured.schemaVersion,
            latestUpdatedAt: captured.latestUpdatedAt.map(CollectionStore.milliseconds),
            counts: .init(notes: captured.notes.count, tasks: captured.tasks.count),
            database: .init(name: snapshotDatabaseName, bytes: bytes, sha256: digest))
        if let code = faults.failWrite?(snapshotManifestName) { throw CollectionRecoveryError.writing(code) }
        try writeFile(try encoder.encode(manifest), to: staging.appendingPathComponent(snapshotManifestName))
        try synchronize(staging)

        let destination = directory.appendingPathComponent(id, isDirectory: true)
        try faults.beforePublish?()
        guard renamex_np(staging.path, destination.path, UInt32(RENAME_EXCL)) == 0
        else { throw CollectionRecoveryError.publicationFailed(code: errno) }
        published = true
        try synchronize(directory)
        return try inspectSnapshot(store.location, id: id)
    }

    /// Every entry in the snapshot directory, by name, each validated afresh.
    /// Unfinished or invalid candidates are listed as unusable, with the reason.
    static func listSnapshots(_ location: CollectionLocation) -> [SnapshotListing] {
        let directory = snapshotsURL(location)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        return names.sorted().map { name in
            if name.hasPrefix(snapshotStagingPrefix) {
                return SnapshotListing(id: name, result: .failure(.invalidPackage(.incomplete)))
            }
            do {
                return SnapshotListing(id: name, result: .success(try inspectSnapshot(location, id: name)))
            } catch let error as CollectionRecoveryError {
                return SnapshotListing(id: name, result: .failure(error))
            } catch {
                return SnapshotListing(id: name, result: .failure(.invalidPackage(.malformed)))
            }
        }
    }

    /// Fully revalidates one snapshot, read-only: exactly the manifest and
    /// database, manifest format and ID, database size and hash, schema,
    /// integrity, foreign keys, counts and domain invariants.
    static func inspectSnapshot(_ location: CollectionLocation, id: String) throws -> SnapshotInfo {
        guard !id.isEmpty, !id.contains("/"), !id.hasPrefix(".") else { throw CollectionRecoveryError.invalidPackage(.malformed) }
        let directory = snapshotsURL(location).appendingPathComponent(id, isDirectory: true)
        var info = stat()
        guard lstat(directory.path, &info) == 0 else { throw CollectionRecoveryError.invalidPackage(.missingFile) }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw CollectionRecoveryError.invalidPackage(.unexpectedFile) }
        let found = try packageEntries(directory)
        guard found.directories.isEmpty, found.others.isEmpty,
              found.files.isSubset(of: [snapshotManifestName, snapshotDatabaseName])
        else { throw CollectionRecoveryError.invalidPackage(.unexpectedFile) }
        guard found.files.contains(snapshotManifestName) else { throw CollectionRecoveryError.invalidPackage(.incomplete) }
        guard found.files.contains(snapshotDatabaseName) else { throw CollectionRecoveryError.invalidPackage(.missingFile) }

        let manifest: SnapshotManifest = try decode(try readFile(directory.appendingPathComponent(snapshotManifestName)),
                                                    format: SnapshotManifest.format)
        guard manifest.id == id, manifest.database.name == snapshotDatabaseName,
              let collectionID = UUID(uuidString: manifest.collectionID)
        else { throw CollectionRecoveryError.invalidPackage(.malformed) }
        let database = directory.appendingPathComponent(snapshotDatabaseName)
        let (bytes, digest) = try fileDigest(database)
        guard bytes == manifest.database.bytes, digest == manifest.database.sha256
        else { throw CollectionRecoveryError.invalidPackage(.hashMismatch) }
        let contents = try readSnapshotDatabase(database)
        guard contents.collectionID == collectionID, contents.schemaVersion == manifest.schemaVersion
        else { throw CollectionRecoveryError.invalidPackage(.malformed) }
        guard contents.notes.count == manifest.counts.notes, contents.tasks.count == manifest.counts.tasks
        else { throw CollectionRecoveryError.invalidPackage(.countMismatch) }
        return SnapshotInfo(id: id, capturedAt: CollectionStore.date(manifest.capturedAt), collectionID: collectionID,
                            schemaVersion: manifest.schemaVersion, noteCount: manifest.counts.notes,
                            taskCount: manifest.counts.tasks, latestUpdatedAt: manifest.latestUpdatedAt.map(CollectionStore.date),
                            databaseBytes: bytes, databaseSHA256: digest)
    }

    /// Proves a snapshot usable without touching it: validates it, copies its
    /// database into a brand-new marked disposable root (never the live root)
    /// and opens that copy with a fresh Store, returning the copy's contents.
    /// This is not a restore; nothing replaces any collection.
    static func reopenSnapshotCopy(_ location: CollectionLocation, id: String, into disposableRoot: URL) async throws -> CollectionContents {
        _ = try inspectSnapshot(location, id: id)
        let target = try CollectionLocation.createFixtureRoot(at: disposableRoot)
        try makeDirectory(target.collectionDirectory)
        let source = snapshotsURL(location).appendingPathComponent(id).appendingPathComponent(snapshotDatabaseName)
        try writeFile(try readFile(source), to: target.databaseURL)
        let store = try await CollectionStore.open(target)
        do {
            let contents = try await store.read(.contents, in: store.generation)
            await store.close()
            return contents
        } catch {
            await store.close()
            throw error
        }
    }

    /// Opens a detached snapshot database read-only and checks its domain
    /// invariants, mapping Store errors to Recovery errors.
    private static func readSnapshotDatabase(_ database: URL) throws -> CollectionContents {
        try requireRollbackJournalHeader(database)
        let contents: CollectionContents
        do {
            contents = try CollectionStore.readDetachedCopy(database)
        } catch CollectionStoreError.unsupportedSchema(let version) {
            throw CollectionRecoveryError.unsupportedSchema(version: version)
        } catch {
            throw CollectionRecoveryError.invalidPackage(.corruptDatabase)
        }
        let notesValid = contents.notes.allSatisfy { Note.isNonblank($0.body) && $0.revision >= 1 }
        let tasksValid = contents.tasks.allSatisfy { task in
            TaskItem.isValidTitle(task.title) && task.revision >= 1
                && (task.completedAt == nil && task.archivedAt == nil) == (task.placement != nil)
                && (task.placement == nil) == (task.orderKey == nil)
        }
        guard notesValid, tasksValid else { throw CollectionRecoveryError.invalidPackage(.domainViolation) }
        return contents
    }

    /// Snapshots are single rollback-journal files: header bytes 18 and 19
    /// (file format write/read versions) are 1. A WAL-marked file is refused
    /// before SQLite opens it, since opening one may create `-wal`/`-shm`
    /// files beside the snapshot.
    private static func requireRollbackJournalHeader(_ database: URL) throws {
        guard let handle = try? FileHandle(forReadingFrom: database) else { throw CollectionRecoveryError.invalidPackage(.missingFile) }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 20), header.count == 20,
              header[header.startIndex + 18] == 1, header[header.startIndex + 19] == 1
        else { throw CollectionRecoveryError.invalidPackage(.corruptDatabase) }
    }

    private static func snapshotID(_ capturedAt: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        return "\(formatter.string(from: CollectionStore.date(capturedAt)))-\(UUID().uuidString.prefix(8).lowercased())"
    }

    /// Size and SHA-256 of a file, read in chunks.
    private static func fileDigest(_ url: URL) throws -> (bytes: Int, sha256: String) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { throw CollectionRecoveryError.invalidPackage(.missingFile) }
        defer { try? handle.close() }
        var hasher = SHA256()
        var bytes = 0
        while true {
            let chunk: Data?
            do {
                chunk = try handle.read(upToCount: 1 << 20)
            } catch {
                throw CollectionRecoveryError.invalidPackage(.corruptDatabase)
            }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
            bytes += chunk.count
        }
        return (bytes, hex(hasher.finalize()))
    }

    // MARK: Encoding

    /// Package-relative path → bytes, including the manifest.
    private static func encode(_ contents: CollectionContents, exportedAt: Int64) throws -> [String: Data] {
        var files: [String: Data] = [:]
        let tasks = ExportTasks(format: ExportTasks.format, formatVersion: ExportTasks.formatVersion,
                                collectionID: contents.collectionID.uuidString,
                                tasks: contents.tasks.map(ExportTasks.Entry.init))
        files[tasksName] = try encoder.encode(tasks)
        var entries: [ExportManifest.NoteEntry] = []
        for note in contents.notes {
            let path = notePath(note.id)
            files[path] = Data(note.body.utf8)
            entries.append(ExportManifest.NoteEntry(note, path: path))
        }
        let manifest = ExportManifest(
            format: ExportManifest.format, formatVersion: ExportManifest.formatVersion,
            collectionID: contents.collectionID.uuidString, schemaVersion: contents.schemaVersion,
            exportedAt: exportedAt, latestUpdatedAt: contents.latestUpdatedAt.map(CollectionStore.milliseconds),
            counts: .init(notes: contents.notes.count, tasks: contents.tasks.count),
            files: files.mapValues { .init(bytes: $0.count, sha256: hex(SHA256.hash(data: $0))) },
            notes: entries)
        files[manifestName] = try encoder.encode(manifest)
        return files
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    /// Decodes after checking the format name and version, so an unsupported
    /// version is reported as such rather than as malformed.
    private static func decode<T: Decodable>(_ data: Data, format: String) throws -> T {
        guard let header = try? JSONDecoder().decode(FormatHeader.self, from: data), header.format == format
        else { throw CollectionRecoveryError.invalidPackage(.malformed) }
        guard header.formatVersion == 1 else { throw CollectionRecoveryError.unsupportedFormat(version: header.formatVersion) }
        guard let value = try? JSONDecoder().decode(T.self, from: data) else { throw CollectionRecoveryError.invalidPackage(.malformed) }
        return value
    }

    private static func packageName(_ exportedAt: Int64) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime, .withTimeZone]
        let stamp = formatter.string(from: CollectionStore.date(exportedAt))
        return "hana-export-\(stamp)-\(UUID().uuidString.prefix(8).lowercased())"
    }

    static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    // MARK: Files

    private static func requireDestination(_ destination: URL, outside roots: [URL]) throws {
        var info = stat()
        guard lstat(destination.path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR
        else { throw CollectionRecoveryError.destinationUnavailable }
        let resolved = destination.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
        for root in roots {
            let root = root.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
            if resolved == root || resolved.hasPrefix(root + "/") {
                throw CollectionRecoveryError.destinationInsideCollection
            }
        }
    }

    private static func makeDirectory(_ url: URL) throws {
        guard mkdir(url.path, 0o700) == 0 else { throw CollectionRecoveryError.writing(errno) }
    }

    /// Creates `url` exclusively, writes all of `data` and flushes it to stable storage.
    private static func writeFile(_ data: Data, to url: URL) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw CollectionRecoveryError.writing(errno) }
        var failure: Int32?
        data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let written = Darwin.write(descriptor, buffer.baseAddress! + offset, buffer.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    failure = errno
                    return
                }
                offset += written
            }
        }
        if failure == nil, fcntl(descriptor, F_FULLFSYNC) != 0, fsync(descriptor) != 0 { failure = errno }
        if Darwin.close(descriptor) != 0, failure == nil { failure = errno }
        if let failure { throw CollectionRecoveryError.writing(failure) }
    }

    private static func readFile(_ url: URL) throws -> Data {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw CollectionRecoveryError.invalidPackage(.missingFile) }
        guard info.st_mode & S_IFMT == S_IFREG else { throw CollectionRecoveryError.invalidPackage(.unexpectedFile) }
        guard let data = FileManager.default.contents(atPath: url.path) else { throw CollectionRecoveryError.invalidPackage(.missingFile) }
        return data
    }

    /// Package-relative regular files, directories and anything else (links,
    /// devices) below `package`.
    private static func packageEntries(_ package: URL) throws -> (files: Set<String>, directories: Set<String>, others: Set<String>) {
        guard let paths = try? FileManager.default.subpathsOfDirectory(atPath: package.path)
        else { throw CollectionRecoveryError.invalidPackage(.missingFile) }
        var files = Set<String>(), directories = Set<String>(), others = Set<String>()
        for path in paths {
            var info = stat()
            guard lstat(package.appendingPathComponent(path).path, &info) == 0 else { others.insert(path); continue }
            switch info.st_mode & S_IFMT {
            case S_IFREG: files.insert(path)
            case S_IFDIR: directories.insert(path)
            default: others.insert(path)
            }
        }
        return (files, directories, others)
    }

    private static func synchronize(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else { throw CollectionRecoveryError.writing(errno) }
        defer { Darwin.close(descriptor) }
        guard fcntl(descriptor, F_FULLFSYNC) == 0 || fsync(descriptor) == 0 else { throw CollectionRecoveryError.writing(errno) }
    }
}

// MARK: Package formats

private struct FormatHeader: Decodable {
    let format: String
    let formatVersion: Int
}

private struct ExportManifest: Codable {
    static let format = "hana.collection-export"
    static let formatVersion = 1

    struct Counts: Codable { let notes: Int; let tasks: Int }
    struct FileEntry: Codable { let bytes: Int; let sha256: String }

    struct NoteEntry: Codable {
        let id: String
        let path: String
        let title: String
        let pinned: Bool
        let createdAt: Int64
        let contentEditedAt: Int64
        let updatedAt: Int64
        let archivedAt: Int64?
        let revision: Int64

        init(_ note: Note, path: String) {
            id = note.id.uuidString
            self.path = path
            title = note.title ?? ""
            pinned = note.isPinned
            createdAt = CollectionStore.milliseconds(note.createdAt)
            contentEditedAt = CollectionStore.milliseconds(note.contentEditedAt)
            updatedAt = CollectionStore.milliseconds(note.updatedAt)
            archivedAt = note.archivedAt.map(CollectionStore.milliseconds)
            revision = note.revision
        }

        /// Writes absent facts as explicit `null`.
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(path, forKey: .path)
            try container.encode(title, forKey: .title)
            try container.encode(pinned, forKey: .pinned)
            try container.encode(createdAt, forKey: .createdAt)
            try container.encode(contentEditedAt, forKey: .contentEditedAt)
            try container.encode(updatedAt, forKey: .updatedAt)
            try container.encode(archivedAt, forKey: .archivedAt)
            try container.encode(revision, forKey: .revision)
        }
    }

    let format: String
    let formatVersion: Int
    let collectionID: String
    let schemaVersion: Int
    let exportedAt: Int64
    let latestUpdatedAt: Int64?
    let counts: Counts
    let files: [String: FileEntry]
    let notes: [NoteEntry]

    init(format: String, formatVersion: Int, collectionID: String, schemaVersion: Int, exportedAt: Int64,
         latestUpdatedAt: Int64?, counts: Counts, files: [String: FileEntry], notes: [NoteEntry]) {
        self.format = format
        self.formatVersion = formatVersion
        self.collectionID = collectionID
        self.schemaVersion = schemaVersion
        self.exportedAt = exportedAt
        self.latestUpdatedAt = latestUpdatedAt
        self.counts = counts
        self.files = files
        self.notes = notes
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(format, forKey: .format)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(collectionID, forKey: .collectionID)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(exportedAt, forKey: .exportedAt)
        try container.encode(latestUpdatedAt, forKey: .latestUpdatedAt)
        try container.encode(counts, forKey: .counts)
        try container.encode(files, forKey: .files)
        try container.encode(notes, forKey: .notes)
    }
}

private struct SnapshotManifest: Codable {
    static let format = "hana.snapshot"
    static let formatVersion = 1
    static let captureMethod = "sqlite-online-backup from one Store read transaction"

    struct Counts: Codable { let notes: Int; let tasks: Int }
    struct DatabaseFile: Codable { let name: String; let bytes: Int; let sha256: String }

    let format: String
    let formatVersion: Int
    let id: String
    /// UTC milliseconds when the backup finished.
    let capturedAt: Int64
    let capture: String
    let collectionID: String
    let schemaVersion: Int
    let latestUpdatedAt: Int64?
    let counts: Counts
    let database: DatabaseFile

    /// Writes absent facts as explicit `null`.
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(format, forKey: .format)
        try container.encode(formatVersion, forKey: .formatVersion)
        try container.encode(id, forKey: .id)
        try container.encode(capturedAt, forKey: .capturedAt)
        try container.encode(capture, forKey: .capture)
        try container.encode(collectionID, forKey: .collectionID)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(latestUpdatedAt, forKey: .latestUpdatedAt)
        try container.encode(counts, forKey: .counts)
        try container.encode(database, forKey: .database)
    }
}

private struct ExportTasks: Codable {
    static let format = "hana.tasks"
    static let formatVersion = 1

    struct Entry: Codable {
        let id: String
        let title: String
        let createdAt: Int64
        let contentEditedAt: Int64
        let updatedAt: Int64
        let revision: Int64
        let completedAt: Int64?
        let archivedAt: Int64?
        let placement: String?
        let orderKey: Int64?

        init(_ task: TaskItem) {
            id = task.id.uuidString
            title = task.title
            createdAt = CollectionStore.milliseconds(task.createdAt)
            contentEditedAt = CollectionStore.milliseconds(task.contentEditedAt)
            updatedAt = CollectionStore.milliseconds(task.updatedAt)
            revision = task.revision
            completedAt = task.completedAt.map(CollectionStore.milliseconds)
            archivedAt = task.archivedAt.map(CollectionStore.milliseconds)
            placement = task.placement?.rawValue
            orderKey = task.orderKey
        }

        /// Writes absent facts as explicit `null`.
        func encode(to encoder: any Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(id, forKey: .id)
            try container.encode(title, forKey: .title)
            try container.encode(createdAt, forKey: .createdAt)
            try container.encode(contentEditedAt, forKey: .contentEditedAt)
            try container.encode(updatedAt, forKey: .updatedAt)
            try container.encode(revision, forKey: .revision)
            try container.encode(completedAt, forKey: .completedAt)
            try container.encode(archivedAt, forKey: .archivedAt)
            try container.encode(placement, forKey: .placement)
            try container.encode(orderKey, forKey: .orderKey)
        }
    }

    let format: String
    let formatVersion: Int
    let collectionID: String
    let tasks: [Entry]
}
