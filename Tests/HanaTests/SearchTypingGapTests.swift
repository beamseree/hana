import Foundation
import Testing
@testable import Hana

/// Indexed-file queries start on typing pauses (#50), timed by a test clock.
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct SearchTypingGapTests {
    @Test func aKeystrokeAfterAnIdleGapStartsTheFileQueryImmediately() async throws {
        let clock = TestClock()
        var started: [String] = []
        let search = Search(source: { AsyncStream { $0.finish() } }, files: { text in
            started.append(text)
            return AsyncStream { _ in }
        }, typingGap: .milliseconds(50), clock: clock)
        let first = Task { for await _ in search.search(.init(text: "h")) {} }
        defer { first.cancel() }
        try await eventually { started == ["h"] }
        clock.advance(by: .milliseconds(50))
        let second = Task { for await _ in search.search(.init(text: "ha")) {} }
        defer { second.cancel() }
        try await eventually { started == ["h", "ha"] }
    }

    @Test func keystrokesWithinTheGapStartOneFileQueryWithTheLatestTextOnceTypingPauses() async throws {
        let clock = TestClock()
        let files = CatalogFeed()
        var started: [String] = []
        let search = Search(source: { AsyncStream { $0.finish() } }, files: { text in
            started.append(text)
            return files.stream()
        }, typingGap: .milliseconds(50), clock: clock)
        var consumers: [Task<Void, Never>] = []
        defer { consumers.forEach { $0.cancel() } }
        func type(_ text: String) {
            let batches = search.search(.init(text: text))
            consumers.append(Task { for await _ in batches {} })
        }
        type("h")
        try await eventually { started == ["h"] }
        for text in ["ha", "han", "hana"] {
            clock.advance(by: .milliseconds(20))
            type(text)
        }
        // The newer request stops the query already running for "h".
        try await eventually { files.cancellationCount == 1 }
        clock.advance(by: .milliseconds(49))
        try await Task.sleep(for: .milliseconds(50))
        #expect(started == ["h"])
        clock.advance(by: .milliseconds(1))
        try await eventually { started == ["h", "hana"] }
        try await Task.sleep(for: .milliseconds(50))
        #expect(started == ["h", "hana"])
    }

    @Test func applicationsAndRetainedResultsArriveWhileTheFileQueryWaitsForAPause() async throws {
        let clock = TestClock()
        let alpha = app("Alpha", "/Applications/Alpha.app")
        let file = SearchResult(name: "Alpha notes.txt", url: URL(fileURLWithPath: "/fixture/Alpha notes.txt"), kind: .file)
        var started: [String] = []
        let search = Search(source: { AsyncStream {
            $0.yield(.init(results: [alpha], status: .ready)); $0.finish()
        } }, files: { text in
            started.append(text)
            return AsyncStream { $0.yield(.init(results: [file], status: .ready)); $0.finish() }
        }, typingGap: .milliseconds(50), clock: clock)
        for await _ in search.search(.init(text: "Alp")) {}
        #expect(started == ["Alp"])
        clock.advance(by: .milliseconds(10))
        var iterator = search.search(.init(text: "Alpha")).makeAsyncIterator()
        let retained = await iterator.next()
        #expect(retained?.results == [alpha, file])
        var batch = retained
        while batch?.appStatus == .loading { batch = await iterator.next() }
        #expect(batch?.results == [alpha, file])
        #expect(batch?.fileStatus == .loading)
        #expect(started == ["Alp"])
        clock.advance(by: .milliseconds(50))
        while let next = await iterator.next(), next.fileStatus == .loading {}
        #expect(started == ["Alp", "Alpha"])
    }
}
