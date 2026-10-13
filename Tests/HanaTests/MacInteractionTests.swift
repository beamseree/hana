import AppKit
import Testing
@testable import Hana

// Real AppKit presentation through the agreed module boundary. These checks do
// not claim that macOS routed a physical keystroke or restored a foreign editor.
@Suite(.serialized)
@MainActor
struct MacInteractionTests {
    @Test func reinvocationKeepsTheCurrentSession() {
        _ = NSApplication.shared
        let interaction = MacInteraction()
        let first = interaction.presentBar()
        defer { interaction.dismiss(first, reason: .outsideClick) }
        #expect(interaction.presentBar() == first)
        #expect(interaction.currentInvocation == first)
    }
    @Test func oldDismissalCannotCloseAReopenedBar() {
        _ = NSApplication.shared
        let interaction = MacInteraction()
        let old = interaction.presentBar()
        interaction.dismiss(old, reason: .outsideClick)
        #expect(interaction.currentInvocation == nil)
        let fresh = interaction.presentBar()
        defer { interaction.dismiss(fresh, reason: .outsideClick) }
        #expect(fresh != old)
        interaction.dismiss(old, reason: .escape)
        #expect(interaction.currentInvocation == fresh)
    }
    @Test func oldDestinationCannotCloseAReopenedBar() {
        _ = NSApplication.shared
        let interaction = MacInteraction()
        let old = interaction.presentBar()
        interaction.dismiss(old, reason: .escape)
        let fresh = interaction.presentBar()
        defer { interaction.dismiss(fresh, reason: .outsideClick) }
        #expect(!interaction.open(.mockNoteA, from: old))
        #expect(interaction.currentInvocation == fresh)
    }

}

@Suite(.serialized)
@MainActor
struct DestinationInteractionTests {
    @Test func delayedFileAcknowledgmentNeverActivatesOrDismissesANewerInvocation() async throws {
        _ = NSApplication.shared
        let files = CatalogFeed()
        var completion: CheckedContinuation<Void, Error>?
        var activated = false
        let interaction = MacInteraction(search: Search(source: { AsyncStream { $0.finish() } }, files: { _ in files.stream() }, debounce: .zero), openFile: { _ in
            try await withCheckedThrowingContinuation { completion = $0 }
            return .init(activate: { activated = true; return true })
        })
        let old = interaction.presentBar()
        interaction.updateQuery("Notes")
        await files.send([SearchResult(name: "Notes.txt", url: URL(fileURLWithPath: "/fixture/Notes.txt"), kind: .file)])
        try await eventually { interaction.selectedResult != nil }
        let opening = interaction.requestSelectedOpen()
        try await eventually { completion != nil }
        interaction.dismiss(old, reason: .escape)
        let fresh = interaction.presentBar()
        interaction.updateQuery("new context")
        completion?.resume()
        await opening?.value
        #expect(!activated)
        #expect(interaction.currentInvocation == fresh)
        #expect(interaction.query == "new context")
        interaction.dismiss(fresh, reason: .outsideClick)
    }

    @Test func deletedFileFailsNativeRevalidationWithoutLosingQuery() async throws {
        _ = NSApplication.shared
        let files = CatalogFeed()
        let interaction = MacInteraction(search: Search(source: { AsyncStream { $0.finish() } }, files: { _ in files.stream() }, debounce: .zero))
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        interaction.updateQuery("Missing")
        await files.send([SearchResult(name: "Missing.txt", url: URL(fileURLWithPath: "/nonexistent-hana-validation/Missing.txt"), kind: .file)])
        try await eventually { interaction.selectedResult != nil }
        await interaction.requestSelectedOpen()?.value
        #expect(interaction.currentInvocation == invocation)
        #expect(interaction.query == "Missing")
        #expect(interaction.openFailure != nil)
    }

