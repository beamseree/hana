import CryptoKit
import Foundation
import Testing
@testable import Hana

/// Runs the production Collection Store in separate `Hana --collection-fixture`
/// processes. Restart means a fresh process; kills are SIGKILL. This is
/// process-crash evidence, not power-loss evidence.
@Suite(.timeLimit(.minutes(1)))
struct CollectionFixtureHarnessTests {
    @Test func createReadObserveAndRetryAcrossFreshProcesses() throws {
        let root = try HarnessRoot()
        let body = "บันทึก Thai\r\n- [ ] Markdown kept  \n"
        let operation = UUID()
        let created = try Harness.run(["create-note", root.path, "--operation", operation.uuidString], stdin: body).event("note.created")
        #expect(created["bodySHA256"] as? String == sha256(body))
        #expect(created["bodyBytes"] as? Int == body.utf8.count)
        #expect(created["revision"] as? Int == 1)
        #expect(created["observedBefore"] as? Int == 0)
        #expect(created["observedAfter"] as? Int == 1)

        let notes = try #require(try Harness.run(["read", root.path]).event("notes")["notes"] as? [[String: Any]])
        #expect(notes.count == 1)
        #expect(notes.first?["id"] as? String == created["id"] as? String)
        #expect(notes.first?["bodySHA256"] as? String == sha256(body))

        let retried = try Harness.run(["create-note", root.path, "--operation", operation.uuidString], stdin: body).event("note.created")
        #expect(retried["id"] as? String == created["id"] as? String)
        #expect(retried["observedBefore"] as? Int == 1)
        let mismatch = try Harness.run(["create-note", root.path, "--operation", operation.uuidString], stdin: "Other")
        #expect(mismatch.status == 1)
        #expect(mismatch.event("error")["error"] as? String == "operationReused")
        #expect(try Harness.run(["read", root.path]).event("notes")["count"] as? Int == 1)
    }

    @Test func harnessRefusesTheLiveRootWithoutCreatingIt() throws {
        let live = CollectionLocation.defaultLiveRoot
        let existed = FileManager.default.fileExists(atPath: live.path)
        for arguments in [["create-root", live.appendingPathComponent("fixture").path], ["read", live.path],
                          ["create-note", live.path, "--operation", UUID().uuidString],
                          ["read", live.path, "--query", "all"],
                          ["edit-note", live.path, "--id", UUID().uuidString, "--revision", "1"],
                          ["archive-note", live.path, "--id", UUID().uuidString, "--revision", "1"],
                          ["create-task", live.path, "--operation", UUID().uuidString],
                          ["complete-task", live.path, "--id", UUID().uuidString, "--revision", "1"],
                          ["read", live.path, "--query", "today"]] {
            let refused = try Harness.run(arguments, stdin: "Never")
            #expect(refused.status == 1)
            #expect(refused.event("error")["error"] as? String == "liveRootRefused")
        }
        #expect(FileManager.default.fileExists(atPath: live.path) == existed)
    }

