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
                          ["archive-note", live.path, "--id", UUID().uuidString, "--revision", "1"]] {
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

    @Test(arguments: ["before-commit", "after-commit"])
    func killedEditIsAllOrNoneAndAFailedEditLeavesNoTrace(_ point: String) throws {
        let root = try HarnessRoot()
        let created = try Harness.run(["create-note", root.path, "--operation", UUID().uuidString], stdin: "Original").event("note.created")
        let id = try #require(created["id"] as? String)
        let sentinel = "HANA-UNSAVED-SENTINEL-\(UUID().uuidString)"
        let failed = try Harness.run(["edit-note", root.path, "--id", id, "--revision", "1", "--fail", "before-commit"], stdin: sentinel)
        #expect(failed.event("error")["error"] as? String == "injectedFailure")
        #expect(failed.output.range(of: Data(sentinel.utf8)) == nil)
        #expect(try root.files(containing: sentinel) == [])

        let paused = try Harness.start(["edit-note", root.path, "--id", id, "--revision", "1", "--pause", point], stdin: "Replaced")
        try paused.waitForPause()
        paused.kill()
        let notes = try #require(try Harness.run(["read", root.path]).event("notes")["notes"] as? [[String: Any]])
        #expect(notes.count == 1)
        #expect(notes.first?["revision"] as? Int == (point == "after-commit" ? 2 : 1))
        #expect(notes.first?["bodySHA256"] as? String == sha256(point == "after-commit" ? "Replaced" : "Original"))
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

    static func start(_ arguments: [String], stdin: String = "") throws -> Running {
        let process = Process()
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

    static func run(_ arguments: [String], stdin: String = "") throws -> Result {
        let running = try start(arguments, stdin: stdin)
        let output = running.process.standardOutput as! Pipe
        let data = output.fileHandleForReading.readDataToEndOfFile()
        running.process.waitUntilExit()
        return Result(status: running.process.terminationStatus, output: data)
    }
}
