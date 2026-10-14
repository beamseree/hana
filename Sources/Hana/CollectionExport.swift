import CryptoKit
import Foundation

extension CollectionRecovery {
    enum ExportError: Error, Equatable, Sendable {
        case invalidPackage
        case unsupportedVersion
        case destinationRefused
        case unsupportedDestination
        case writeFailure(code: Int32)
        case readOnly
        case noSpace
        case publicationFailure(code: Int32)
    }

    /// Bounded filesystem fault controls for tests and fixture-mode callers.
    struct ExportFaults: Sendable {
        var beforeWrite: (@Sendable (String) throws -> Void)?
        var beforePublish: (@Sendable (URL, URL) throws -> Void)?
    }

    struct ExportResult: Sendable {
        let url: URL
        let collectionID: UUID
        let noteCount: Int
        let taskCount: Int
    }

    /// Captures all records in one Store read. Future editors must successfully
    /// flush before calling this; unsaved caller buffers are never accepted.
    static func export(from store: CollectionStore, in generation: StoreGeneration,
                       to destination: URL, faults: ExportFaults = .init()) async throws -> ExportResult {
        let started = CollectionStore.milliseconds(Date())
        let records = try await store.read(.allRecords, in: generation)
        let finished = CollectionStore.milliseconds(Date())
        return try await Task.detached {
            let parent = try exportDestination(destination, source: store.location.root)
            return try writeExport(records, started: started, finished: finished, to: parent, faults: faults)
        }.value
    }

