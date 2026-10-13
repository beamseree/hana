import Foundation
import Testing
@testable import Hana

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct SearchTests {
    @Test func failedCatalogStatusStillDeliversAvailableMatches() async {
        let search = Search(source: { AsyncStream { $0.yield(.init(applications: [app("Notes", "/Applications/Notes.app")], status: .failed)); $0.finish() } }, debounce: .zero)
        for await batch in search.search(.init(text: "notes")) {
            #expect(batch.status == .failed)
            #expect(batch.results.map(\.name) == ["Notes"])
        }
    }

    @Test func installationFilenameRemainsSearchableWhenBundleNameDiffers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let bundle = root.appendingPathComponent("Google Chrome.app/Contents")
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let data = try PropertyListSerialization.data(fromPropertyList: ["CFBundleName": "Chrome"], format: .xml, options: 0)
        try data.write(to: bundle.appendingPathComponent("Info.plist"))
        let search = Search(roots: [root], debounce: .zero)
        for await batch in search.search(.init(text: "Google Chrome")) where batch.status != .loading {
            #expect(batch.results.map(\.name) == ["Chrome"])
            break
        }
    }

    @Test func emptyQueriesDoNotConsultASourceAndCancellationFinishesOldStream() async throws {
        var calls = 0
        let feed = CatalogFeed()
        let search = Search(source: { calls += 1; return feed.stream() }, debounce: .zero)
        for await batch in search.search(.init(text: "  ")) { #expect(batch.results.isEmpty) }
        #expect(calls == 0)
        let stream = search.search(.init(text: "old"))
        let consume = Task { var count = 0; for await _ in stream { count += 1 }; return count }
        try await eventually { calls == 1 }
        for await batch in search.search(.init(text: "")) { #expect(batch.results.isEmpty) }
        await feed.send([app("old", "/Applications/old.app")])
        #expect(await consume.value == 0)
    }

    @Test func catalogRefreshesAnActiveQueryAfterInstallationAndRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let search = Search(roots: [root], debounce: .zero)
        var iterator = search.search(.init(text: "Added")).makeAsyncIterator()
        while let batch = await iterator.next(), batch.status == .loading {}
        let installed = root.appendingPathComponent("Added.app")
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        let added = await iterator.next()
        #expect(added?.results.map(\.name) == ["Added"])
        try FileManager.default.removeItem(at: installed)
        let removed = await iterator.next()
        #expect(removed?.results.isEmpty == true)
    }

    @Test func successfulUseOnlyReordersWithinNameTiersAndDeliveryIsBounded() async {
        let exact = app("App", "/Applications/App.app")
        let preferred = app("App Z", "/Applications/App Z.app")
        let apps = (0..<100).map { app("App \($0)", "/Applications/App \($0).app") } + [preferred, exact]
        let search = Search(source: { AsyncStream { $0.yield(.init(applications: apps, status: .ready)); $0.finish() } }, debounce: .zero)
        search.recordOpened(preferred.id)
        var last: Search.Batch?
        for await batch in search.search(.init(text: "app")) { last = batch }
        #expect(last?.results.count == 20)
        #expect(last?.results.prefix(2).map(\.name) == ["App", "App Z"])
    }

    @Test func cachedCatalogDescendsFoldersButExcludesHiddenAndBundleInternals() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["Group/Alpha.app", "Group/Alpha.app/Contents/Nested.app", ".Hidden.app", ".Secret/Leak.app", "Beta.app"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        let search = Search(roots: [root], debounce: .zero)
        for await batch in search.search(.init(text: "a")) where batch.status != .loading {
            #expect(batch.results.map(\.name) == ["Alpha", "Beta"])
            break
        }
    }

    @Test func literalUnicodeAndAllNameTokensMatchWithoutRewritingInput() async {
        let apps = [app("Notes Pro", "/Applications/Notes Pro.app"), app("บันทึก [*]", "/Applications/Thai.app"), app("Café", "/Applications/Cafe.app")]
        for (query, expected) in [("pro NOTES", "Notes Pro"), ("ทึก [*]", "บันทึก [*]"), ("CAFE\u{301}", "Café")] {
            let search = Search(source: { AsyncStream { $0.yield(.init(applications: apps, status: .ready)); $0.finish() } }, debounce: .zero)
            let request = Search.Request(text: query)
            var last: Search.Batch?
            for await batch in search.search(request) { last = batch }
            #expect(last?.results.map(\.name) == [expected])
            #expect(request.text == query)
        }
    }

    @Test func distinctInstallationsSurviveDeduplicationBeforeTheLimit() async {
        let same = app("Notes", "/Applications/Notes.app")
        let other = app("Notes", "/Users/test/Applications/Notes.app")
        let apps = Array(repeating: same, count: 30) + [other]
        let search = Search(source: { AsyncStream { $0.yield(.init(applications: apps, status: .ready)); $0.finish() } }, debounce: .zero)
        var last: Search.Batch?
        for await batch in search.search(.init(text: "Notes")) { last = batch }
        #expect(last?.results.map(\.url.path) == ["/Applications/Notes.app", "/Users/test/Applications/Notes.app"])
    }

    @Test func exactPrefixAndSubstringHaveDeterministicOrder() async {
        let apps = [app("My Notes", "/Applications/My Notes.app"),
                    app("Notes Pro", "/Applications/Notes Pro.app"),
                    app("Notes", "/Applications/Notes.app")]
        let search = Search(source: { AsyncStream { $0.yield(.init(applications: apps, status: .ready)); $0.finish() } }, debounce: .zero)
        var last: Search.Batch?
        for await batch in search.search(.init(text: "notes")) { last = batch }
        #expect(last?.results.map(\.name) == ["Notes", "Notes Pro", "My Notes"])
    }
}

func app(_ name: String, _ path: String) -> ApplicationResult {
    ApplicationResult(name: name, url: URL(fileURLWithPath: path))
}
