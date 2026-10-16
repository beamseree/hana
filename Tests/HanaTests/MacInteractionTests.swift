import AppKit
import Testing
@testable import Hana

// Real AppKit presentation through the agreed module boundary. These checks do
// not claim that macOS routed a physical keystroke or restored a foreign editor.
@Suite(.serialized, .nativeWindowSlot)
@MainActor
struct MacInteractionTests {
    @Test func emptySourceUpdateDoesNotReplaceRowsWithOnlyRecheckedMatches() async throws {
        _ = NSApplication.shared
        let apps = CatalogFeed(), files = CatalogFeed()
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, files: { _ in files.stream() }, typingGap: .zero))
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let notes = app("Notes", "/fixture/Notes.app"), numbers = app("Numbers", "/fixture/Numbers.app")
        interaction.updateQuery("N")
        await apps.send([notes, numbers]); await files.send([])
        try await eventually { interaction.results == [notes, numbers] }
        interaction.updateQuery("No")
        try await eventually { files.subscriptionCount == 2 }
        // A completed empty file response can publish the catalog's rechecked
        // Notes row even though no source has delivered any fresh match yet.
        await files.send([], status: .failed)
        try await eventually { interaction.statusMessage?.contains("failure") == true }
        #expect(interaction.results == [notes, numbers])
        #expect(interaction.statusMessage == "A search source reported a failure. Retry the search.")
        await apps.send([notes], status: .loading)
        try await eventually { interaction.results == [notes] }
        #expect(interaction.isLoading)
        #expect(interaction.statusMessage == "A search source reported a failure. Available results are shown; retry the search.")
    }

    @Test(arguments: [true, false])
    func sourceFailureOnlyClaimsResultsForTheDisplayedRequest(fileSourceFails: Bool) async throws {
        _ = NSApplication.shared
        let matches = CatalogFeed(), failing = CatalogFeed()
        let apps = fileSourceFails ? matches : failing
        let files = fileSourceFails ? failing : matches
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, files: { _ in files.stream() }, typingGap: .zero))
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let result = SearchResult(name: "Notes", url: URL(fileURLWithPath: "/fixture/Notes"),
                                  kind: fileSourceFails ? .application : .file)
        interaction.updateQuery("Notes")
        await matches.send([result], status: .loading)
        try await eventually { interaction.results == [result] }
        await failing.send([], status: .failed)
        try await eventually { interaction.statusMessage?.contains("failure") == true }
        #expect(interaction.statusMessage == "A search source reported a failure. Available results are shown; retry the search.")

        interaction.updateQuery("missing")
        try await eventually { failing.subscriptionCount == 2 }
        await failing.send([], status: .failed)
        try await eventually { interaction.statusMessage?.contains("failure") == true }
        #expect(interaction.results == [result])
        #expect(interaction.statusMessage == "A search source reported a failure. Retry the search.")
        await matches.send([])
        try await eventually { interaction.results.isEmpty }
        #expect(interaction.statusMessage == "A search source reported a failure. Retry the search.")
    }

    @Test func enterOnAnOutdatedRowWaitsAndOpensTheFreshMatch() async throws {
        _ = NSApplication.shared
        let apps = CatalogFeed()
        var opened: [URL] = []
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, typingGap: .zero),
            launchApplication: { url in opened.append(url); return .init(activate: { true }) })
        interaction.presentBar()
        defer { if let current = interaction.currentInvocation { interaction.dismiss(current, reason: .outsideClick) } }
        let notes = app("Notes", "/fixture/Notes.app"), safari = app("Safari", "/fixture/Safari.app")
        interaction.updateQuery("Note")
        await apps.send([notes])
        try await eventually { interaction.selectedResult?.id == notes.id }
        interaction.updateQuery("Safari")
        #expect(interaction.selectedResult?.id == notes.id)
        #expect(interaction.requestSelectedOpen() == nil)
        // Held: the visible rows stay and the opening status is shown.
        #expect(interaction.statusMessage == "Opening selected destination…")
        #expect(interaction.results == [notes])
        #expect(opened.isEmpty)
        try await eventually { apps.subscriptionCount == 2 }
        await apps.send([notes, safari])
        try await eventually { interaction.currentInvocation == nil }
        #expect(opened == [safari.url])
    }

    @Test func enterOnARetainedRowThatStillMatchesOpensImmediately() async throws {
        _ = NSApplication.shared
        let apps = CatalogFeed()
        var opened: [URL] = []
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, typingGap: .zero),
            launchApplication: { url in opened.append(url); return .init(activate: { true }) })
        interaction.presentBar()
        defer { if let current = interaction.currentInvocation { interaction.dismiss(current, reason: .outsideClick) } }
        let notes = app("Notes", "/fixture/Notes.app")
        interaction.updateQuery("Note")
        await apps.send([notes])
        try await eventually { interaction.selectedResult?.id == notes.id }
        interaction.updateQuery("Notes")
        await interaction.requestSelectedOpen()?.value
        #expect(opened == [notes.url])
        #expect(interaction.currentInvocation == nil)
    }

    @Test func enterAgainAfterNavigatingToAMatchingRowOpensItAtOnce() async throws {
        _ = NSApplication.shared
        let apps = CatalogFeed()
        var opened: [URL] = []
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, typingGap: .zero),
            launchApplication: { url in opened.append(url); return .init(activate: { true }) })
        interaction.presentBar()
        defer { if let current = interaction.currentInvocation { interaction.dismiss(current, reason: .outsideClick) } }
        let notes = app("Notes", "/fixture/Notes.app"), numbers = app("Numbers", "/fixture/Numbers.app")
        interaction.updateQuery("N")
        await apps.send([notes, numbers])
        try await eventually { interaction.results == [notes, numbers] }
        interaction.updateQuery("Nu")
        #expect(interaction.selectedResult?.id == notes.id)
        #expect(interaction.requestSelectedOpen() == nil)
        interaction.moveSelection(by: 1)
        await interaction.requestSelectedOpen()?.value
        #expect(opened == [numbers.url])
        #expect(interaction.currentInvocation == nil)
    }

    @Test func anEditCancelsAHeldEnter() async throws {
        _ = NSApplication.shared
        let apps = CatalogFeed()
        var opened: [URL] = []
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, typingGap: .zero),
            launchApplication: { url in opened.append(url); return .init(activate: { true }) })
        let invocation = interaction.presentBar()
        defer { if let current = interaction.currentInvocation { interaction.dismiss(current, reason: .outsideClick) } }
        let notes = app("Notes", "/fixture/Notes.app"), safari = app("Safari", "/fixture/Safari.app")
        interaction.updateQuery("Note")
        await apps.send([notes])
        try await eventually { interaction.selectedResult?.id == notes.id }
        interaction.updateQuery("Safari")
        interaction.requestSelectedOpen()
        interaction.updateQuery("Safar")
        #expect(interaction.statusMessage == nil)
        try await eventually { apps.subscriptionCount == 2 }
        await apps.send([notes, safari])
        try await eventually { interaction.results == [safari] }
        try await Task.sleep(for: .milliseconds(20))
        #expect(opened.isEmpty)
        #expect(interaction.currentInvocation == invocation)
        await interaction.requestSelectedOpen()?.value
        #expect(opened == [safari.url])
    }

    @Test(arguments: [MacInteraction.DismissalReason.escape, .shortcut, .outsideClick])
    func dismissalCancelsAHeldEnter(reason: MacInteraction.DismissalReason) async throws {
        _ = NSApplication.shared
        let apps = CatalogFeed()
        var launched: [URL] = [], activated = false
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, typingGap: .zero),
            launchApplication: { url in launched.append(url); return .init(activate: { activated = true; return true }) })
        let invocation = interaction.presentBar()
        let notes = app("Notes", "/fixture/Notes.app"), safari = app("Safari", "/fixture/Safari.app")
        interaction.updateQuery("Note")
        await apps.send([notes])
        try await eventually { interaction.selectedResult?.id == notes.id }
        interaction.updateQuery("Safari")
        interaction.requestSelectedOpen()
        try await eventually { apps.subscriptionCount == 2 }
        interaction.dismiss(invocation, reason: reason)
        let fresh = interaction.presentBar()
        defer { interaction.dismiss(fresh, reason: .outsideClick) }
        await apps.send([notes, safari])
        try await Task.sleep(for: .milliseconds(20))
        #expect(launched.isEmpty)
        #expect(!activated)
        #expect(interaction.currentInvocation == fresh)
    }

    @Test func aHeldEnterEndsWithNoMatchesWhenBothSourcesFinishEmpty() async throws {
        _ = NSApplication.shared
        let apps = CatalogFeed(), files = CatalogFeed()
        var opened: [URL] = []
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, files: { _ in files.stream() }, typingGap: .zero),
            launchApplication: { url in opened.append(url); return .init(activate: { true }) },
            openFile: { url in opened.append(url); return .init(activate: { true }) })
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let notes = app("Notes", "/fixture/Notes.app")
        interaction.updateQuery("Note")
        await apps.send([notes]); await files.send([])
        try await eventually { interaction.results == [notes] && !interaction.isLoading }
        interaction.updateQuery("no-such-result")
        interaction.requestSelectedOpen()
        try await eventually { apps.subscriptionCount == 2 && files.subscriptionCount == 2 }
        await apps.send([notes])
        try await Task.sleep(for: .milliseconds(20)) // Files are still loading.
        #expect(interaction.results == [notes])
        #expect(interaction.statusMessage == "Opening selected destination…")
        await files.send([])
        try await eventually { interaction.statusMessage?.hasPrefix("No matches") == true }
        #expect(interaction.results.isEmpty)
        #expect(opened.isEmpty)
        #expect(interaction.currentInvocation == invocation)
    }

    @Test func editsKeepPreviousRowsUntilFreshMatchesArrive() async throws {
        _ = NSApplication.shared
        let apps = CatalogFeed(), files = CatalogFeed()
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, files: { _ in files.stream() }, typingGap: .zero))
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let notes = app("Notes", "/fixture/Notes.app")
        let numbers = app("Numbers", "/fixture/Numbers.app")
        let safari = app("Safari", "/fixture/Safari.app")
        interaction.updateQuery("N")
        await apps.send([notes, numbers]); await files.send([])
        try await eventually { interaction.results == [notes, numbers] }
        interaction.updateQuery("No")
        #expect(interaction.results == [notes, numbers])
        #expect(interaction.selectedResult?.id == notes.id)
        interaction.updateQuery("N") // Backspace before the new source responds.
        #expect(interaction.results == [notes, numbers])
        interaction.updateQuery("Safari")
        #expect(interaction.results == [notes, numbers])
        try await eventually { apps.subscriptionCount >= 2 && files.subscriptionCount >= 2 }
        await apps.send([], status: .failed)
        try await eventually { interaction.statusMessage?.contains("failure") == true }
        #expect(interaction.results == [notes, numbers])
        #expect(interaction.isLoading)
        await files.send([safari], status: .loading)
        try await eventually { interaction.results == [safari] }
        #expect(interaction.selectedResult?.id == safari.id)
        #expect(interaction.isLoading)
        interaction.updateQuery("no-such-result")
        #expect(interaction.results == [safari])
        let subscriptions = files.subscriptionCount
        try await eventually { files.subscriptionCount > subscriptions }
        await apps.send([]); await files.send([])
        try await eventually { interaction.results.isEmpty && interaction.statusMessage?.hasPrefix("No matches") == true }
    }

    @Test func editingDuringAFinishedShrinkHoldsTheCurrentHeightWhileLoading() async throws {
        _ = NSApplication.shared
        let apps = CatalogFeed()
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, typingGap: .zero))
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let values = (1...7).map { app("Notes \($0)", "/fixture/\($0).app") }
        interaction.updateQuery("N")
        await apps.send(values)
        try await eventually { interaction.contentHeight == 468 }
        await apps.send([values[0]])
        try await eventually { interaction.results.count == 1 }
        let heightAtEdit = interaction.contentHeight
        interaction.updateQuery("No")
        try await Task.sleep(for: .milliseconds(180))
        #expect(interaction.contentHeight >= heightAtEdit)
    }

    @Test func selectionFollowsBetterMatchesAndEveryEditResetsNavigationAndScroll() async throws {
        _ = NSApplication.shared
        let feed = CatalogFeed()
        let interaction = MacInteraction(search: Search(source: { feed.stream() }, typingGap: .zero))
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let values = (10...21).map { app("App \($0)", "/fixture/\($0).app") }
        let best = app("App", "/fixture/best.app")
        interaction.updateQuery("App")
        await feed.send(values)
        try await eventually { interaction.selectedResult?.id == values[0].id }
        await feed.send(values + [best])
        try await eventually { interaction.selectedResult?.id == best.id }
        interaction.moveSelection(by: 12)
        try await eventually { interaction.resultsScrollOffset > 0 }
        let chosen = interaction.selectedResult?.id
        await feed.send(Array(values.dropFirst()) + [best])
        try await eventually { interaction.results.count == 12 }
        #expect(interaction.selectedResult?.id == chosen)
        interaction.updateQuery("App ")
        try await eventually { interaction.selectedResult?.id == best.id && interaction.resultsScrollOffset == 0 }
        // Another edit resets even when the selected result's ID is unchanged.
        interaction.updateQuery("App")
        try await eventually { feed.subscriptionCount == 3 }
        #expect(interaction.selectedResult?.id == best.id)
        #expect(interaction.resultsScrollOffset == 0)
    }

    @Test func loadingUsesNoStatusRowAndNoResultsWaitsForBothSources() async throws {
        _ = NSApplication.shared
        let apps = CatalogFeed(), files = CatalogFeed()
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, files: { _ in files.stream() }, typingGap: .zero))
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        interaction.updateQuery("nothing")
        #expect(interaction.isLoading)
        #expect(interaction.statusMessage == nil)
        await apps.send([])
        try await eventually { files.subscriptionCount == 1 }
        try await Task.sleep(for: .milliseconds(180))
        #expect(interaction.statusMessage == nil)
        // Only New note and New task, while no source has matched.
        #expect(interaction.contentHeight == 188)
        await files.send([])
        try await eventually { interaction.statusMessage?.hasPrefix("No matches") == true }
        #expect(!interaction.isLoading)
        #expect(interaction.results.isEmpty)
    }

    @Test(arguments: [SourceStatus.ready, .partial, .failed])
    func typingKeepsHeightUntilBothSourcesFinishAndClearingCollapses(finishedStatus: SourceStatus) async throws {
        _ = NSApplication.shared
        let apps = CatalogFeed(), files = CatalogFeed()
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, files: { _ in files.stream() }, typingGap: .zero))
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let values = (1...7).map { app("Notes \($0)", "/fixture/\($0).app") }
        interaction.updateQuery("N")
        await apps.send(values)
        try await eventually { interaction.results.count == 7 && interaction.contentHeight >= 468 }
        let expanded = interaction.contentHeight
        for (index, query) in ["No", "Not", "Note", "Notes"].enumerated() {
            interaction.updateQuery(query)
            #expect(interaction.results == values)
            try await eventually { apps.subscriptionCount == index + 2 && files.subscriptionCount == index + 2 }
            await apps.send(values, status: .loading)
            try await Task.sleep(for: .milliseconds(180)) // Let any incorrect shrink animation finish.
            #expect(interaction.contentHeight == expanded)
        }
        await apps.send([values[0]], status: .ready)
        try await eventually { interaction.results.count == 1 }
        try await Task.sleep(for: .milliseconds(180))
        #expect(interaction.contentHeight == expanded) // Files still loading.
        await files.send([], status: finishedStatus)
        // One match and the two suggestions, plus any status row.
        let finishedHeight: CGFloat = finishedStatus == .ready ? 244 : 288
        try await eventually { interaction.contentHeight == finishedHeight }
        interaction.updateQuery("")
        try await eventually { interaction.contentHeight == 68 && interaction.results.isEmpty }
    }

    @Test func reinvocationKeepsTheCurrentSession() {
        _ = NSApplication.shared
        let interaction = MacInteraction()
        let first = interaction.presentBar()
        defer { interaction.dismiss(first, reason: .outsideClick) }
        #expect(interaction.presentBar() == first)
        #expect(interaction.currentInvocation == first)
    }

    @Test(arguments: ["", "search text", "-"], [CaptureSession.Mode.search, .note, .task])
    func searchShortcutClosesTheBarAndReopensEmptySearch(text: String, mode: CaptureSession.Mode) async throws {
        _ = NSApplication.shared
        let interaction = MacInteraction(frontmostApplication: { nil })
        defer { interaction.stop() }
        interaction.toggleBar()
        let first = try #require(interaction.currentInvocation)
        try await eventually { NSApp.keyWindow?.title == "Hana Search" }
        let panel = try #require(NSApp.keyWindow)
        let editor = try #require(panel.firstResponder as? NSTextView)
        editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        if mode != .search {
            if mode == .note { try enterNoteCaptureForValidation(interaction, editor: editor) }
            else {
                editor.setSelectedRange(NSRange(location: 0, length: 0))
                editor.insertText("[", replacementRange: NSRange(location: NSNotFound, length: 0))
            }
            #expect(interaction.mode == mode)
            editor.insertText("unsaved capture", replacementRange: NSRange(location: NSNotFound, length: 0))
        }

        interaction.toggleBar()
        #expect(interaction.currentInvocation == nil)
        #expect(!panel.isVisible)
        #expect(interaction.query.isEmpty)

        interaction.toggleBar()
        let fresh = try #require(interaction.currentInvocation)
        #expect(fresh != first)
        #expect(interaction.mode == .search && interaction.query.isEmpty)
        interaction.dismiss(first, reason: .shortcut)
        #expect(interaction.currentInvocation == fresh)
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
        #expect(!interaction.open(.main, from: old))
        #expect(interaction.currentInvocation == fresh)
    }

}

