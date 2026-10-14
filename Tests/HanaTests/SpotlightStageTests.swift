import Foundation
import Testing
@testable import Hana

/// Spotlight adapter checks (#50). Live-index tests are opt-in because they
/// depend on the local index. Their fixtures are synthetic files in a temporary
/// folder in the home directory, imported with `mdimport` and then removed.
@Suite(.serialized, .timeLimit(.minutes(2)))
@MainActor
struct SpotlightStageTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HANA_LIVE_INDEX"] != nil))
    func allThreeStagesStartBeforeAnyFinishesGathering() async throws {
        var started: [ObjectIdentifier] = []
        var startedBeforeFirstFinish: Int?
        let observers = [
            NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidStartGathering, object: nil, queue: .main) { note in
                let id = ObjectIdentifier(note.object as AnyObject)
                MainActor.assumeIsolated { started.append(id) }
            },
            NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { if startedBeforeFirstFinish == nil { startedBeforeFirstFinish = started.count } }
            }
        ]
        defer { observers.forEach(NotificationCenter.default.removeObserver) }
        var status: SourceStatus = .loading
        for await snapshot in SpotlightSource.snapshots(for: "Hana50 \(UUID().uuidString)") {
            status = snapshot.status
            if status != .loading { break }
        }
        #expect(status == .ready)
        #expect(Set(started).count == 3)
        #expect(startedBeforeFirstFinish == 3)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HANA_LIVE_INDEX"] != nil))
    func aNameMatchSurvivesThousandsOfExtensionOnlyMatchesInTheShortlist() async throws {
        let fixtures = try Fixtures()
        defer { fixtures.remove() }
        // Only the substring stage gathers it, alongside every indexed PDF.
        let named = try fixtures.file("Hana50 pdf guide.txt")
        try await fixtures.importIntoIndex()
        try await expectEventually(query: "Hana50 pdf guide") { $0.contains(named) }
        let results = try await settledResults(for: "pdf")
        #expect(results.contains(named))
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HANA_LIVE_INDEX"] != nil))
    func indexedHiddenDestinationsAreExcludedAfterShortlisting() async throws {
        let fixtures = try Fixtures()
        defer { fixtures.remove() }
        let visible = try fixtures.file("Hana50Vis visible.txt")
        let hidden = try fixtures.file("Hana50Vis hidden.txt", hidden: true)
        let inHiddenFolder = try fixtures.file("Concealed/Hana50Vis nested.txt")
        try fixtures.hide("Concealed")
        try await fixtures.importIntoIndex()
        // Wait until the index holds every fixture, so exclusion is not vacuous.
        try await fixtures.waitUntilIndexed(named: "Hana50Vis", count: 3)
        let results = try await settledResults(for: "Hana50Vis")
        #expect(results.contains(visible))
        for excluded in [hidden, inHiddenFolder] {
            #expect(!results.contains(excluded), "\(excluded.path)")
        }
    }

    /// On macOS 26.4.1 Spotlight did not index files inside an `.rtfd` package,
    /// so the package rule is checked against the filesystem directly.
    @Test func destinationsInsidePackagesOrHiddenFoldersAreNotVisible() throws {
        // The temporary directory is under hidden /private, so use the home folder.
        let fixtures = try Fixtures()
        defer { fixtures.remove() }
        let visible = try fixtures.file("Folder/visible.txt")
        let package = fixtures.root.appendingPathComponent("Notes.rtfd")
        let inPackage = try fixtures.file("Notes.rtfd/attachment.txt")
        let hidden = try fixtures.file("hidden.txt", hidden: true)
        let inHiddenFolder = try fixtures.file("Concealed/nested.txt")
        try fixtures.hide("Concealed")
        #expect(SpotlightSource.visibleDestination(visible))
        #expect(SpotlightSource.visibleDestination(package))
        #expect(!SpotlightSource.visibleDestination(inPackage))
        #expect(!SpotlightSource.visibleDestination(hidden))
        #expect(!SpotlightSource.visibleDestination(inHiddenFolder))
    }

    private func settledResults(for text: String) async throws -> [URL] {
        var results: [URL] = []
        var status: SourceStatus = .loading
        for await snapshot in SpotlightSource.snapshots(for: text) {
            results = snapshot.results.map(\.url.standardizedFileURL)
            status = snapshot.status
            if status != .loading { break }
        }
        try #require(status == .ready || status == .partial)
        return results
    }

    private func expectEventually(query: String, _ condition: ([URL]) -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            if condition(try await settledResults(for: query)) { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        Issue.record("Fixtures for \(query) were not indexed within 30 seconds")
    }
}

private struct Fixtures {
    let root: URL

    init() throws {
        root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Hana Issue 50 Validation \(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func file(_ path: String, hidden: Bool = false) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("Synthetic Hana #50 fixture; contains no personal data.\n".utf8).write(to: url)
        if hidden { try hide(path) }
        return url.standardizedFileURL
    }

    func hide(_ path: String) throws {
        var url = root.appendingPathComponent(path)
        var values = URLResourceValues()
        values.isHidden = true
        try url.setResourceValues(values)
    }

    func importIntoIndex() async throws {
        let root = root
        try await Task.detached {
            let importer = Process()
            importer.executableURL = URL(fileURLWithPath: "/usr/bin/mdimport")
            importer.arguments = [root.path]
            try importer.run()
            importer.waitUntilExit()
        }.value
    }

    func waitUntilIndexed(named name: String, count: Int) async throws {
        let root = root
        let deadline = ContinuousClock.now + .seconds(30)
        while ContinuousClock.now < deadline {
            let found = try await Task.detached {
                let finder = Process(), output = Pipe()
                finder.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
                finder.arguments = ["-onlyin", root.path, "-name", name]
                finder.standardOutput = output
                finder.standardError = FileHandle.nullDevice
                try finder.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                finder.waitUntilExit()
                return String(decoding: data, as: UTF8.self).split(separator: "\n").count
            }.value
            if found >= count { return }
            try await Task.sleep(for: .milliseconds(250))
        }
        Issue.record("Fixtures named \(name) were not indexed within 30 seconds")
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
}
