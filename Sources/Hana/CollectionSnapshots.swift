import CryptoKit
import Foundation

extension CollectionRecovery {
    struct SnapshotManifest: Codable, Equatable, Sendable {
        let formatVersion: Int
        let schemaVersion: Int
        let snapshotID: UUID
        /// UTC wall-clock instant sampled under the Store writer barrier;
        /// this is not the timestamp of the most recent database commit.
        let capturedAtUTC: String
        let captureProvenance: String
        let collectionID: UUID
        let noteCount: Int
        let taskCount: Int
        let databaseSHA256: String
    }

    struct Snapshot: Sendable {
        let url: URL
        let manifest: SnapshotManifest
    }

    enum SnapshotError: Error, Equatable, Sendable {
        case unsafeLocation, incomplete, invalidManifest, invalidDatabase
        case unsupportedVersion
        case fileFailure(code: Int32)
        case publicationFailure(code: Int32)
    }

    struct SnapshotInspection: Sendable {
        let url: URL
        let validation: Result<SnapshotManifest, SnapshotError>
        var manifest: SnapshotManifest? { try? validation.get() }
        var failure: SnapshotError? {
            if case let .failure(error) = validation { error } else { nil }
        }
        var isUsable: Bool { if case .success = validation { true } else { false } }
    }

    @concurrent static func inspectSnapshot(at url: URL) async -> SnapshotInspection {
        do { return SnapshotInspection(url: url, validation: .success(try validateSnapshot(at: url))) }
        catch { return SnapshotInspection(url: url, validation: .failure(error as? SnapshotError ?? .invalidDatabase)) }
    }

    /// Every candidate gets a diagnostic; only validated published packages
    /// have `isUsable`. Incomplete attempts are retained, never retried here.
    @concurrent static func listSnapshots(in directory: URL) async throws -> [SnapshotInspection] {
        try requireSnapshotItem(directory, type: S_IFDIR)
        let candidates = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        var inspections: [SnapshotInspection] = []
        for candidate in candidates { inspections.append(await inspectSnapshot(at: candidate)) }
        return inspections
    }

    enum SnapshotPhase: String, Sendable {
        case staging, capturing, closing, validating, writingManifest, publishing, complete, failed
    }

    /// Internal controls for deterministic capture/failure tests only.
    struct SnapshotFaults: Sendable {
        var captureBarrier: (@Sendable () throws -> Void)?
        var atPhase: (@Sendable (SnapshotPhase) throws -> Void)?
    }

    /// A manual copy on the destination volume. Failed staging is retained for
    /// inspection; retry always creates a new package and never overwrites one.
    @concurrent static func createSnapshot(from store: CollectionStore, in generation: StoreGeneration,
                                           destination: URL, faults: SnapshotFaults = .init(),
                                           onStatus: @escaping @Sendable (SnapshotPhase) -> Void = { _ in }) async throws -> Snapshot {
        var complete = false
        defer { if !complete { onStatus(.failed) } }
        @Sendable func phase(_ value: SnapshotPhase) throws {
            onStatus(value)
            try faults.atPhase?(value)
        }
        try phase(.staging)
        try prepareSnapshotDirectory(destination, excluding: store.location.collectionDirectory)
        let id = UUID()
        let staging = destination.appendingPathComponent(".incomplete-\(id.uuidString)")
        try makeSnapshotDirectory(staging)
        let database = staging.appendingPathComponent("collection.sqlite")
        let descriptor = open(database.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw SnapshotError.fileFailure(code: errno) }
        guard close(descriptor) == 0 else { throw SnapshotError.fileFailure(code: errno) }
        try phase(.capturing)
        let capture = try await store.captureSnapshot(to: database, in: generation,
            atBarrier: faults.captureBarrier, beforeClose: { try phase(.closing) })
        try phase(.validating)
        let validated = try CollectionStore.validatedSnapshotRecords(at: database)
        guard validated == capture.records else { throw SnapshotError.invalidDatabase }
        let manifest = SnapshotManifest(formatVersion: 1, schemaVersion: CollectionSchema.version, snapshotID: id,
            capturedAtUTC: capture.capturedAt.ISO8601Format(Date.ISO8601FormatStyle(includingFractionalSeconds: true, timeZone: .gmt)),
            captureProvenance: "store-writer-barrier-online-backup-v1", collectionID: capture.records.collectionID,
            noteCount: capture.records.notes.count, taskCount: capture.records.tasks.count,
            databaseSHA256: try snapshotHash(database))
        try phase(.writingManifest)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"), options: .withoutOverwriting)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.appendingPathComponent("manifest.json").path)
        _ = try validateSnapshot(at: staging, stagedID: id)
        let published = destination.appendingPathComponent("snapshot-\(id.uuidString)")
        try phase(.publishing)
        guard renamex_np(staging.path, published.path, UInt32(RENAME_EXCL)) == 0
        else { throw SnapshotError.publicationFailure(code: errno) }
        complete = true
        onStatus(.complete)
        return Snapshot(url: published, manifest: manifest)
    }