@Suite(.serialized, .nativeWindowSlot)
@MainActor
struct DestinationInteractionTests {
    @Test func newQueryCanOpenWhileAnObsoleteOpenIsStillPending() async throws {
        _ = NSApplication.shared
        let feed = CatalogFeed()
        var oldCompletion: CheckedContinuation<Void, Error>?
        var activated: [URL] = []
        let a = app("Alpha", "/Applications/A.app"), b = app("Beta", "/Applications/B.app")
        let interaction = MacInteraction(search: Search(source: { feed.stream() }, typingGap: .zero), launchApplication: { url in
            if url == a.url { try await withCheckedThrowingContinuation { oldCompletion = $0 } }
            return .init(activate: { activated.append(url); return true })
        })
        interaction.presentBar()
        defer { if let current = interaction.currentInvocation { interaction.dismiss(current, reason: .outsideClick) } }
        interaction.updateQuery("Alpha")
        await feed.send([a, b])
        try await eventually { interaction.selectedResult?.id == a.id }
        let obsolete = interaction.requestSelectedOpen()
        try await eventually { oldCompletion != nil }
        interaction.updateQuery("Beta")
        try await eventually { feed.subscriptionCount == 2 }
        await feed.send([a, b])
        try await eventually { interaction.selectedResult?.id == b.id }
        await interaction.requestSelectedOpen()?.value
        #expect(activated == [b.url])
        oldCompletion?.resume(throwing: CocoaError(.fileReadNoPermission))
        await obsolete?.value
        #expect(activated == [b.url])
        #expect(interaction.openFailure == nil)
    }

