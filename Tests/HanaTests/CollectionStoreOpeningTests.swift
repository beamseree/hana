import Foundation
import GRDB
import Testing
@testable import Hana

@Suite(.timeLimit(.minutes(1)))
struct CollectionStoreOpeningTests {
    @Test(arguments: Tampering.allCases)
    func refusedExistingStoresArePreservedByteForByte(_ tampering: Tampering) async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        _ = try await store.perform(.createNote(operation: UUID(), body: "Keep me"), in: store.generation)
        await store.close()
        try tampering.apply(to: fixture.location)
        let before = try FileTree(fixture.location.root)

        await #expect(throws: tampering.expected) { _ = try await CollectionStore.open(fixture.location) }

        let after = try FileTree(fixture.location.root)
        // Durable artifacts stay byte-identical. SQLite's `-shm` WAL index is
        // transient shared memory any reader may rebuild; it must only survive.
        for (path, bytes) in before.files where !path.hasSuffix("-shm") {
            #expect(after.files[path] == bytes, "\(path) changed or vanished")
        }
        #expect(Set(before.files.keys).isSubset(of: after.files.keys))
        let added = Set(after.files.keys).subtracting(before.files.keys)
        #expect(added.allSatisfy { $0.hasSuffix("-wal") || $0.hasSuffix("-shm") }, "unexpected \(added)")
        #expect(Set(before.directories).isSubset(of: after.directories))
    }

    @Test func aSecondOwnerIsRefusedUntilTheFirstCloses() async throws {
        let fixture = try TemporaryFixture()
        let first = try await CollectionStore.open(fixture.location)
        await #expect(throws: CollectionStoreError.alreadyOwned) { _ = try await CollectionStore.open(fixture.location) }
        await first.close()
        let second = try await CollectionStore.open(fixture.location)
        #expect(second.generation != first.generation)
        await second.close()
    }

    @Test func storageIsOwnerOnlyWhileLiveAndRefusedWhenWidened() async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        _ = try await store.perform(.createNote(operation: UUID(), body: "Private"), in: store.generation)
        let tree = try FileTree(fixture.location.root)
        #expect(tree.files.keys.contains("Collection/collection.sqlite-wal"))
        for (path, mode) in tree.modes {
            let isDirectory = tree.directories.contains(path)
            #expect(mode == (isDirectory ? 0o700 : 0o600), "\(path) has mode \(String(mode, radix: 8))")
        }
        await store.close()
        #expect(chmod(fixture.location.root.path, 0o755) == 0)
        await #expect(throws: CollectionStoreError.insecureStorage) { _ = try await CollectionStore.open(fixture.location) }
    }

    @Test func fixtureRootsMustBeNewMarkedAndOutsideTheLiveRoot() throws {
        let fixture = try TemporaryFixture()
        let live = fixture.directory.appendingPathComponent("Application Support/com.beamseree.hana", isDirectory: true)
        // Path-based refusal while the live root does not exist yet.
        #expect(throws: CollectionStoreError.liveRootRefused) {
            try CollectionLocation.createFixtureRoot(at: live.appendingPathComponent("child"), liveRoot: live)
        }
        #expect(!FileManager.default.fileExists(atPath: live.path))
        try FileManager.default.createDirectory(at: live, withIntermediateDirectories: true)
        let alias = fixture.directory.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: live)
        let upper = URL(fileURLWithPath: live.path.uppercased())
        for candidate in [live, live.appendingPathComponent("child"), alias, alias.appendingPathComponent("child"),
                          upper.appendingPathComponent("child")] {
            #expect(throws: CollectionStoreError.liveRootRefused) { try CollectionLocation.createFixtureRoot(at: candidate, liveRoot: live) }
            #expect(throws: CollectionStoreError.liveRootRefused) { try CollectionLocation.fixture(candidate, liveRoot: live) }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: live.path).isEmpty)

        // The real live root is refused without being created.
        let real = CollectionLocation.defaultLiveRoot
        let existed = FileManager.default.fileExists(atPath: real.path)
        #expect(throws: CollectionStoreError.liveRootRefused) { try CollectionLocation.createFixtureRoot(at: real.appendingPathComponent("fixture")) }
        #expect(throws: CollectionStoreError.liveRootRefused) { try CollectionLocation.fixture(real) }
        #expect(FileManager.default.fileExists(atPath: real.path) == existed)

        // Reopening requires the disposable marker; creation requires a new path.
        #expect(try CollectionLocation.fixture(fixture.location.root) == fixture.location)
        #expect(throws: CollectionStoreError.fixtureRootUnavailable) { try CollectionLocation.createFixtureRoot(at: fixture.location.root) }
        let unmarked = fixture.directory.appendingPathComponent("unmarked")
        try FileManager.default.createDirectory(at: unmarked, withIntermediateDirectories: false)
        #expect(throws: CollectionStoreError.notDisposableFixture) { try CollectionLocation.fixture(unmarked) }
    }
}