    @Test(arguments: ["before-commit", "after-commit"])
    func killedCreationIsAllOrNoneAndRetriesIdempotently(_ point: String) throws {
        let root = try HarnessRoot()
        let operation = UUID()
        let body = "Killed at \(point)"
        let paused = try Harness.start(["create-note", root.path, "--operation", operation.uuidString, "--pause", point], stdin: body)
        try paused.waitForPause()
        paused.kill()

        let afterKill = try Harness.run(["read", root.path]).event("notes")
        #expect(afterKill["count"] as? Int == (point == "after-commit" ? 1 : 0))
        let survivor = (afterKill["notes"] as? [[String: Any]])?.first?["id"] as? String

        let retried = try Harness.run(["create-note", root.path, "--operation", operation.uuidString], stdin: body).event("note.created")
        if let survivor { #expect(retried["id"] as? String == survivor) }
        let final = try Harness.run(["read", root.path]).event("notes")
        #expect(final["count"] as? Int == 1)
        #expect((final["notes"] as? [[String: Any]])?.first?["bodySHA256"] as? String == sha256(body))
    }

    @Test func processDeathReleasesOwnership() async throws {
        let root = try HarnessRoot()
        let holder = try Harness.start(["create-note", root.path, "--operation", UUID().uuidString, "--pause", "before-commit"], stdin: "Held")
        try holder.waitForPause()
        let location = try CollectionLocation.fixture(URL(fileURLWithPath: root.path))
        await #expect(throws: CollectionStoreError.alreadyOwned) { _ = try await CollectionStore.open(location) }
        let refused = try Harness.run(["read", root.path])
        #expect(refused.event("error")["error"] as? String == "alreadyOwned")
        holder.kill()
        let store = try await CollectionStore.open(location)
        #expect(try await store.read(.notes, in: store.generation).isEmpty)
        await store.close()
    }

    @Test func unsavedSentinelNeverReachesStorageOrDiagnostics() async throws {
        let root = try HarnessRoot()
        let sentinel = "HANA-UNSAVED-SENTINEL-\(UUID().uuidString)"
        var captured = Data()

        // Failed save in a fresh process, then a process killed mid-transaction.
        let failed = try Harness.run(["create-note", root.path, "--operation", UUID().uuidString, "--fail", "before-commit"],
                                     stdin: "Draft \(sentinel)")
        #expect(failed.status == 1)
        captured += failed.output
        let killed = try Harness.start(["create-note", root.path, "--operation", UUID().uuidString, "--pause", "before-commit"],
                                       stdin: "Draft \(sentinel)")
        try killed.waitForPause()
        killed.kill()
        captured += killed.output

        // In-process: a failed write, a stale-generation submission and a
        // buffer that is never submitted, while other work commits.
        let location = try CollectionLocation.fixture(URL(fileURLWithPath: root.path))
        let failing = try await CollectionStore.open(location, faults: .init(beforeCommit: { _ in throw InjectedFailure() }))
        let staleGeneration = failing.generation
        do {
            _ = try await failing.perform(.createNote(operation: UUID(), body: sentinel), in: failing.generation)
        } catch {
            #expect(!String(describing: error).contains(sentinel))
        }
        await failing.close()
        let store = try await CollectionStore.open(location)
        let unsubmitted = "Unsaved \(sentinel)"
        await #expect(throws: CollectionStoreError.staleGeneration) {
            _ = try await store.perform(.createNote(operation: UUID(), body: unsubmitted), in: staleGeneration)
        }
        let committed = "Committed \(UUID().uuidString)"
        _ = try await store.perform(.createNote(operation: UUID(), body: committed), in: store.generation)
        // While the WAL is live. The committed text is a positive control for the scan.
        #expect(try root.files(containing: sentinel) == [])
        #expect(try root.files(containing: committed) == ["Collection/collection.sqlite-wal"])
        await store.close()

        let restarted = try Harness.run(["read", root.path])
        captured += restarted.output
        #expect(restarted.event("notes")["count"] as? Int == 1)
        #expect(try root.files(containing: sentinel) == [])
        #expect(try root.files(containing: committed) == ["Collection/collection.sqlite"])
        #expect(captured.range(of: Data(sentinel.utf8)) == nil)
        #expect(!captured.isEmpty)
    }
}

