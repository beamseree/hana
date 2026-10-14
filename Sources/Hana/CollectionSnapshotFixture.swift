import Foundation

/// Snapshot-only harness caller. Catalogs stay in the marked fixture root;
/// reopening creates a new disposable root and never replaces a collection.
enum CollectionSnapshotFixture {
    private struct Usage: Error {}

    static func run(_ action: String, root: URL, options: [String: String]) async throws {
        let location = try CollectionLocation.fixture(root)
        let catalog = root.appendingPathComponent("Snapshots")
        switch action {
        case "snapshot-create":
            let fail = options["--fail"].flatMap(CollectionRecovery.SnapshotPhase.init(rawValue:))
            guard options["--fail"] == nil || (fail != nil && fail != .complete && fail != .failed) else { throw Usage() }
            let store = try await CollectionStore.open(location)
            do {
                let snapshot = try await CollectionRecovery.createSnapshot(from: store, in: store.generation, destination: catalog,
                    faults: .init(atPhase: { phase in
                        if phase == fail { throw CollectionRecovery.SnapshotError.fileFailure(code: ENOSPC) }
                    }), onStatus: { phase in CollectionFixtureHarness.emit("snapshot.status", ["phase": phase.rawValue]) })
                await store.close()
                CollectionFixtureHarness.emit("snapshot.created", try fields(snapshot.manifest))
            } catch {
                await store.close()
                throw error
            }
        case "snapshot-list":
            let inspections = try await CollectionRecovery.listSnapshots(in: catalog)
            CollectionFixtureHarness.emit("snapshots", ["usableCount": inspections.filter(\.isUsable).count,
                "candidates": try inspections.map { try fields($0) }])
        case "snapshot-inspect", "snapshot-reopen":
            guard let id = options["--id"].flatMap(UUID.init(uuidString:)) else { throw Usage() }
            let package = catalog.appendingPathComponent("snapshot-\(id.uuidString)")
            if action == "snapshot-inspect" {
                CollectionFixtureHarness.emit("snapshot.inspected", try fields(await CollectionRecovery.inspectSnapshot(at: package)))
            } else {
                guard let path = options["--destination"] else { throw Usage() }
                let reopened = try await CollectionRecovery.reopenSnapshot(at: package, disposableRoot: URL(fileURLWithPath: path))
                do {
                    try await CollectionFixtureHarness.read("all", from: reopened)
                    await reopened.close()
                    CollectionFixtureHarness.emit("snapshot.reopened", ["snapshotID": id.uuidString])
                } catch {
                    await reopened.close()
                    throw error
                }
            }
        default: throw Usage()
        }
    }

    private static func fields(_ manifest: CollectionRecovery.SnapshotManifest) throws -> [String: Any] {
        try JSONSerialization.jsonObject(with: JSONEncoder().encode(manifest)) as? [String: Any] ?? [:]
    }

    private static func fields(_ inspection: CollectionRecovery.SnapshotInspection) throws -> [String: Any] {
        var result: [String: Any] = ["candidate": inspection.url.lastPathComponent, "usable": inspection.isUsable]
        if let manifest = inspection.manifest { result["manifest"] = try fields(manifest) }
        if let failure = inspection.failure { result["failure"] = "\(failure)" }
        return result
    }
}