extension CollectionStoreOpeningTests {
    @Test func linkedRuntimeUsesDurableSettingsAndOnlyTheWriterCanWriteOrCheckpoint() async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        let report = try await store.runtimeReport()
        #expect(!report.sqliteVersion.isEmpty && !report.sqliteSourceID.isEmpty)
        for settings in [report.writer, report.reader] {
            #expect(settings.journalMode == "wal")
            #expect(settings.synchronous == 2) // FULL
            #expect(settings.fullfsync == 1 && settings.checkpointFullfsync == 1)
            #expect(settings.foreignKeys == 1)
        }
        #expect(report.writer.isReadOnly == false)
        // The WAL-reset bug needs two connections writing or checkpointing the
        // same file; pool readers can do neither.
        #expect(report.reader.isReadOnly == true)
        #expect(report.reader.checkpointResult == 8) // SQLITE_READONLY
        #expect(report.writer.walAutocheckpoint == 1000)

        let wal = fixture.location.databaseURL.path + "-wal"
        func walSize() throws -> Int { try FileManager.default.attributesOfItem(atPath: wal)[.size] as? Int ?? -1 }
        _ = try await store.perform(.createNote(operation: UUID(), body: "In the WAL"), in: store.generation)
        #expect(try walSize() > 0)
        await store.close()
        // Close checkpoints and truncates the WAL from the writer connection.
        #expect(try walSize() == 0)
    }
}

enum Tampering: CaseIterable, Sendable {
    case missingDatabase, emptyCollectionDirectory, notADatabase, truncated, newerSchema, olderSchema, foreignDatabase

    var expected: CollectionStoreError {
        switch self {
        case .missingDatabase, .emptyCollectionDirectory: .missingCollection
        case .notADatabase, .truncated: .unreadableCollection
        case .newerSchema: .unsupportedSchema(version: 2)
        case .olderSchema: .unsupportedSchema(version: 0)
        case .foreignDatabase: .notHanaCollection
        }
    }

    func apply(to location: CollectionLocation) throws {
        let database = location.databaseURL
        switch self {
        case .missingDatabase:
            try FileManager.default.removeItem(at: database)
            try Data("orphaned sidecar".utf8).write(to: URL(fileURLWithPath: database.path + "-wal"))
        case .emptyCollectionDirectory:
            try FileManager.default.removeItem(at: database)
        case .notADatabase:
            try Data(repeating: 0x5A, count: 8192).write(to: database)
        case .truncated:
            let handle = try FileHandle(forWritingTo: database)
            try handle.truncate(atOffset: 4096)
            try handle.close()
        case .newerSchema, .olderSchema, .foreignDatabase:
            let queue = try DatabaseQueue(path: database.path)
            try queue.writeWithoutTransaction { db in
                switch self {
                case .newerSchema: try db.execute(sql: "PRAGMA user_version = 2")
                case .olderSchema: try db.execute(sql: "PRAGMA user_version = 0")
                default: try db.execute(sql: "PRAGMA application_id = 0")
                }
            }
            try queue.close()
        }
    }
}

/// Every file's bytes and every entry's permission bits below a root.
struct FileTree {
    var files: [String: Data] = [:]
    var directories: [String] = []
    var modes: [String: mode_t] = [:]

    init(_ root: URL) throws {
        let base = root.resolvingSymlinksInPath().path + "/"
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]))
        for case let url as URL in enumerator {
            let path = String(url.resolvingSymlinksInPath().path.dropFirst(base.count))
            var info = stat()
            #expect(lstat(url.path, &info) == 0)
            modes[path] = info.st_mode & 0o777
            if info.st_mode & S_IFMT == S_IFDIR { directories.append(path) } else { files[path] = try Data(contentsOf: url) }
        }
    }
}
