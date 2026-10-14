import CryptoKit
import Foundation
import Testing
@testable import Hana

/// Validation-only composition of the two reviewed feature diffs. Copy this
/// file into the disposable combined worktree; it is not part of either PR's
/// independently buildable production test target.
@Suite(.timeLimit(.minutes(1)))
struct CombinedCollectionJourneyTests {
    @Test func organizedRestartExportSnapshotAndDisposableReopen() async throws {
        let environment = ProcessInfo.processInfo.environment
        let parent = URL(fileURLWithPath: try #require(environment["HANA_COMBINED_ROOT"]))
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        let location = try CollectionLocation.createFixtureRoot(at: parent.appendingPathComponent("source"))
        let exports = try CollectionLocation.createFixtureRoot(at: parent.appendingPathComponent("exports"))
        let clock = FixedClock(Date(timeIntervalSince1970: 1_800_000_000.250))
        let store = try await CollectionStore.open(location, clock: clock.now)
        let expected = try await OrganizedCollection.build(in: store, clock: clock).views
        let oldGeneration = store.generation
        await store.close()

        var transcript: [[String: Any]] = []
        func process(_ arguments: [String]) throws -> Harness.Result {
            let result = try Harness.run(arguments)
            #expect(result.status == 0)
            transcript.append(["arguments": arguments, "status": result.status, "events": result.lines])
            return result
        }
        // A new process opens the persisted source. No original Store remains open.
        let restarted = try process(["read", location.root.path, "--query", "all"])
        #expect(restarted.event("notes")["count"] as? Int == 7)
        #expect(restarted.event("tasks")["count"] as? Int == 14)
        _ = try process(["runtime-report", location.root.path])

        let exported = try process(["export", location.root.path, "--destination", exports.root.path]).event("collection.exported")
        let package = exports.root.appendingPathComponent(try #require(exported["package"] as? String))
        // This decoder is #28's independent test decoder, not Recovery's validator.
        let reconstructed = try IndependentExportDecoder.records(at: package)
        #expect(reconstructed == expected.records)
        #expect(IndependentExportDecoder.views(reconstructed) == expected)
        for note in expected.records.notes {
            #expect(try Data(contentsOf: package.appendingPathComponent("notes/\(note.id.uuidString).md")) == Data(note.body.utf8))
        }

        let snapshot = try process(["snapshot-create", location.root.path]).event("snapshot.created")
        let id = try #require(snapshot["snapshotID"] as? String)
        let snapshots = location.root.appendingPathComponent("Snapshots")
        let snapshotURL = snapshots.appendingPathComponent("snapshot-\(id)")
        let snapshotDatabase = snapshotURL.appendingPathComponent("collection.sqlite")
        let databaseBefore = try Data(contentsOf: snapshotDatabase)
        let manifestBefore = try Data(contentsOf: snapshotURL.appendingPathComponent("manifest.json"))
        #expect(snapshot["collectionID"] as? String == expected.records.collectionID.uuidString)
        #expect(try process(["snapshot-list", location.root.path]).event("snapshots")["usableCount"] as? Int == 1)
        #expect(try process(["snapshot-inspect", location.root.path, "--id", id]).event("snapshot.inspected")["usable"] as? Bool == true)
        // Move the source collection aside, including all its sidecars. The
        // reopened Store can only depend on the published standalone snapshot.
        try FileManager.default.moveItem(at: location.collectionDirectory, to: parent.appendingPathComponent("source-detached"))
        let disposable = parent.appendingPathComponent("verification")
        let reopenedProcess = try process(["snapshot-reopen", location.root.path, "--id", id, "--destination", disposable.path])
        for event in ["notes", "tasks"] {
            #expect(NSDictionary(dictionary: reopenedProcess.event(event)) == NSDictionary(dictionary: restarted.event(event)))
        }
        let reopened = try await CollectionStore.open(try CollectionLocation.fixture(disposable))
        #expect(reopened.generation != oldGeneration)
        let actual = try await OrganizedCollection.views(of: reopened)
        #expect(actual == expected)
        #expect(actual.records == reconstructed)
        await reopened.close()
        #expect(try Data(contentsOf: snapshotDatabase) == databaseBefore)
        #expect(try Data(contentsOf: snapshotURL.appendingPathComponent("manifest.json")) == manifestBefore)
        let summary: [String: Any] = [
            "base": "210e9f34de86d751de6eb80a584cc41cde560ee3",
            "exportCommit": "0592aab17803b2f1a0e5978af2f51aa4494a1bd8",
            "snapshotCommit": "57a756aad05549eb5207a34b00c3b75d1d5fd8d0",
            "binarySHA256": SHA256.hash(data: try Data(contentsOf: Harness.executable)).map { String(format: "%02x", $0) }.joined(),
            "fixtureRoot": parent.path, "collectionID": expected.records.collectionID.uuidString,
            "notes": 7, "tasks": 14, "snapshotID": id,
            "fullDomainAndOrganizedViewsEqual": actual == expected && IndependentExportDecoder.views(reconstructed) == expected,
            "exactNoteBytesEqual": actual.records.notes == expected.records.notes,
            "sourceDetachedBeforeSnapshotReopen": true,
            "ordinaryReopenOnly": true, "transcript": transcript
        ]
        let report = URL(fileURLWithPath: try #require(environment["HANA_COMBINED_REPORT"]))
        try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]).write(to: report)
    }
}