    /// Verification only: create a new marked disposable root. The sole
    /// published snapshot is never opened as a writable Store or replaced.
    @concurrent static func reopenSnapshot(at snapshot: URL, disposableRoot: URL) async throws -> CollectionStore {
        _ = try validateSnapshot(at: snapshot)
        try requireOutsideSnapshot(disposableRoot, snapshot: snapshot)
        let source = snapshot.appendingPathComponent("collection.sqlite")
        let location = try CollectionLocation.createFixtureRoot(at: disposableRoot)
        try makeSnapshotDirectory(location.collectionDirectory)
        try FileManager.default.copyItem(at: source, to: location.databaseURL)
        // Validate the actual copied bytes too, before opening a new writer.
        let manifest = try validateSnapshot(at: snapshot)
        guard try snapshotHash(location.databaseURL) == manifest.databaseSHA256 else { throw SnapshotError.invalidManifest }
        _ = try CollectionStore.validatedSnapshotRecords(at: location.databaseURL)
        return try await CollectionStore.open(location)
    }

    private static func validateSnapshot(at url: URL, stagedID: UUID? = nil) throws -> SnapshotManifest {
        if stagedID == nil, url.lastPathComponent.hasPrefix(".incomplete-") { throw SnapshotError.incomplete }
        try requireSnapshotItem(url, type: S_IFDIR)
        let database = url.appendingPathComponent("collection.sqlite")
        let manifestURL = url.appendingPathComponent("manifest.json")
        let names = try Set(FileManager.default.contentsOfDirectory(atPath: url.path))
        guard names == ["collection.sqlite", "manifest.json"] else { throw SnapshotError.incomplete }
        try requireSnapshotItem(database, type: S_IFREG)
        try requireSnapshotItem(manifestURL, type: S_IFREG)
        let manifest: SnapshotManifest
        do { manifest = try JSONDecoder().decode(SnapshotManifest.self, from: Data(contentsOf: manifestURL)) }
        catch { throw SnapshotError.invalidManifest }
        guard manifest.formatVersion == 1, manifest.schemaVersion == CollectionSchema.version
        else { throw SnapshotError.unsupportedVersion }
        guard (stagedID ?? manifest.snapshotID) == manifest.snapshotID,
              stagedID != nil || url.lastPathComponent == "snapshot-\(manifest.snapshotID.uuidString)",
              manifest.capturedAtUTC.hasSuffix("Z"),
              (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(manifest.capturedAtUTC)) != nil,
              manifest.captureProvenance == "store-writer-barrier-online-backup-v1",
              try snapshotHash(database) == manifest.databaseSHA256
        else { throw SnapshotError.invalidManifest }
        let records: CollectionRecords
        do { records = try CollectionStore.validatedSnapshotRecords(at: database) }
        catch CollectionStoreError.unsupportedSchema { throw SnapshotError.unsupportedVersion }
        catch { throw SnapshotError.invalidDatabase }
        guard records.collectionID == manifest.collectionID,
              records.notes.count == manifest.noteCount, records.tasks.count == manifest.taskCount
        else { throw SnapshotError.invalidManifest }
        return manifest
    }

    private static func requireSnapshotItem(_ url: URL, type: mode_t) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == type, info.st_uid == geteuid(),
              info.st_mode & 0o077 == 0,
              type != S_IFREG || info.st_nlink == 1
        else { throw SnapshotError.unsafeLocation }
    }

    private static func requireOutsideSnapshot(_ destination: URL, snapshot: URL) throws {
        let path = destination.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
        let snapshotPath = snapshot.resolvingSymlinksInPath().standardizedFileURL.path.lowercased()
        guard path != snapshotPath, !path.hasPrefix(snapshotPath + "/") else { throw SnapshotError.unsafeLocation }
    }

    private static func snapshotHash(_ file: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
    }

    private static func makeSnapshotDirectory(_ url: URL) throws {
        guard mkdir(url.path, 0o700) == 0 else { throw SnapshotError.fileFailure(code: errno) }
    }

    private static func prepareSnapshotDirectory(_ url: URL, excluding source: URL) throws {
        let path = url.resolvingSymlinksInPath().standardizedFileURL.path
        let sourcePath = source.resolvingSymlinksInPath().standardizedFileURL.path
        guard path != sourcePath, !path.hasPrefix(sourcePath + "/") else { throw SnapshotError.unsafeLocation }
        if !FileManager.default.fileExists(atPath: url.path) { try makeSnapshotDirectory(url) }
        try requireSnapshotItem(url, type: S_IFDIR)
    }
}