    @Test func onlyAcknowledgedOpeningImprovesSessionUsage() async throws {
        _ = NSApplication.shared
        let a = app("App A", "/Applications/A.app"), b = app("App B", "/Applications/B.app")
        let search = Search(source: { AsyncStream { $0.yield(.init(results: [b, a], status: .ready)); $0.finish() } }, typingGap: .zero)
        var shouldFail = true
        let interaction = MacInteraction(search: search, launchApplication: { _ in
            if shouldFail { throw CocoaError(.fileReadNoPermission) }
            return .init(activate: { true })
        })
        let invocation = interaction.presentBar()
        interaction.updateQuery("App")
        try await eventually { interaction.results.count == 2 }
        interaction.moveSelection(by: 1)
        await interaction.requestSelectedOpen()?.value
        var last: Search.Batch?
        for await batch in search.search(.init(text: "App")) { last = batch }
        #expect(last?.results.map(\.id) == [a.id, b.id])
        #expect(interaction.currentInvocation == invocation)
        shouldFail = false
        await interaction.requestSelectedOpen()?.value
        for await batch in search.search(.init(text: "App")) { last = batch }
        #expect(last?.results.map(\.id) == [b.id, a.id])
        #expect(interaction.currentInvocation == nil)
    }

    @Test func usageIsRecordedOnlyForTheResultMatchingTheOpenedRequest() async throws {
        _ = NSApplication.shared
        let a = app("App A", "/Applications/A.app"), b = app("App B", "/Applications/B.app")
        let search = Search(source: { AsyncStream { $0.yield(.init(results: [a, b], status: .ready)); $0.finish() } }, typingGap: .zero)
        var opened: [URL] = []
        let interaction = MacInteraction(search: search,
            launchApplication: { url in opened.append(url); return .init(activate: { true }) })
        interaction.presentBar()
        defer { if let current = interaction.currentInvocation { interaction.dismiss(current, reason: .outsideClick) } }
        interaction.updateQuery("App")
        try await eventually { interaction.results.map(\.id) == [a.id, b.id] }
        // App A stays selected but no longer matches; Enter waits for App B.
        interaction.updateQuery("App B")
        #expect(interaction.selectedResult?.id == a.id)
        interaction.requestSelectedOpen()
        try await eventually { interaction.currentInvocation == nil }
        #expect(opened == [b.url])
        var last: Search.Batch?
        for await batch in search.search(.init(text: "App")) { last = batch }
        #expect(last?.results.map(\.id) == [b.id, a.id])
    }