extension CollectionFixtureHarnessTests {
    @Test func editPinArchiveAndRestorePersistAcrossFreshProcesses() throws {
        let root = try HarnessRoot()
        let created = try Harness.run(["create-note", root.path, "--operation", UUID().uuidString], stdin: "Draft").event("note.created")
        let id = try #require(created["id"] as? String)
        let body = "# แก้ไข Edited\r\n- [ ] kept  \n"

        let edited = try Harness.run(["edit-note", root.path, "--id", id, "--revision", "1"], stdin: body).event("note.changed")
        #expect(edited["revision"] as? Int == 2)
        #expect(edited["bodySHA256"] as? String == sha256(body))
        #expect(edited["titleSHA256"] as? String == sha256("# แก้ไข Edited"))
        #expect(edited["createdAt"] as? Int == created["createdAt"] as? Int)
        #expect(edited["observedBeforeRevision"] as? Int == 1)
        #expect(edited["observedAfterRevision"] as? Int == 2)
        let pinned = try Harness.run(["pin-note", root.path, "--id", id, "--revision", "2", "--pinned", "true"]).event("note.changed")
        #expect(pinned["pinned"] as? Bool == true && pinned["revision"] as? Int == 3)
        #expect(pinned["contentEditedAt"] as? Int == edited["contentEditedAt"] as? Int)
        let archived = try Harness.run(["archive-note", root.path, "--id", id, "--revision", "3"]).event("note.changed")
        #expect(archived["archived"] as? Bool == true && archived["pinned"] as? Bool == true)
        #expect(archived["observedAfterRevision"] as? Int == 4)

        #expect(try Harness.run(["read", root.path]).event("notes")["count"] as? Int == 0)
        let archive = try Harness.run(["read", root.path, "--query", "archive"]).event("notes")
        #expect((archive["notes"] as? [[String: Any]])?.map { $0["id"] as? String } == [id])
        #expect(try Harness.run(["read", root.path, "--query", "search"]).event("search")["count"] as? Int == 0)
        let eligible = try Harness.run(["read", root.path, "--query", "search-archived"]).event("search")
        let entry = (eligible["entries"] as? [[String: Any]])?.first
        #expect(entry?["archived"] as? Bool == true && entry?["textSHA256"] as? String == sha256(body))

        // Stale and archived edits fail in a fresh process without change.
        let stale = try Harness.run(["edit-note", root.path, "--id", id, "--revision", "1"], stdin: "Stale")
        #expect(stale.status == 1 && stale.event("error")["error"] as? String == "staleRevision")
        let refused = try Harness.run(["edit-note", root.path, "--id", id, "--revision", "4"], stdin: "Hidden")
        #expect(refused.event("error")["error"] as? String == "archivedNote")

        let restored = try Harness.run(["restore-note", root.path, "--id", id, "--revision", "4"]).event("note.changed")
        #expect(restored["archived"] as? Bool == false && restored["pinned"] as? Bool == true && restored["revision"] as? Int == 5)
        let all = try Harness.run(["read", root.path, "--query", "all"]).event("notes")
        let final = try #require((all["notes"] as? [[String: Any]])?.first)
        #expect(all["count"] as? Int == 1)
        #expect(final["bodySHA256"] as? String == sha256(body) && final["revision"] as? Int == 5)
        #expect(final["contentEditedAt"] as? Int == edited["contentEditedAt"] as? Int)
    }

    @Test func aFailedEditLeavesNoTraceInStorageOrOutput() throws {
        let root = try HarnessRoot()
        let created = try Harness.run(["create-note", root.path, "--operation", UUID().uuidString], stdin: "Original").event("note.created")
        let id = try #require(created["id"] as? String)
        let sentinel = "HANA-UNSAVED-SENTINEL-\(UUID().uuidString)"
        let failed = try Harness.run(["edit-note", root.path, "--id", id, "--revision", "1", "--fail", "before-commit"], stdin: sentinel)
        #expect(failed.event("error")["error"] as? String == "injectedFailure")
        #expect(failed.output.range(of: Data(sentinel.utf8)) == nil)
        #expect(try root.files(containing: sentinel) == [])
        let notes = try #require(try Harness.run(["read", root.path]).event("notes")["notes"] as? [[String: Any]])
        #expect(notes.first?["revision"] as? Int == 1 && notes.first?["bodySHA256"] as? String == sha256("Original"))
    }

    @Test(arguments: ["edit-note", "pin-note", "archive-note"], ["before-commit", "after-commit"])
    func killedNoteChangeIsAllOrNone(_ action: String, _ point: String) throws {
        let root = try HarnessRoot()
        let created = try Harness.run(["create-note", root.path, "--operation", UUID().uuidString], stdin: "Original").event("note.created")
        let id = try #require(created["id"] as? String)
        let extra = action == "pin-note" ? ["--pinned", "true"] : []
        let paused = try Harness.start([action, root.path, "--id", id, "--revision", "1", "--pause", point] + extra, stdin: "Replaced")
        try paused.waitForPause()
        paused.kill()

        let committed = point == "after-commit"
        let all = try #require(try Harness.run(["read", root.path, "--query", "all"]).event("notes")["notes"] as? [[String: Any]])
        let note = try #require(all.first)
        #expect(all.count == 1)
        #expect(note["revision"] as? Int == (committed ? 2 : 1))
        #expect(note["bodySHA256"] as? String == sha256(committed && action == "edit-note" ? "Replaced" : "Original"))
        #expect(note["pinned"] as? Bool == (committed && action == "pin-note"))
        #expect(note["archived"] as? Bool == (committed && action == "archive-note"))
    }
}

