import Foundation
import Testing
@testable import Hana

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct SearchTests {
    @Test func loadingReplacementsNeverResurrectPreviouslyInvisibleCandidates() async throws {
        let apps = CatalogFeed()
        let search = Search(source: { apps.stream() }, typingGap: .zero)
        let candidates = (10...34).map { app("Note \($0)", "/fixture/\($0).app") }
        var iterator = search.search(.init(text: "Note")).makeAsyncIterator()
        await apps.send(candidates, status: .loading)
        var batch = await iterator.next()
        while batch?.results.isEmpty == true { batch = await iterator.next() }
        #expect(batch?.results == Array(candidates.prefix(20)))
        // The next snapshot renames the visible destinations. Candidates that
        // never reached the screen must not accumulate as hidden carryover.
        await apps.send(candidates.prefix(20).map { SearchResult(name: "Other", url: $0.url) }, status: .loading)
        batch = await iterator.next()
        #expect(batch?.results.isEmpty == true)
    }

    @Test func retainedAliasesKeepTheirSourceOwnershipWhenThatSourceFinishes() async throws {
        let apps = CatalogFeed(), files = CatalogFeed()
        let catalog = app("Friendly", "/Applications/Notes.app")
        let indexed = SearchResult(name: "Notes", url: catalog.url)
        let search = Search(source: { apps.stream() }, files: { _ in files.stream() }, typingGap: .zero)
        var first = search.search(.init(text: "Notes")).makeAsyncIterator()
        await apps.send([catalog]); await files.send([indexed])
        while let batch = await first.next(), batch.fileStatus == .loading || batch.appStatus == .loading {}
        var next = search.search(.init(text: "Note")).makeAsyncIterator()
        #expect(await next.next()?.results.first?.id == catalog.id)
        try await eventually { files.subscriptionCount == 2 }
        await files.send([])
        var batch = await next.next()
        while batch?.fileStatus == .loading { batch = await next.next() }
        #expect(batch?.results.isEmpty == true)
    }

    @Test func retainedMatchesSurviveLoadingSnapshotsUntilTheirSourceFinishes() async throws {
        let apps = CatalogFeed(), files = CatalogFeed()
        let application = app("Notes", "/Applications/Notes.app")
        let file = SearchResult(name: "Notes.txt", url: URL(fileURLWithPath: "/fixture/Notes.txt"), kind: .file)
        let search = Search(source: { apps.stream() }, files: { _ in files.stream() }, typingGap: .zero)
        var first = search.search(.init(text: "Notes")).makeAsyncIterator()
        await apps.send([application]); await files.send([file])
        while let batch = await first.next(), batch.results.count != 2 {}
        var next = search.search(.init(text: "Note")).makeAsyncIterator()
        #expect(await next.next()?.results == [application, file])
        try await eventually { apps.subscriptionCount == 2 && files.subscriptionCount == 2 }
        await apps.send([], status: .loading); await files.send([], status: .loading)
        #expect(await next.next()?.results == [application, file])
        await apps.send([], status: .ready)
        var batch = await next.next()
        while batch?.appStatus != .ready { batch = await next.next() }
        #expect(batch?.results == [file])
        await files.send([], status: .ready)
        while batch?.fileStatus != .ready { batch = await next.next() }
        #expect(batch?.results.isEmpty == true)
    }

    @Test func editsFirstYieldRecheckedRerankedResultsBeforeSourcesRespond() async throws {
        let a = app("Alpha Beta", "/Applications/A.app")
        let b = app("Beta Alpha", "/Applications/B.app")
        var responds = true
        let search = Search(source: {
            AsyncStream {
                if responds { $0.yield(.init(results: [a, b], status: .ready)) }
                $0.finish()
            }
        }, typingGap: .zero)
        for await _ in search.search(.init(text: "Alpha")) {}
        responds = false
        for (text, expected) in [("Beta", [b, a]), ("Bet", [b, a]), ("unrelated", [])] {
            var iterator = search.search(.init(text: text)).makeAsyncIterator()
            let initial = await iterator.next()
            #expect(initial?.results == expected)
            #expect(initial?.appStatus == .loading)
        }
    }

    @Test func closenessThenRecentSuccessfulUsePrecedeFrequencyWithinATier() async {
        let exact = app("App", "/Applications/exact.app")
        let close = app("App Z", "/Applications/close.app")
        let frequent = app("App Alphabet", "/Applications/frequent.app")
        let recent = app("App Recently", "/Applications/recent.app")
        let weak = app("My App", "/Applications/weak.app")
        let values = [weak, frequent, recent, close, exact]
        let search = Search(source: { AsyncStream { $0.yield(.init(results: values, status: .ready)); $0.finish() } }, typingGap: .zero)
        for _ in 0..<100 { search.recordOpened(frequent.id); search.recordOpened(weak.id) }
        search.recordOpened(recent.id)
        var last: Search.Batch?
        for await batch in search.search(.init(text: "app")) { last = batch }
        #expect(last?.results.map(\.id) == [exact, close, recent, frequent, weak].map(\.id))
        // A new Search instance has no durable successful-use history.
        let fresh = Search(source: { AsyncStream { $0.yield(.init(results: values, status: .ready)); $0.finish() } }, typingGap: .zero)
        for await batch in fresh.search(.init(text: "app")) { last = batch }
        #expect(last?.results.map(\.id) == [exact, close, frequent, recent, weak].map(\.id))
    }

    @Test func comparisonNormalizesWhitespaceAndCaseButPreservesThaiMarksAndLiteralSymbols() async {
        let literal = app("- [*?] \"Café\" บันทึก", "/Applications/literal.app")
        let wrongMark = app("- [*?] \"Café\" บนทึก", "/Applications/wrong.app")
        let values = [wrongMark, literal, app("Anything", "/Applications/other.app")]
        let search = Search(source: { AsyncStream { $0.yield(.init(results: values, status: .ready)); $0.finish() } }, typingGap: .zero)
        let text = "  -  [*?] \"CAFE\u{301}\"\tบันทึก  "
        let request = Search.Request(text: text)
        var last: Search.Batch?
        for await batch in search.search(request) { last = batch }
        #expect(last?.results == [literal])
        #expect(request.text == text)
        // Equal comparison names tie by stable destination, not input order.
        let a = app("Notes Pro", "/Applications/Z.app")
        let z = app("NOTES\tPRO", "/Applications/A.app")
        let ties = Search(source: { AsyncStream { $0.yield(.init(results: [z, a], status: .ready)); $0.finish() } }, typingGap: .zero)
        for await batch in ties.search(.init(text: "notes pro")) { last = batch }
        #expect(last?.results.map(\.id) == [z.id, a.id])
    }

    @Test func equalClosenessUsesStableIdentityRatherThanSourceOrDisplayOrder() async {
        let first = app("App Z", "/Applications/A.app")
        let second = app("App A", "/Applications/Z.app")
        for values in [[second, first], [first, second]] {
            let search = Search(source: { AsyncStream { $0.yield(.init(results: values, status: .ready)); $0.finish() } }, typingGap: .zero)
            var last: Search.Batch?
            for await batch in search.search(.init(text: "app")) { last = batch }
            #expect(last?.results == [first, second])
        }
    }

    @Test func largeMixedCandidatesRetainLateStrongMatchesAfterExclusionsAndDuplicates() async {
        let exact = app("[*]", "/Applications/exact.app")
        let prefix = SearchResult(name: "[*] file", url: URL(fileURLWithPath: "/fixture/prefix.txt"), kind: .file)
        let hidden = app("[*]", "/fixture/.hidden/excluded.app")
        let weak = (0..<6_000).map { app("Weak \($0) [*]", "/fixture/\($0).app") }
        let values = Array(repeating: hidden, count: 3_000) + weak + Array(repeating: weak[0], count: 3_000) + [prefix, exact]
        let search = Search(source: { AsyncStream { $0.yield(.init(results: values, status: .ready)); $0.finish() } }, typingGap: .zero)
        for _ in 0..<100 { search.recordOpened(weak[0].id) }
        var last: Search.Batch?
        for await batch in search.search(.init(text: "[*]")) { last = batch }
        #expect(last?.results.count == 20)
        #expect(last?.results.prefix(2).map(\.id) == [exact.id, prefix.id])
        #expect(Set(last?.results.map(\.id) ?? []).count == 20)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HANA_BOUNDED_FIXTURE"] != nil))
    func indexedLiteralExactSurvivesMoreThanTwoThousandBroadFalsePositives() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["HANA_BOUNDED_FIXTURE"])
        let fixture = URL(fileURLWithPath: path)
        let search = Search(roots: [], indexedFiles: true, typingGap: .zero)
        var found = false
        for await batch in search.search(.init(text: fixture.lastPathComponent)) {
            if batch.results.contains(where: { $0.url == fixture }) { found = true; break }
            if batch.fileStatus == .ready || batch.fileStatus == .failed || batch.fileStatus == .partial { break }
        }
        #expect(found)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HANA_BOUNDED_FIXTURE"] != nil))
    func indexedCompactionRetainsASuccessfulUsageWinnerBeyondItsCandidateCap() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["HANA_BOUNDED_FIXTURE"])).deletingLastPathComponent()
        let chosen = root.appendingPathComponent("Usage/0299/Hana7Use.txt")
        let search = Search(roots: [], indexedFiles: true, typingGap: .zero)
        search.recordOpened(.init(destination: chosen))
        var last: Search.Batch?
        for await batch in search.search(.init(text: "Hana7Use.txt")) {
            last = batch
            if batch.fileStatus == .ready || batch.fileStatus == .partial || batch.fileStatus == .failed { break }
        }
        #expect(last?.results.first?.url == chosen)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HANA_BOUNDED_FIXTURE"] != nil))
    func indexedReplacementScanNeverTemporarilyRemovesAStillExistingLateMatch() async throws {
        let fixture = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["HANA_BOUNDED_FIXTURE"]))
        let search = Search(roots: [], indexedFiles: true, typingGap: .zero)
        var iterator = search.search(.init(text: fixture.lastPathComponent)).makeAsyncIterator()
        while let batch = await iterator.next() {
            if batch.fileStatus == .ready { #expect(batch.results.contains { $0.url == fixture }); break }
        }
        let addition = fixture.deletingLastPathComponent().appendingPathComponent("[ 0000 Hana7 new *].txt")
        try Data("Synthetic update fixture".utf8).write(to: addition)
        defer { try? FileManager.default.removeItem(at: addition) }
        try await Task.detached {
            let importer = Process()
            importer.executableURL = URL(fileURLWithPath: "/usr/bin/mdimport")
            importer.arguments = [addition.path]
            try importer.run(); importer.waitUntilExit()
        }.value
        // Every batch during replacement must retain the still-existing exact
        // identity; Mac Interaction would otherwise invalidate its selection.
        var observedUpdate = false
        while let batch = await iterator.next() {
            observedUpdate = true
            #expect(batch.results.contains { $0.url == fixture })
            if batch.fileStatus == .ready { break }
        }
        #expect(observedUpdate)
    }

    @Test func lateFileFailureAndRecoveryLeaveCatalogUsefulAndDeduplicateRecovery() async throws {
        let files = CatalogFeed()
        let application = app("Notes", "/Applications/Notes.app")
        let file = SearchResult(name: "Notes.txt", url: URL(fileURLWithPath: "/fixture/Notes.txt"), kind: .file)
        let search = Search(source: { AsyncStream { $0.yield(.init(results: [application], status: .ready)); $0.finish() } },
                            files: { _ in files.stream() }, typingGap: .zero)
        var iterator = search.search(.init(text: "Notes")).makeAsyncIterator()
        var batch = await iterator.next()
        while batch?.results.isEmpty == true { batch = await iterator.next() }
        await files.send([file], status: .partial)
        while batch?.fileStatus != .partial { batch = await iterator.next() }
        #expect(batch?.results.map(\.id) == [application.id, file.id])
        await files.send([], status: .failed)
        while batch?.fileStatus != .failed { batch = await iterator.next() }
        #expect(batch?.results.map(\.id) == [application.id])
        await files.send([application, file], status: .ready)
        while batch?.fileStatus != .ready { batch = await iterator.next() }
        #expect(batch?.results.map(\.id) == [application.id, file.id])
        for await _ in search.search(.init(text: "")) {}
        try await eventually { files.cancellationCount == 1 }
    }

    @Test func strongerIndexedNameImprovesTierWithoutReplacingCatalogPresentation() async {
        let chosen = SearchResult(name: "Friendly Name", url: URL(fileURLWithPath: "/Applications/Target.app"), alternateNames: ["My Target"])
        let indexed = SearchResult(name: "Target", url: chosen.url)
        let weak = app("Target Extra", "/Applications/Target Extra.app")
        let search = Search(source: { AsyncStream { $0.yield(.init(results: [chosen, weak], status: .ready)); $0.finish() } },
                            files: { _ in AsyncStream { $0.yield(.init(results: [indexed], status: .ready)); $0.finish() } }, typingGap: .zero)
        var last: Search.Batch?
        for await batch in search.search(.init(text: "Target")) { last = batch }
        #expect(last?.results.map(\.name) == ["Friendly Name", "Target Extra"])
    }

    @Test func unmatchedCatalogAliasCannotHideAMatchingMetadataFilename() async {
        let url = URL(fileURLWithPath: "/Applications/Notes.app")
        let catalog = SearchResult(name: "Notes", url: url)
        let indexed = SearchResult(name: "Notes", url: url, alternateNames: ["Notes.app"])
        let search = Search(source: { AsyncStream { $0.yield(.init(results: [catalog], status: .ready)); $0.finish() } },
                            files: { _ in AsyncStream { $0.yield(.init(results: [indexed], status: .ready)); $0.finish() } }, typingGap: .zero)
        var last: Search.Batch?
        for await batch in search.search(.init(text: "Notes.app")) { last = batch }
        #expect(last?.results.map(\.url) == [url])
    }

    @Test func visibleFoldersIncludingAnOrdinaryFolderNamedTrashRemainEligible() async {
        let folder = SearchResult(name: "Notes", url: URL(fileURLWithPath: "/Users/test/Trash/Notes"), kind: .folder)
        let search = Search(source: { AsyncStream { $0.finish() } }, files: { _ in
            AsyncStream { $0.yield(.init(results: [folder], status: .ready)); $0.finish() }
        }, typingGap: .zero)
        var last: Search.Batch?
        for await batch in search.search(.init(text: "notes")) { last = batch }
        #expect(last?.results == [folder])
        #expect(last?.results.first?.typeLabel == "Folder")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HANA_INDEXED_FIXTURE"] != nil))
    func liveIndexedFixtureMatchesLiteralPunctuationThroughSearch() async throws {
        let path = try #require(ProcessInfo.processInfo.environment["HANA_INDEXED_FIXTURE"])
        let fixture = URL(fileURLWithPath: path)
        let search = Search(roots: [], indexedFiles: true, typingGap: .zero)
        // Single-token gathering also guards the native one-child compound
        // predicate exception. Multiword and symbol cases exercise translation.
        for text in [fixture.lastPathComponent, "TextEdit", "ทึก [*]", "[*]", "Hana TextEdit"] {
            // Broad TextEdit can legitimately fill the bounded result list with
            // stronger matches than our long fixture name. Assert its exact app;
            // the specific queries below still require the literal file URL.
            let expected = text == "TextEdit" ? URL(fileURLWithPath: "/System/Applications/TextEdit.app") : fixture
            var found = false
            for await batch in search.search(.init(text: text)) {
                if batch.results.contains(where: { $0.url == expected }) { found = true; break }
                if batch.fileStatus == .ready || batch.fileStatus == .failed { break }
            }
            #expect(found, "Indexed synthetic fixture was not returned for query: \(text)")
        }
    }

    @Test func replacingOrClearingAQueryCancelsFilesAndRejectsTheirLateSnapshots() async throws {
        let old = CatalogFeed(), fresh = CatalogFeed()
        let search = Search(source: { AsyncStream { $0.finish() } }, files: { text in
            text == "old" ? old.stream() : fresh.stream()
        }, typingGap: .zero)
        let obsolete = search.search(.init(text: "old"))
        let consuming = Task { for await _ in obsolete {} }
        try await eventually { old.subscriptionCount == 1 }
        let request = Search.Request(text: "fresh")
        var iterator = search.search(request).makeAsyncIterator()
        await fresh.send([app("fresh", "/Applications/fresh.app")])
        await old.send([app("old", "/Applications/old.app")])
        var batch = await iterator.next()
        while batch?.results.isEmpty == true { batch = await iterator.next() }
        #expect(batch?.generation == request.generation)
        #expect(batch?.results.map(\.name) == ["fresh"])
        await consuming.value
        try await eventually { old.cancellationCount == 1 }
        for await batch in search.search(.init(text: "")) { #expect(batch.results.isEmpty) }
        try await eventually { fresh.cancellationCount == 1 }
    }

    @Test func filesMatchLiteralNamesAndMergeByDestinationBeforeVisibleLimit() async {
        let same = app("Notes", "/Applications/Notes.app")
        let file = SearchResult(name: "Notes [*] บันทึก.txt", url: URL(fileURLWithPath: "/Users/test/Documents/Notes [*] บันทึก.txt"), kind: .file)
        let hidden = SearchResult(name: "Notes [*] บันทึก.txt", url: URL(fileURLWithPath: "/Users/test/.hidden/Notes [*] บันทึก.txt"), kind: .file)
        let privateFile = SearchResult(name: "Notes [*] บันทึก.txt", url: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/com.beamseree.hana/Notes [*] บันทึก.txt"), kind: .file)
        let others = ["/Users/test/.Trash/Notes.txt", "/Applications/X.app/Contents/Notes.txt", "/Users/test/Notes/other.txt"].map {
            SearchResult(name: URL(fileURLWithPath: $0).lastPathComponent, url: URL(fileURLWithPath: $0), kind: .file)
        }
        let metadata = Array(repeating: hidden, count: 40) + [privateFile, same, app("Notes", "/Other/Notes.app"), file] + others
        let search = Search(source: { AsyncStream { $0.yield(.init(results: [same], status: .ready)); $0.finish() } },
                            files: { _ in AsyncStream { $0.yield(.init(results: metadata, status: .ready)); $0.finish() } }, typingGap: .zero)
        var last: Search.Batch?
        for await batch in search.search(.init(text: "notes")) { last = batch }
        #expect(last?.results.map(\.url.path) == ["/Applications/Notes.app", "/Other/Notes.app", file.url.path])
        for await batch in search.search(.init(text: "ทึก [*]")) { last = batch }
        #expect(last?.results == [file])
        #expect(last?.results.first?.typeLabel == "File")
    }

    @Test func mixedSearchKeepsApplicationsUsefulWhileFilesLoadThenFail() async throws {
        let files = AsyncStream<SourceSnapshot>.makeStream()
        let search = Search(source: { AsyncStream { $0.yield(.init(results: [app("Notes", "/Applications/Notes.app")], status: .ready)); $0.finish() } },
                            files: { _ in files.stream }, typingGap: .zero)
        var iterator = search.search(.init(text: "notes")).makeAsyncIterator()
        var batch = await iterator.next()
        while batch?.results.isEmpty == true { batch = await iterator.next() }
        #expect(batch?.results.map(\.name) == ["Notes"])
        #expect(batch?.fileStatus == .loading)
        files.continuation.yield(.init(results: [], status: .failed))
        while batch?.fileStatus != .failed { batch = await iterator.next() }
        #expect(batch?.results.map(\.name) == ["Notes"])
        files.continuation.finish()
    }

    @Test func failedSourceStatusStillDeliversAvailableMatches() async {
        let search = Search(source: { AsyncStream { $0.yield(.init(results: [app("Notes", "/Applications/Notes.app")], status: .failed)); $0.finish() } }, typingGap: .zero)
        for await batch in search.search(.init(text: "notes")) where batch.appStatus != .loading {
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
        let search = Search(roots: [root], typingGap: .zero)
        for await batch in search.search(.init(text: "Google Chrome")) where batch.status != .loading {
            #expect(batch.results.map(\.name) == ["Chrome"])
            break
        }
    }

    @Test func emptyQueriesDoNotConsultASourceAndCancellationFinishesOldStream() async throws {
        var calls = 0
        let feed = CatalogFeed()
        let search = Search(source: { calls += 1; return feed.stream() }, typingGap: .zero)
        for await batch in search.search(.init(text: "  ")) { #expect(batch.results.isEmpty) }
        #expect(calls == 0)
        let stream = search.search(.init(text: "old"))
        let consume = Task { var count = 0; for await _ in stream { count += 1 }; return count }
        try await eventually { calls == 1 }
        for await batch in search.search(.init(text: "")) { #expect(batch.results.isEmpty) }
        await feed.send([app("old", "/Applications/old.app")])
        #expect(await consume.value == 1) // The initial rechecked (empty) batch only.
    }

    @Test func catalogRefreshesAnActiveQueryAfterInstallationAndRemoval() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let search = Search(roots: [root], typingGap: .zero)
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

    @Test func snapshotsReadByOneBatchAreNotRepeatedInTheNext() async throws {
        let apps = CatalogFeed(), files = CatalogFeed()
        let application = app("Notes", "/Applications/Notes.app")
        let file = SearchResult(name: "Notes.txt", url: URL(fileURLWithPath: "/fixture/Notes.txt"), kind: .file)
        let search = Search(source: { apps.stream() }, files: { _ in files.stream() }, typingGap: .zero)
        var iterator = search.search(.init(text: "Notes")).makeAsyncIterator()
        try await eventually { apps.subscriptionCount == 1 && files.subscriptionCount == 1 }
        // Both arrive before the batch loop reads the sources, so one batch
        // already shows both; the second snapshot's signal is still pending.
        await apps.send([application]); await files.send([file])
        var batch = await iterator.next()
        while batch?.status != .ready { batch = await iterator.next() }
        #expect(batch?.results == [application, file])
        await files.send([])
        #expect(await iterator.next()?.results == [application])
    }

    @Test func successfulUseOnlyReordersWithinNameTiersAndDeliveryIsBounded() async {
        let exact = app("App", "/Applications/App.app")
        let preferred = app("App Z", "/Applications/App Z.app")
        let apps = (0..<100).map { app("App \($0)", "/Applications/App \($0).app") } + [preferred, exact]
        let search = Search(source: { AsyncStream { $0.yield(.init(results: apps, status: .ready)); $0.finish() } }, typingGap: .zero)
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
        let search = Search(roots: [root], typingGap: .zero)
        for await batch in search.search(.init(text: "a")) where batch.status != .loading {
            #expect(batch.results.map(\.name) == ["Alpha", "Beta"])
            break
        }
    }

    @Test func literalUnicodeAndAllNameTokensMatchWithoutRewritingInput() async {
        let apps = [app("Notes Pro", "/Applications/Notes Pro.app"), app("บันทึก [*]", "/Applications/Thai.app"), app("Café", "/Applications/Cafe.app")]
        for (query, expected) in [("pro NOTES", "Notes Pro"), ("ทึก [*]", "บันทึก [*]"), ("CAFE\u{301}", "Café")] {
            let search = Search(source: { AsyncStream { $0.yield(.init(results: apps, status: .ready)); $0.finish() } }, typingGap: .zero)
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
        let search = Search(source: { AsyncStream { $0.yield(.init(results: apps, status: .ready)); $0.finish() } }, typingGap: .zero)
        var last: Search.Batch?
        for await batch in search.search(.init(text: "Notes")) { last = batch }
        #expect(last?.results.map(\.url.path) == ["/Applications/Notes.app", "/Users/test/Applications/Notes.app"])
    }

    @Test func exactPrefixAndSubstringHaveDeterministicOrder() async {
        let apps = [app("My Notes", "/Applications/My Notes.app"),
                    app("Notes Pro", "/Applications/Notes Pro.app"),
                    app("Notes", "/Applications/Notes.app")]
        let search = Search(source: { AsyncStream { $0.yield(.init(results: apps, status: .ready)); $0.finish() } }, typingGap: .zero)
        var last: Search.Batch?
        for await batch in search.search(.init(text: "notes")) { last = batch }
        #expect(last?.results.map(\.name) == ["Notes", "Notes Pro", "My Notes"])
    }
}

func app(_ name: String, _ path: String) -> SearchResult {
    SearchResult(name: name, url: URL(fileURLWithPath: path))
}