    @Test func navigatedFileSurvivesNewExactBatchAndRemovalReturnsToFirstRow() async throws {
        _ = NSApplication.shared
        let apps = CatalogFeed(), files = CatalogFeed()
        let a = app("Note A", "/Applications/A.app")
        let chosen = SearchResult(name: "Note Z", url: URL(fileURLWithPath: "/fixture/Z.txt"), kind: .file)
        let exact = app("Note", "/Applications/exact.app")
        var opened: [URL] = []
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, files: { _ in files.stream() }, typingGap: .zero),
                                         openFile: { url in opened.append(url); return .init(activate: { true }) })
        let invocation = interaction.presentBar()
        defer { if let current = interaction.currentInvocation { interaction.dismiss(current, reason: .outsideClick) } }
        interaction.updateQuery("Note")
        await apps.send([a]); await files.send([chosen])
        try await eventually { interaction.results.count == 2 }
        interaction.moveSelection(by: 1)
        #expect(interaction.selectedResult?.id == chosen.id)
        await apps.send([exact, a])
        try await eventually { interaction.results.first?.id == exact.id }
        #expect(interaction.selectedResult?.id == chosen.id)
        await files.send([])
        try await eventually { interaction.results.count == 2 }
        #expect(interaction.selectedResult?.id == exact.id)
        await files.send([chosen])
        try await eventually { interaction.results.count == 3 }
        #expect(interaction.selectedResult?.id == exact.id)
        interaction.moveSelection(by: 2)
        await interaction.requestSelectedOpen()?.value
        #expect(opened == [chosen.url])
        #expect(interaction.currentInvocation != invocation)
    }

    @Test func rapidReopeningRejectsPendingBatchesAndFailedOpenCallbacks() async throws {
        _ = NSApplication.shared
        let oldFiles = CatalogFeed(), newFiles = CatalogFeed()
        var completion: CheckedContinuation<Void, Error>?
        let file = SearchResult(name: "Old", url: URL(fileURLWithPath: "/fixture/old.txt"), kind: .file)
        let freshFile = SearchResult(name: "Fresh", url: URL(fileURLWithPath: "/fixture/fresh.txt"), kind: .file)
        let interaction = MacInteraction(search: Search(source: { AsyncStream { $0.finish() } }, files: { text in
            text == "Old" ? oldFiles.stream() : newFiles.stream()
        }, typingGap: .zero), openFile: { _ in
            try await withCheckedThrowingContinuation { completion = $0 }
            return .init(activate: { Issue.record("Obsolete callback activated"); return false })
        })
        let old = interaction.presentBar()
        interaction.updateQuery("Old")
        await oldFiles.send([file])
        try await eventually { interaction.selectedResult != nil }
        let opening = interaction.requestSelectedOpen()
        try await eventually { completion != nil }
        interaction.dismiss(old, reason: .escape)
        for _ in 0..<5 {
            let transient = interaction.presentBar()
            interaction.updateQuery("Fresh")
            interaction.dismiss(transient, reason: .outsideClick)
        }
        let fresh = interaction.presentBar()
        defer { interaction.dismiss(fresh, reason: .outsideClick) }
        interaction.updateQuery("Fresh")
        await newFiles.send([freshFile])
        try await eventually { interaction.selectedResult?.id == freshFile.id }
        await oldFiles.send([file], status: .failed)
        completion?.resume(throwing: CocoaError(.fileReadNoPermission))
        await opening?.value
        #expect(interaction.currentInvocation == fresh)
        #expect(interaction.query == "Fresh")
        #expect(interaction.selectedResult?.id == freshFile.id)
        #expect(interaction.openFailure == nil)
    }

    @Test func delayedFileAcknowledgmentNeverActivatesOrDismissesANewerInvocation() async throws {
        _ = NSApplication.shared
        let files = CatalogFeed()
        var completion: CheckedContinuation<Void, Error>?
        var activated = false
        let interaction = MacInteraction(search: Search(source: { AsyncStream { $0.finish() } }, files: { _ in files.stream() }, typingGap: .zero), openFile: { _ in
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
        let interaction = MacInteraction(search: Search(source: { AsyncStream { $0.finish() } }, files: { _ in files.stream() }, typingGap: .zero))
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
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, files: { _ in files.stream() }, typingGap: .zero), openFile: { url in
            attempted = url
            throw CocoaError(.fileReadNoPermission)
        })
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        interaction.updateQuery("Notes")
        await files.send([file])
        try await eventually { interaction.selectedResult?.id == file.id }
        // Navigates without leaving the top row; the suggestions are below it.
        interaction.moveSelection(by: -1)
        await apps.send([app("Notes", "/Applications/Notes.app")])
        try await eventually { interaction.results.count == 2 }
        #expect(interaction.selectedResult?.id == file.id)
        await interaction.requestSelectedOpen()?.value
        #expect(attempted == file.url)
        #expect(interaction.currentInvocation == invocation)
        #expect(interaction.query == "Notes")
        #expect(interaction.openFailure == "Access was denied. Check this destination’s permissions in Finder, then retry.")
        #expect(interaction.selectedResult?.id == file.id)
    }

    @Test func failedFilesStillAllowAvailableApplicationOpening() async throws {
        _ = NSApplication.shared
        let apps = CatalogFeed(), files = CatalogFeed()
        let destination = app("Hana9 App", "/Applications/Hana9.app")
        var activated = false
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, files: { _ in files.stream() }, typingGap: .zero),
            launchApplication: { _ in .init(activate: { activated = true; return true }) })
        interaction.presentBar()
        interaction.updateQuery("Hana9")
        await apps.send([destination]); await files.send([], status: .failed)
        try await eventually { interaction.selectedResult?.id == destination.id }
        #expect(interaction.query == "Hana9")
        await interaction.requestSelectedOpen()?.value
        #expect(activated)
        #expect(interaction.currentInvocation == nil)
    }

    @Test func missingFileExplainsUnavailableLocationAndRetainsSelection() async throws {
        _ = NSApplication.shared
        let file = SearchResult(name: "Hana9 Missing", url: URL(fileURLWithPath: "/nonexistent-hana9/Missing.txt"), kind: .file)
        let interaction = MacInteraction(search: Search(source: { AsyncStream { $0.yield(.init(results: [file], status: .ready)); $0.finish() } }, typingGap: .zero))
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .escape) }
        interaction.updateQuery("Hana9")
        try await eventually { interaction.selectedResult?.id == file.id }
        await interaction.requestSelectedOpen()?.value
        #expect(interaction.openFailure == "This destination is no longer available at this location. Check it in Finder, then search again.")
        #expect(interaction.query == "Hana9")
        #expect(interaction.selectedResult?.id == file.id)
        #expect(interaction.currentInvocation == invocation)
    }

    @Test func changedQueryNeverActivatesAnOldAcknowledgment() async throws {
        _ = NSApplication.shared
        let feed = CatalogFeed()
        var completion: CheckedContinuation<Void, Error>?
        var activated = false
        let interaction = MacInteraction(search: Search(source: { feed.stream() }, typingGap: .zero), launchApplication: { _ in
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
        let interaction = MacInteraction(search: Search(source: { feed.stream() }, typingGap: .zero))
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
        let interaction = MacInteraction(search: Search(source: { feed.stream() }, typingGap: .zero), launchApplication: { url in .init(activate: { opened.append(url); return true }) })
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

    @Test func barClosesBeforeASlowNativeOpenAcknowledges() async throws {
        _ = NSApplication.shared
        let feed = CatalogFeed()
        var completion: CheckedContinuation<Void, Error>?
        var activated = false
        let interaction = MacInteraction(search: Search(source: { feed.stream() }, typingGap: .zero), launchApplication: { _ in
            .init(open: {
                try await withCheckedThrowingContinuation { completion = $0 }
                return { activated = true; return true }
            })
        })
        interaction.presentBar()
        defer { if let current = interaction.currentInvocation { interaction.dismiss(current, reason: .outsideClick) } }
        interaction.updateQuery("App")
        await feed.send([app("App", "/Applications/App.app")])
        try await eventually { interaction.selectedResult != nil }
        let opening = interaction.requestSelectedOpen()
        try await eventually { completion != nil }
        #expect(interaction.currentInvocation == nil)
        #expect(!activated)
        completion?.resume()
        await opening?.value
        #expect(activated)
    }

    @Test func aNewerBarBlocksALateNativeOpenActivation() async throws {
        _ = NSApplication.shared
        let feed = CatalogFeed()
        var completion: CheckedContinuation<Void, Error>?
        var activated = false
        let interaction = MacInteraction(search: Search(source: { feed.stream() }, typingGap: .zero), launchApplication: { _ in
            .init(open: {
                try await withCheckedThrowingContinuation { completion = $0 }
                return { activated = true; return true }
            })
        })
        interaction.presentBar()
        interaction.updateQuery("App")
        await feed.send([app("App", "/Applications/App.app")])
        try await eventually { interaction.selectedResult != nil }
        let opening = interaction.requestSelectedOpen()
        try await eventually { completion != nil }
        let fresh = interaction.presentBar()
        defer { interaction.dismiss(fresh, reason: .outsideClick) }
        interaction.updateQuery("new")
        completion?.resume()
        await opening?.value
        #expect(!activated)
        #expect(interaction.currentInvocation == fresh)
        #expect(interaction.query == "new")
    }

    @Test func aFailedNativeOpenNeverReachesANewerBar() async throws {
        _ = NSApplication.shared
        let feed = CatalogFeed()
        var completion: CheckedContinuation<Void, Error>?
        let interaction = MacInteraction(search: Search(source: { feed.stream() }, typingGap: .zero), launchApplication: { _ in
            .init(open: {
                try await withCheckedThrowingContinuation { completion = $0 }
                return { true }
            })
        })
        interaction.presentBar()
        interaction.updateQuery("App")
        await feed.send([app("App", "/Applications/App.app")])
        try await eventually { interaction.selectedResult != nil }
        let opening = interaction.requestSelectedOpen()
        try await eventually { completion != nil }
        let fresh = interaction.presentBar()
        defer { interaction.dismiss(fresh, reason: .outsideClick) }
        completion?.resume(throwing: CocoaError(.fileReadUnknown))
        await opening?.value
        #expect(interaction.currentInvocation == fresh)
        #expect(interaction.openFailure == nil)
    }

    @Test func failureRetainsQueryAndOldAcknowledgmentCannotDismissNewInvocation() async throws {
        _ = NSApplication.shared
        let feed = CatalogFeed()
        var completion: CheckedContinuation<Void, Error>?
        var activationRequests = 0
        let interaction = MacInteraction(search: Search(source: { feed.stream() }, typingGap: .zero), launchApplication: { _ in
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
        let interaction = MacInteraction(search: Search(source: { feed.stream() }, typingGap: .zero))
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

    @Test func selectionTracksIdentityAndVanishingReturnsToFollowingTheTop() async throws {
        _ = NSApplication.shared
        let feed = CatalogFeed()
        let search = Search(source: { feed.stream() }, typingGap: .zero)
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
        #expect(interaction.selectedResult?.id == a.id)
        let best = app("App", "/Applications/Best.app")
        await feed.send([a, best])
        try await eventually { interaction.results.first?.id == best.id }
        #expect(interaction.selectedResult?.id == best.id)
        await interaction.requestSelectedOpen()?.value
        #expect(opened == [best.url])
        #expect(interaction.currentInvocation == nil)
    }
}

@Suite(.serialized, .nativeWindowSlot)
@MainActor
struct ResultIconInteractionTests {
    @Test func neverCompletingIconsHoldBackNoBatchSelectionOrOpening() async throws {
        _ = NSApplication.shared
        let feed = CatalogFeed(), icons = IconFeed()
        let a = app("Alpha", "/Applications/A.app"), b = app("Alpha Beta", "/Applications/B.app")
        var launched: [URL] = []
        let interaction = MacInteraction(search: Search(source: { feed.stream() }, typingGap: .zero),
            launchApplication: { url in launched.append(url); return .init(activate: { true }) },
            loadIcon: icons.load)
        interaction.presentBar()
        defer { if let current = interaction.currentInvocation { interaction.dismiss(current, reason: .outsideClick) } }
        interaction.updateQuery("Alpha")
        await feed.send([b, a])
        try await eventually { interaction.results.map(\.id) == [a.id, b.id] }
        #expect(interaction.selectedResult?.id == a.id)
        try await eventually { !icons.requested.isEmpty }
        interaction.moveSelection(by: 1)
        await interaction.requestSelectedOpen()?.value
        #expect(launched == [b.url])
        #expect(interaction.currentInvocation == nil)
    }

    @Test func lateIconsNeverChangeResultsOrSelectionAndObsoleteOnesAreNotShown() async throws {
        _ = NSApplication.shared
        let feed = CatalogFeed(), icons = IconFeed()
        let old = app("Old", "/Applications/Old.app")
        let a = app("New", "/Applications/New.app"), b = app("New Beta", "/Applications/New Beta.app")
        let interaction = MacInteraction(search: Search(source: { feed.stream() }, typingGap: .zero), loadIcon: icons.load)
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        interaction.updateQuery("Old")
        await feed.send([old])
        try await eventually { icons.requested.contains(old.url) }
        interaction.updateQuery("New")
        try await eventually { feed.subscriptionCount == 2 }
        await feed.send([a, b])
        try await eventually { icons.requested.contains(a.url) && icons.requested.contains(b.url) }
        interaction.moveSelection(by: 1)
        icons.release(old.url, with: try solidIcon())
        icons.release(b.url, with: try solidIcon())
        icons.release(a.url, with: nil)
        try await eventually { interaction.icons[b.id] != nil }
        #expect(interaction.icons[old.id] == nil && interaction.icons[a.id] == nil)
        #expect(interaction.results.map(\.id) == [a.id, b.id])
        #expect(interaction.selectedResult?.id == b.id)
        #expect(interaction.query == "New")
    }
}

func solidIcon() throws -> ResultIcon {
    let context = try #require(CGContext(data: nil, width: 2, height: 2, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    return ResultIcon(image: try #require(context.makeImage()), scale: 1)
}

/// Icons that arrive only when a test releases them.
@MainActor
final class IconFeed {
    private var pending: [URL: [CheckedContinuation<ResultIcon?, Never>]] = [:]
    private(set) var requested: [URL] = []
    func load(_ url: URL, scale: CGFloat) async -> ResultIcon? {
        requested.append(url)
        return await withCheckedContinuation { pending[url, default: []].append($0) }
    }
    func release(_ url: URL, with icon: ResultIcon?) {
        pending.removeValue(forKey: url)?.forEach { $0.resume(returning: icon) }
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
    /// Waits for a subscriber, as long as `eventually` waits for a condition. A
    /// Search that never subscribes fails the test instead of spinning forever.
    func send(_ apps: [SearchResult], status: SourceStatus = .ready) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while continuations.isEmpty {
            guard ContinuousClock.now < deadline else {
                Issue.record("No Search subscribed to this feed")
                return
            }
            await Task.yield()
        }
        for continuation in continuations { continuation.yield(.init(results: apps, status: status)) }
    }
}

@MainActor
func eventually(_ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    #expect(condition())
}