extension CollectionFixtureHarnessTests {
    @Test func taskLifecyclePersistsAcrossFreshProcessesAndTimeZones() throws {
        let root = try HarnessRoot()
        let title = " ซื้อนม Thai é 🌸 "
        let operation = UUID()
        // Each step runs in a fresh process, some in another time zone.
        let created = try Harness.run(["create-task", root.path, "--operation", operation.uuidString, "--placement", "today"],
                                      stdin: title, environment: ["TZ": "Asia/Bangkok"]).event("task.created")
        let id = try #require(created["id"] as? String)
        #expect(created["titleSHA256"] as? String == sha256(title) && created["titleBytes"] as? Int == title.utf8.count)
        #expect(created["placement"] as? String == "today" && created["revision"] as? Int == 1)
        #expect(created["observedBefore"] as? Int == 0 && created["observedAfter"] as? Int == 1)
        let retried = try Harness.run(["create-task", root.path, "--operation", operation.uuidString, "--placement", "today"],
                                      stdin: title).event("task.created")
        #expect(retried["id"] as? String == id && retried["observedBefore"] as? Int == 1)
        let other = try Harness.run(["create-task", root.path, "--operation", UUID().uuidString], stdin: "Inbox").event("task.created")
        #expect(other["placement"] as? String == "inbox")

        for zone in ["America/New_York", "Europe/Berlin", "Pacific/Kiritimati", "UTC"] {
            let today = try Harness.run(["read", root.path, "--query", "today"], environment: ["TZ": zone]).event("tasks")
            #expect((today["tasks"] as? [[String: Any]])?.map { $0["id"] as? String } == [id], "\(zone)")
        }
        let multiline = try Harness.run(["create-task", root.path, "--operation", UUID().uuidString], stdin: "Two\nlines")
        #expect(multiline.status == 1 && multiline.event("error")["error"] as? String == "multilineTaskTitle")
        #expect(multiline.output.range(of: Data("Two".utf8)) == nil)

        let edited = try Harness.run(["edit-task", root.path, "--id", id, "--revision", "1"], stdin: "Renamed").event("task.changed")
        #expect(edited["revision"] as? Int == 2 && edited["titleSHA256"] as? String == sha256("Renamed"))
        #expect(edited["observedBeforeRevision"] as? Int == 1 && edited["observedAfterRevision"] as? Int == 2)
        let moved = try Harness.run(["move-task", root.path, "--id", id, "--revision", "2", "--to", "inbox"]).event("task.changed")
        #expect(moved["placement"] as? String == "inbox")
        let inbox = try Harness.run(["read", root.path, "--query", "inbox"]).event("tasks")
        #expect((inbox["tasks"] as? [[String: Any]])?.map { $0["id"] as? String } == [id, other["id"] as? String])
        let completed = try Harness.run(["complete-task", root.path, "--id", id, "--revision", "3"]).event("task.changed")
        #expect(completed["completedAt"] is Int && completed["placement"] is NSNull && completed["orderKey"] is NSNull)
        let archived = try Harness.run(["archive-task", root.path, "--id", id, "--revision", "4"]).event("task.changed")
        #expect(archived["archivedAt"] is Int && archived["completedAt"] as? Int == completed["completedAt"] as? Int)
        let refused = try Harness.run(["reopen-task", root.path, "--id", id, "--revision", "5"])
        #expect(refused.status == 1 && refused.event("error")["error"] as? String == "archivedTask")
        #expect(try Harness.run(["read", root.path, "--query", "archived-tasks"]).event("tasks")["count"] as? Int == 1)
        #expect(try Harness.run(["read", root.path, "--query", "task-search"]).event("task-search")["count"] as? Int == 1)
        #expect(try Harness.run(["read", root.path, "--query", "task-search-all"]).event("task-search")["count"] as? Int == 2)

        let restored = try Harness.run(["restore-task", root.path, "--id", id, "--revision", "5"]).event("task.changed")
        #expect(restored["archivedAt"] is NSNull && restored["completedAt"] as? Int == completed["completedAt"] as? Int)
        #expect(try Harness.run(["read", root.path, "--query", "completed"]).event("tasks")["count"] as? Int == 1)
        let reopened = try Harness.run(["reopen-task", root.path, "--id", id, "--revision", "6"]).event("task.changed")
        #expect(reopened["placement"] as? String == "inbox" && reopened["completedAt"] is NSNull)
        let all = try Harness.run(["read", root.path, "--query", "all"])
        #expect(all.event("notes")["count"] as? Int == 0)
        let tasks = try #require(all.event("tasks")["tasks"] as? [[String: Any]])
        let final = try #require(tasks.first { $0["id"] as? String == id })
        #expect(tasks.count == 2 && final["revision"] as? Int == 7 && final["createdAt"] as? Int == created["createdAt"] as? Int)
        #expect(final["contentEditedAt"] as? Int == edited["contentEditedAt"] as? Int)
    }