    @Test func selectedFileSurvivesLateAppBatchAndFailedOpenRetainsContext() async throws {
        _ = NSApplication.shared
        let files = CatalogFeed(), apps = CatalogFeed()
        var attempted: URL?
        let file = SearchResult(name: "Notes.txt", url: URL(fileURLWithPath: "/missing/Notes.txt"), kind: .file)
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, files: { _ in files.stream() }, debounce: .zero), openFile: { url in
            attempted = url
            throw CocoaError(.fileReadNoPermission)
        })
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        interaction.updateQuery("Notes")
        await files.send([file])
        try await eventually { interaction.selectedResult?.id == file.id }
        await apps.send([app("Notes", "/Applications/Notes.app")])
        try await eventually { interaction.results.count == 2 }
        #expect(interaction.selectedResult?.id == file.id)
        await interaction.requestSelectedOpen()?.value
        #expect(attempted == file.url)
        #expect(interaction.currentInvocation == invocation)
        #expect(interaction.query == "Notes")
        #expect(interaction.openFailure != nil)
    }

    @Test func changedQueryNeverActivatesAnOldAcknowledgment() async throws {
        _ = NSApplication.shared
        let feed = CatalogFeed()
        var completion: CheckedContinuation<Void, Error>?
        var activated = false
        let interaction = MacInteraction(search: Search(source: { feed.stream() }, debounce: .zero), launchApplication: { _ in
            try await withCheckedThrowingContinuation { completion = $0 }
            return .init(activate: { activated = true; return true })
        })
        let invocation = interaction.presentBar()
        interaction.updateQuery("App")
        await feed.send([app("App", "/Applications/App.app")])
        try await eventually { interaction.selectedResult != nil }
        let operation = interaction.requestSelectedOpen()
        try await eventually { completion != nil }
        interaction.updateQuery("new")
        completion?.resume()
        await operation?.value
        #expect(!activated)
        #expect(interaction.currentInvocation == invocation)
        #expect(interaction.query == "new")
        interaction.dismiss(invocation, reason: .outsideClick)
    }

    @Test func unavailableInstallationFailsThroughTheNativeAdapterWithoutLosingContext() async throws {
        _ = NSApplication.shared
        let feed = CatalogFeed()
        let interaction = MacInteraction(search: Search(source: { feed.stream() }, debounce: .zero))
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        interaction.updateQuery("Missing")
        await feed.send([app("Missing", "/nonexistent-hana-validation/Missing.app")])
        try await eventually { interaction.selectedResult != nil }
        await interaction.requestSelectedOpen()?.value
        #expect(interaction.currentInvocation == invocation)
        #expect(interaction.query == "Missing")
        #expect(interaction.openFailure != nil)
    }

    @Test func enterCapturesTheVisibleDestinationBeforeAsynchronousWork() async throws {
        _ = NSApplication.shared
        let feed = CatalogFeed()
        var opened: [URL] = []
        let interaction = MacInteraction(search: Search(source: { feed.stream() }, debounce: .zero), launchApplication: { url in .init(activate: { opened.append(url); return true }) })
        let invocation = interaction.presentBar()
        defer { if let current = interaction.currentInvocation { interaction.dismiss(current, reason: .outsideClick) } }
        interaction.updateQuery("App")
        let a = app("App A", "/Applications/A.app"), b = app("App B", "/Applications/B.app")
        await feed.send([a, b])
        try await eventually { interaction.results.count == 2 }
        let opening = interaction.requestSelectedOpen()
        interaction.moveSelection(by: 1)
        await opening?.value
        #expect(opened == [a.url])
        #expect(interaction.currentInvocation != invocation)
    }

    @Test func failureRetainsQueryAndOldAcknowledgmentCannotDismissNewInvocation() async throws {
        _ = NSApplication.shared
        let feed = CatalogFeed()
        var completion: CheckedContinuation<Void, Error>?
        var activationRequests = 0
        let interaction = MacInteraction(search: Search(source: { feed.stream() }, debounce: .zero), launchApplication: { _ in
            try await withCheckedThrowingContinuation { completion = $0 }
            return .init(activate: { activationRequests += 1; return true })
        })
        let old = interaction.presentBar()
        interaction.updateQuery("App")
        await feed.send([app("App", "/Applications/App.app")])
        try await eventually { interaction.selectedResult != nil }
        let failed = Task { await interaction.requestSelectedOpen()?.value }
        try await eventually { completion != nil }
        completion?.resume(throwing: CocoaError(.fileReadNoPermission))
        await failed.value
        #expect(interaction.query == "App")
        #expect(interaction.selectedResult?.name == "App")
        #expect(interaction.openFailure?.contains("retry") == true)
        #expect(interaction.currentInvocation == old)
        completion = nil
        let delayed = Task { await interaction.requestSelectedOpen()?.value }
        try await eventually { completion != nil }
        interaction.dismiss(old, reason: .outsideClick)
        let fresh = interaction.presentBar()
        interaction.updateQuery("new")
        completion?.resume()
        await delayed.value
        #expect(interaction.currentInvocation == fresh)
        #expect(interaction.query == "new")
        #expect(activationRequests == 0)
        // A real user Space change remains an ordinary dismissal, even after an
        // old native operation has completed without requesting activation.
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)
        #expect(interaction.currentInvocation == nil)
    }

    @Test func obsoleteBatchesAndClearingCannotReplaceCurrentResults() async throws {
        _ = NSApplication.shared
        let feed = CatalogFeed()
        let interaction = MacInteraction(search: Search(source: { feed.stream() }, debounce: .zero))
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        interaction.updateQuery("Alpha")
        await feed.send([app("Alpha", "/Applications/A.app")])
        try await eventually { interaction.results.count == 1 }
        interaction.updateQuery("Beta")
        await feed.send([app("Alpha", "/Applications/A.app"), app("Beta", "/Applications/B.app")])
        try await eventually { feed.subscriptionCount == 2 }
        await feed.send([app("Alpha", "/Applications/A.app"), app("Beta", "/Applications/B.app")])
        try await eventually { interaction.results.first?.name == "Beta" }
        interaction.updateQuery("")
        await feed.send([app("Alpha", "/Applications/A.app")])
        try await Task.sleep(for: .milliseconds(10))
        #expect(interaction.results.isEmpty)
        #expect(interaction.selectedResult == nil)
    }

    @Test func selectionTracksIdentityAndVanishingNeverOpensANeighbor() async throws {
        _ = NSApplication.shared
        let feed = CatalogFeed()
        let search = Search(source: { feed.stream() }, debounce: .zero)
        var opened: [URL] = []
        let interaction = MacInteraction(search: search, launchApplication: { url in .init(activate: { opened.append(url); return true }) })
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let a = app("App A", "/Applications/A.app"), b = app("App B", "/Applications/B.app")
        interaction.updateQuery("App")
        await feed.send([a, b])
        try await eventually { interaction.results.count == 2 }
        interaction.moveSelection(by: 1)
        #expect(interaction.selectedResult?.id == b.id)
        await feed.send([b])
        try await eventually { interaction.results.count == 1 }
        #expect(interaction.selectedResult?.id == b.id)
        await feed.send([a])
        try await eventually { interaction.results.first?.id == a.id }
        #expect(interaction.selectedResult == nil)
        await interaction.requestSelectedOpen()?.value
        #expect(opened.isEmpty)
        interaction.moveSelection(by: 1)
        await interaction.requestSelectedOpen()?.value
        #expect(opened == [a.url])
        #expect(interaction.currentInvocation == nil)
    }
}

@MainActor
final class CatalogFeed {
    private var continuations: [AsyncStream<SourceSnapshot>.Continuation] = []
    var cancellationCount = 0
    var subscriptionCount: Int { continuations.count }
    func stream() -> AsyncStream<SourceSnapshot> {
        AsyncStream { continuation in
            continuations.append(continuation)
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor in self?.cancellationCount += 1 }
            }
        }
    }
    func send(_ apps: [SearchResult], status: SourceStatus = .ready) async {
        while continuations.isEmpty { await Task.yield() }
        for continuation in continuations { continuation.yield(.init(results: apps, status: status)) }
    }
}

@MainActor
func eventually(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(condition())
}
