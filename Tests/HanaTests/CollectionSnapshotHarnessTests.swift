import Foundation
import Testing
@testable import Hana

@Suite(.timeLimit(.minutes(1)))
struct CollectionSnapshotHarnessTests {
    @Test func createListInspectAndDisposableReopenAcrossFreshProcesses() throws {
        let root = try HarnessRoot()
        let note = try Harness.run(["create-note", root.path, "--operation", UUID().uuidString], stdin: "# Exact บันทึก\r\n").event("note.created")
        let task = try Harness.run(["create-task", root.path, "--operation", UUID().uuidString, "--placement", "today"], stdin: "Task").event("task.created")
        let noteID = try #require(note["id"] as? String)
        let taskID = try #require(task["id"] as? String)
        _ = try Harness.run(["pin-note", root.path, "--id", noteID, "--revision", "1", "--pinned", "true"])
        _ = try Harness.run(["complete-task", root.path, "--id", taskID, "--revision", "1"])
        _ = try Harness.run(["archive-task", root.path, "--id", taskID, "--revision", "2"])
        let expected = try Harness.run(["read", root.path, "--query", "all"])
        let created = try Harness.run(["snapshot-create", root.path])
        #expect(created.status == 0)
        let id = try #require(created.event("snapshot.created")["snapshotID"] as? String)
        #expect(created.lines.filter { $0["event"] as? String == "snapshot.status" }.last?["phase"] as? String == "complete")
        let list = try Harness.run(["snapshot-list", root.path]).event("snapshots")
        #expect(list["usableCount"] as? Int == 1)
        #expect(try Harness.run(["snapshot-inspect", root.path, "--id", id]).event("snapshot.inspected")["usable"] as? Bool == true)
        let reopened = try Harness.run(["snapshot-reopen", root.path, "--id", id, "--destination", root.directory.appendingPathComponent("verification").path])
        #expect(reopened.status == 0)
        for event in ["notes", "tasks"] {
            #expect(NSDictionary(dictionary: reopened.event(event)) == NSDictionary(dictionary: expected.event(event)))
        }
        _ = reopened.event("snapshot.reopened")
    }

    @Test func snapshotHarnessRefusesLivePathsAliasesAndOverwritingADisposableStore() throws {
        let root = try HarnessRoot()
        let live = CollectionLocation.defaultLiveRoot.path
        for command in ["snapshot-create", "snapshot-list", "snapshot-inspect", "snapshot-reopen"] {
            #expect(try Harness.run([command, live, "--id", UUID().uuidString]).status == 1)
        }
        _ = try Harness.run(["create-note", root.path, "--operation", UUID().uuidString], stdin: "Keep")
        let id = try #require(try Harness.run(["snapshot-create", root.path]).event("snapshot.created")["snapshotID"] as? String)
        #expect(try Harness.run(["snapshot-reopen", root.path, "--id", id, "--destination", root.path]).status == 1)
        #expect(try Harness.run(["snapshot-reopen", root.path, "--id", id, "--destination", live]).status == 1)
        #expect(try Harness.run(["snapshot-inspect", root.path, "--id", "../../Collection"]).status == 1)
        let before = try Harness.run(["read", root.path]).event("notes")
        #expect(before["count"] as? Int == 1)
    }
}