    @Test func failedTaskSavesLeaveNoTraceInStorageOrOutput() throws {
        let root = try HarnessRoot()
        let created = try Harness.run(["create-task", root.path, "--operation", UUID().uuidString], stdin: "Original").event("task.created")
        let id = try #require(created["id"] as? String)
        let sentinel = "HANA-UNSAVED-SENTINEL-\(UUID().uuidString)"
        var captured = Data()
        for arguments in [["create-task", root.path, "--operation", UUID().uuidString, "--fail", "before-commit"],
                          ["edit-task", root.path, "--id", id, "--revision", "1", "--fail", "before-commit"]] {
            let failed = try Harness.run(arguments, stdin: sentinel)
            #expect(failed.event("error")["error"] as? String == "injectedFailure")
            captured += failed.output
        }
        let killed = try Harness.start(["create-task", root.path, "--operation", UUID().uuidString, "--pause", "before-commit"],
                                       stdin: sentinel)
        try killed.waitForPause()
        killed.kill()
        captured += killed.output
        let refused = try Harness.run(["create-task", root.path, "--operation", UUID().uuidString], stdin: "\(sentinel)\nsecond line")
        #expect(refused.event("error")["error"] as? String == "multilineTaskTitle")
        captured += refused.output

        let read = try Harness.run(["read", root.path, "--query", "all"])
        captured += read.output
        let tasks = try #require(read.event("tasks")["tasks"] as? [[String: Any]])
        #expect(tasks.count == 1 && tasks.first?["titleSHA256"] as? String == sha256("Original"))
        #expect(try root.files(containing: sentinel) == [])
        #expect(try root.files(containing: "Original") == ["Collection/collection.sqlite"])
        #expect(captured.range(of: Data(sentinel.utf8)) == nil && !captured.isEmpty)
    }

    @Test(arguments: ["create-task", "edit-task", "move-task", "complete-task", "archive-task"], ["before-commit", "after-commit"])
    func killedTaskCommandIsAllOrNone(_ action: String, _ point: String) throws {
        let root = try HarnessRoot()
        let created = try Harness.run(["create-task", root.path, "--operation", UUID().uuidString], stdin: "Original").event("task.created")
        let id = try #require(created["id"] as? String)
        let operation = UUID().uuidString
        let arguments = action == "create-task"
            ? [action, root.path, "--operation", operation, "--placement", "today"]
            : [action, root.path, "--id", id, "--revision", "1"] + (action == "move-task" ? ["--to", "today"] : [])
        let paused = try Harness.start(arguments + ["--pause", point], stdin: "Replaced")
        try paused.waitForPause()
        paused.kill()

        let committed = point == "after-commit"
        let tasks = try #require(try Harness.run(["read", root.path, "--query", "all"]).event("tasks")["tasks"] as? [[String: Any]])
        let original = try #require(tasks.first { $0["id"] as? String == id })
        if action == "create-task" {
            #expect(tasks.count == (committed ? 2 : 1))
            // The retry returns the survivor or creates the task exactly once.
            let survivor = tasks.first { $0["id"] as? String != id }?["id"] as? String
            let retried = try Harness.run(["create-task", root.path, "--operation", operation, "--placement", "today"],
                                          stdin: "Replaced").event("task.created")
            if let survivor { #expect(retried["id"] as? String == survivor) }
            #expect(try Harness.run(["read", root.path, "--query", "today"]).event("tasks")["count"] as? Int == 1)
        } else {
            #expect(tasks.count == 1)
            #expect(original["revision"] as? Int == (committed ? 2 : 1))
            #expect(original["titleSHA256"] as? String == sha256(committed && action == "edit-task" ? "Replaced" : "Original"))
            #expect(original["placement"] as? String? == (committed && action != "edit-task"
                ? (action == "move-task" ? "today" : nil) : "inbox"))
            #expect((original["completedAt"] is Int) == (committed && action == "complete-task"))
            #expect((original["archivedAt"] is Int) == (committed && action == "archive-task"))
        }
    }
}

