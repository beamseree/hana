import Foundation
import Testing
@testable import Hana

struct WorkingWindowsValidationTests {
    @Test func fixtureArgumentsNeverFallThroughToLiveLaunch() throws {
        #expect(try WorkingWindowsOptions.parse(["--diagnostics"]) == nil)
        let valid = ["--validate-working-windows", "--working-windows-interactive", "--working-windows-fixture-root", "/tmp/fixture", "--working-windows-report", "/tmp/report.jsonl"]
        #expect(try WorkingWindowsOptions.parse(valid)?.mode == .interactive)
        for invalid in [Array(valid.dropFirst()), Array(valid.dropLast()), ["--validate-working-windows"], ["--validate-working-windows=true"], ["--working-windows"], valid + ["--working-windows-smoke-write"], valid + ["--working-windows-report", "/tmp/other"], valid + ["--working-windows-unknown"], valid + ["--validate-main-window"], valid.map { $0 == "/tmp/fixture" ? "relative" : $0 }] {
            #expect(throws: (any Error).self) { try WorkingWindowsOptions.parse(invalid) }
        }
    }
    @Test func persistentFixtureKeepsIDsEditsAndOrganizationWithoutReseeding() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hana-working-fixture-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let (store, first) = try await WorkingWindowsFixture.open(root: root)
        let noteID = try #require(first.notes["quit"])
        let note = try #require(try await store.read(.note(noteID), in: store.generation))
        _ = try await store.perform(.editNote(noteID, expectedRevision: note.revision, body: "Changed ไทย🌸"), in: store.generation)
        let records = try await store.read(.allRecords, in: store.generation)
        #expect(records.notes.count == 6 && records.tasks.count == 10)
        #expect(try await store.read(.inbox, in: store.generation).count == 3)
        #expect(try await store.read(.today, in: store.generation).count == 3)
        #expect(try await store.read(.completedTasks, in: store.generation).count == 2)
        #expect(try await store.read(.archivedTasks, in: store.generation).count == 2)
        await store.close()
        let (reopened, second) = try await WorkingWindowsFixture.open(root: root)
        #expect(first == second)
        #expect(try await reopened.read(.allRecords, in: reopened.generation) == records)
        #expect(try await reopened.read(.note(noteID), in: reopened.generation)?.body == "Changed ไทย🌸")
        await reopened.close()
        let sidecar = root.appendingPathComponent(WorkingWindowsFixture.sidecarName)
        var corrupt = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: sidecar)) as? [String: Any])
        var aliases = try #require(corrupt["notes"] as? [String: String])
        aliases["scratch"] = aliases["quit"]
        corrupt["notes"] = aliases
        try JSONSerialization.data(withJSONObject: corrupt).write(to: sidecar)
        await #expect(throws: (any Error).self) {
            let (unexpected, _) = try await WorkingWindowsFixture.open(root: root)
            await unexpected.close()
        }
        try FileManager.default.removeItem(at: sidecar)
        await #expect(throws: (any Error).self) { try await WorkingWindowsFixture.open(root: root) }
    }
    @Test func fixtureRefusesUnmarkedAndAliasedRoots() async throws {
        let parent = FileManager.default.temporaryDirectory.appendingPathComponent("hana-working-refusal-\(UUID())")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: parent) }
        await #expect(throws: (any Error).self) { try await WorkingWindowsFixture.open(root: parent) }
        let target = parent.appendingPathComponent("target")
        _ = try CollectionLocation.createFixtureRoot(at: target)
        let alias = parent.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        await #expect(throws: (any Error).self) { try await WorkingWindowsFixture.open(root: alias) }
    }
}