    private static func writeExport(_ records: CollectionRecords, started: Int64, finished: Int64,
                                    to destination: URL, faults: ExportFaults) throws -> ExportResult {
        let id = UUID().uuidString
        let package = destination.appendingPathComponent(".hana-export-\(id).partial", isDirectory: true)
        let published = destination.appendingPathComponent("Hana-export-\(id)", isDirectory: true)
        guard mkdir(package.path, 0o700) == 0 else { throw exportWriteError(errno) }
        defer { try? FileManager.default.removeItem(at: package) }
        guard mkdir(package.appendingPathComponent("notes").path, 0o700) == 0 else { throw exportWriteError(errno) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let noteMetadata = try records.notes.map { note in
            let path = "notes/\(note.id.uuidString).md"
            let data = Data(note.body.utf8)
            try writeExportFile(data, path: path, in: package, faults: faults)
            return ExportNote(id: note.id, path: path, title: note.title, sha256: exportHash(data), byteCount: data.count,
                              createdAt: CollectionStore.milliseconds(note.createdAt),
                              contentEditedAt: CollectionStore.milliseconds(note.contentEditedAt),
                              updatedAt: CollectionStore.milliseconds(note.updatedAt), revision: note.revision,
                              pinned: note.isPinned, archivedAt: note.archivedAt.map(CollectionStore.milliseconds))
        }
        let taskMetadata = records.tasks.map { task in
            ExportTask(id: task.id, title: task.title, createdAt: CollectionStore.milliseconds(task.createdAt),
                       contentEditedAt: CollectionStore.milliseconds(task.contentEditedAt),
                       updatedAt: CollectionStore.milliseconds(task.updatedAt), revision: task.revision,
                       completedAt: task.completedAt.map(CollectionStore.milliseconds),
                       archivedAt: task.archivedAt.map(CollectionStore.milliseconds),
                       placement: task.placement?.rawValue, orderKey: task.orderKey)
        }
        let tasks = try encoder.encode(ExportTasks(formatVersion: 1, collectionID: records.collectionID, tasks: taskMetadata))
        try writeExportFile(tasks, path: "tasks.json", in: package, faults: faults)
        let manifest = ExportManifest(formatVersion: 1, collectionID: records.collectionID,
                                      captureStartedAt: started, captureFinishedAt: finished,
                                      packagedAt: CollectionStore.milliseconds(Date()),
                                      captureMethod: "single-committed-store-read", noteCount: noteMetadata.count, taskCount: taskMetadata.count,
                                      tasksSHA256: exportHash(tasks), notes: noteMetadata)
        try writeExportFile(encoder.encode(manifest), path: "manifest.json", in: package, faults: faults)
        do { try faults.beforePublish?(package, published) }
        catch { throw ExportError.publicationFailure(code: exportPOSIXCode(error)) }
        _ = try validateExportPackage(package)
        // Both names share an existing local destination directory. EXCL never
        // replaces a prior export, even if a name appears after validation.
        guard renamex_np(package.path, published.path, UInt32(RENAME_EXCL)) == 0
        else { throw ExportError.publicationFailure(code: errno) }
        return ExportResult(url: published, collectionID: records.collectionID, noteCount: noteMetadata.count, taskCount: taskMetadata.count)
    }

    private static func exportDestination(_ url: URL, source: URL) throws -> URL {
        guard url.isFileURL else { throw ExportError.unsupportedDestination }
        let parent = url.standardizedFileURL.resolvingSymlinksInPath()
        for root in [source, CollectionLocation.defaultLiveRoot] {
            let protected = root.standardizedFileURL.resolvingSymlinksInPath().path.lowercased()
            let candidate = parent.path.lowercased()
            guard candidate != protected, !candidate.hasPrefix(protected + "/") else { throw ExportError.destinationRefused }
        }
        var info = stat()
        guard stat(parent.path, &info) == 0 else { throw exportWriteError(errno) }
        guard info.st_mode & S_IFMT == S_IFDIR else { throw ExportError.unsupportedDestination }
        var filesystem = statfs()
        guard statfs(parent.path, &filesystem) == 0 else { throw exportWriteError(errno) }
        guard filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else { throw ExportError.unsupportedDestination }
        return parent
    }

    private static func writeExportFile(_ data: Data, path: String, in package: URL, faults: ExportFaults) throws {
        do {
            try faults.beforeWrite?(path)
            let url = package.appendingPathComponent(path)
            let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
        } catch { throw exportWriteError(exportPOSIXCode(error)) }
    }

    private static func exportPOSIXCode(_ error: any Error) -> Int32 {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain { return Int32(nsError.code) }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError { return exportPOSIXCode(underlying) }
        return EIO
    }

    private static func exportWriteError(_ code: Int32) -> ExportError {
        switch code {
        case EROFS: .readOnly
        case ENOSPC, EDQUOT: .noSpace
        default: .writeFailure(code: code)
        }
    }

    /// Revalidates a portable package; this is inspection, not import.
    static func validateExport(at package: URL) async throws -> ExportResult {
        guard !package.lastPathComponent.hasPrefix(".hana-export-") else { throw ExportError.invalidPackage }
        return try await Task.detached { try validateExportPackage(package) }.value
    }

    private static func validateExportPackage(_ package: URL) throws -> ExportResult {
        do {
            try requireExportFile(package, type: S_IFDIR)
            let manifestURL = package.appendingPathComponent("manifest.json")
            let tasksURL = package.appendingPathComponent("tasks.json")
            let notesURL = package.appendingPathComponent("notes")
            try requireExportFile(manifestURL, type: S_IFREG)
            try requireExportFile(tasksURL, type: S_IFREG)
            try requireExportFile(notesURL, type: S_IFDIR)
            let decoder = JSONDecoder()
            let manifest = try decoder.decode(ExportManifest.self, from: Data(contentsOf: manifestURL))
            guard manifest.formatVersion == 1 else { throw ExportError.unsupportedVersion }
            let taskBytes = try Data(contentsOf: tasksURL)
            guard exportHash(taskBytes) == manifest.tasksSHA256 else { throw ExportError.invalidPackage }
            let tasks = try decoder.decode(ExportTasks.self, from: taskBytes)
            guard tasks.formatVersion == 1 else { throw ExportError.unsupportedVersion }
            guard manifest.collectionID == tasks.collectionID,
                  manifest.noteCount == manifest.notes.count, manifest.taskCount == tasks.tasks.count,
                  manifest.captureMethod == "single-committed-store-read",
                  Set(manifest.notes.map(\.id)).count == manifest.notes.count,
                  Set(tasks.tasks.map(\.id)).count == tasks.tasks.count,
                  Set(manifest.notes.map(\.id)).isDisjoint(with: tasks.tasks.map(\.id)),
                  Set(try FileManager.default.contentsOfDirectory(atPath: package.path)) == ["manifest.json", "tasks.json", "notes"],
                  Set(try FileManager.default.contentsOfDirectory(atPath: notesURL.path)) == Set(manifest.notes.map { "\($0.id.uuidString).md" })
            else { throw ExportError.invalidPackage }
            for note in manifest.notes {
                guard note.path == "notes/\(note.id.uuidString).md", note.revision >= 1 else { throw ExportError.invalidPackage }
                let url = package.appendingPathComponent(note.path)
                try requireExportFile(url, type: S_IFREG)
                let bytes = try Data(contentsOf: url)
                guard bytes.count == note.byteCount, exportHash(bytes) == note.sha256,
                      let body = String(data: bytes, encoding: .utf8), Note.isNonblank(body)
                else { throw ExportError.invalidPackage }
                let title = body.split(whereSeparator: \.isNewline).lazy.map { $0.trimmingCharacters(in: .whitespaces) }
                    .first { !$0.isEmpty }
                guard title == note.title else { throw ExportError.invalidPackage }
            }
            for task in tasks.tasks {
                try TaskItem.validate(title: task.title)
                let active = task.completedAt == nil && task.archivedAt == nil
                guard task.revision >= 1, active == (task.placement != nil), active == (task.orderKey != nil),
                      task.placement == nil || TaskPlacement(rawValue: task.placement!) != nil
                else { throw ExportError.invalidPackage }
            }
            return ExportResult(url: package, collectionID: manifest.collectionID,
                                noteCount: manifest.noteCount, taskCount: manifest.taskCount)
        } catch let error as ExportError {
            throw error
        } catch {
            throw ExportError.invalidPackage
        }
    }

    private static func requireExportFile(_ url: URL, type: mode_t) throws {
        var info = stat()
        guard lstat(url.path, &info) == 0, info.st_mode & S_IFMT == type else { throw ExportError.invalidPackage }
    }

    private static func exportHash(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

private struct ExportManifest: Codable {
    let formatVersion: Int
    let collectionID: UUID
    /// UTC Unix milliseconds bounding the Store read, not a database commit time.
    let captureStartedAt: Int64
    let captureFinishedAt: Int64
    let packagedAt: Int64
    let captureMethod: String
    let noteCount: Int
    let taskCount: Int
    let tasksSHA256: String
    let notes: [ExportNote]
}

private struct ExportNote: Codable {
    let id: UUID
    let path: String
    let title: String?
    let sha256: String
    let byteCount: Int
    let createdAt: Int64
    let contentEditedAt: Int64
    let updatedAt: Int64
    let revision: Int64
    let pinned: Bool
    let archivedAt: Int64?
}

private struct ExportTasks: Codable {
    let formatVersion: Int
    let collectionID: UUID
    let tasks: [ExportTask]
}

private struct ExportTask: Codable {
    let id: UUID
    let title: String
    let createdAt: Int64
    let contentEditedAt: Int64
    let updatedAt: Int64
    let revision: Int64
    let completedAt: Int64?
    let archivedAt: Int64?
    let placement: String?
    let orderKey: Int64?
}