private func sha256(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
}

struct HarnessRoot {
    let directory: URL
    var path: String { directory.appendingPathComponent("root").path }

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("hana-harness-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        let created = try Harness.run(["create-root", path])
        #expect(created.status == 0)
        _ = created.event("fixture.root-created")
    }

    /// Relative paths of every file below the root, including the database
    /// and its sidecars, whose bytes contain `text`.
    func files(containing text: String) throws -> [String] {
        let enumerator = try #require(FileManager.default.enumerator(atPath: path))
        return try enumerator.compactMap { $0 as? String }.filter { relative in
            let url = URL(fileURLWithPath: path).appendingPathComponent(relative)
            guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { return false }
            return try Data(contentsOf: url).range(of: Data(text.utf8)) != nil
        }
    }
}

enum Harness {
    struct Result {
        let status: Int32
        let output: Data
        var lines: [[String: Any]] {
            String(decoding: output, as: UTF8.self).split(separator: "\n").compactMap {
                try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]
            }
        }
        func event(_ name: String) -> [String: Any] {
            let match = lines.last { $0["event"] as? String == name }
            #expect(match != nil, "no \(name) event in \(String(decoding: output, as: UTF8.self))")
            return match ?? [:]
        }
    }

    final class Running {
        let process: Process
        private let pipe: Pipe
        private(set) var output = Data()

        init(process: Process, pipe: Pipe) {
            self.process = process
            self.pipe = pipe
        }

        func waitForPause() throws {
            while !String(decoding: output, as: UTF8.self).contains("\"event\":\"paused\"") {
                let chunk = pipe.fileHandleForReading.availableData
                guard !chunk.isEmpty else { throw HarnessExited(output: String(decoding: output, as: UTF8.self)) }
                output += chunk
            }
        }

        func kill() {
            Darwin.kill(process.processIdentifier, SIGKILL)
            process.waitUntilExit()
            output += pipe.fileHandleForReading.readDataToEndOfFile()
        }
    }

    struct HarnessExited: Error { let output: String }

    static var executable: URL {
        if let override = ProcessInfo.processInfo.environment["HANA_EXECUTABLE"] { return URL(fileURLWithPath: override) }
        // The Hana product is built next to the test bundle.
        return Bundle(for: Running.self).bundleURL.deletingLastPathComponent().appendingPathComponent("Hana")
    }

    static func start(_ arguments: [String], stdin: String = "", environment: [String: String] = [:]) throws -> Running {
        let process = Process()
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { $1 }
        process.executableURL = executable
        process.arguments = ["--collection-fixture"] + arguments
        let output = Pipe(), input = Pipe()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = input
        try process.run()
        input.fileHandleForWriting.write(Data(stdin.utf8))
        try input.fileHandleForWriting.close()
        return Running(process: process, pipe: output)
    }

    static func run(_ arguments: [String], stdin: String = "", environment: [String: String] = [:]) throws -> Result {
        let running = try start(arguments, stdin: stdin, environment: environment)
        let output = running.process.standardOutput as! Pipe
        let data = output.fileHandleForReading.readDataToEndOfFile()
        running.process.waitUntilExit()
        return Result(status: running.process.terminationStatus, output: data)
    }
}
