import Foundation
import Testing
@testable import Hana

/// Indexed results omit dependency, build and system folders (#56).
@Suite(.timeLimit(.minutes(1)))
@MainActor
struct SearchExclusionTests {
    @Test func dependencyAndBuildFoldersAreExcludedAtAnyDepthByWholeName() async {
        let excluded = ["node_modules", "Pods", "DerivedData", ".build", "target", "vendor", "dist", "NODE_MODULES", "Dist"].flatMap { folder in
            [indexed("/Users/test/Projects/web/\(folder)", kind: .folder),
             indexed("/Users/test/Projects/web/\(folder)/te.js"),
             indexed("/Users/test/Projects/web/\(folder)/deep/locale/te.json")]
        }
        let kept = [indexed("/Users/test/Projects/distance/te.js"), indexed("/Users/test/Projects/targets/te.js"),
                    indexed("/Users/test/Projects/web/te.js")]
        let results = await files(excluded + kept, query: "te")
        #expect(Set(results.map(\.url.path)) == Set(kept.map(\.url.path)))

        // The excluded folders themselves, against names that only contain them.
        let folders = ["dist", "distance", "target", "targets", "Pods", "iPods"].map { indexed("/Users/test/Projects/\($0)", kind: .folder) }
        #expect(await files(folders, query: "dist").map(\.name) == ["distance"])
        #expect(await files(folders, query: "target").map(\.name) == ["targets"])
        #expect(await files(folders, query: "pods").map(\.name) == ["iPods"])
    }

    @Test func systemAndLibraryLocationsAreExcludedExceptICloudDriveAndCloudStorage() async {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let excluded = ["/System/Library/Perl/5.34/unicore/te.pl", "/System/te.txt", "/Library/Application Support/Vendor/te.json",
                        "/Library/te.txt", "\(home)/Library/Application Support/Code/User/History/te.js", "\(home)/Library/te.txt",
                        "\(home)/Library/Mobile Documents/com~apple~CloudDocs/web/node_modules/te.js",
                        "\(home)/Library/CloudStorage/Dropbox/web/Pods/te.json"].map { indexed($0) }
            + [indexed("\(home)/Library/Containers/te", kind: .folder)]
        let kept = ["\(home)/Library/Mobile Documents/com~apple~CloudDocs/Documents/te.txt",
                    "\(home)/Library/CloudStorage/GoogleDrive-test/My Drive/te.pdf", "\(home)/Documents/te.txt",
                    "/Users/Shared/te.txt", "/Volumes/External/Library/te.txt", "/Users/test/System/te.txt"].map { indexed($0) }
        let results = await files(excluded + kept, query: "te")
        #expect(Set(results.map(\.url.path)) == Set(kept.map(\.url.path)))
    }

    @Test func applicationsInConventionalRootsStillAppearFromTheCatalogAndTheIndex() async {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let terminal = app("Terminal", "/System/Applications/Utilities/Terminal.app")
        let textEdit = app("TextEdit", "/System/Applications/TextEdit.app")
        let viewer = app("Text Viewer", "/System/Library/CoreServices/Applications/Text Viewer.app")
        let excluded = [app("Telegram Helper", "\(home)/Library/Application Support/Telegram/Telegram Helper.app"),
                        app("Test Runner", "/Users/test/web/node_modules/electron/dist/Test Runner.app"),
                        app("TestService", "/System/Library/CoreServices/TestService.app")]
        let results = await files([textEdit, viewer] + excluded, apps: [terminal], query: "te")
        #expect(Set(results.map(\.url.path)) == Set([terminal, textEdit, viewer].map(\.url.path)))
    }

    @Test func excludedCandidatesDoNotTakeShortlistPlaces() async {
        // Exact matches outrank the eligible prefix matches; there are more of
        // them than the visible limit and the Spotlight adapter's shortlist.
        let excluded = (0..<300).map { indexed("/Users/test/Projects/p\($0)/node_modules/locale/te.json") }
            + (0..<300).map { indexed("/System/Library/Perl/\($0)/te.pl") }
        let eligible = (0..<5).map { indexed("/Users/test/Documents/temp \($0).txt") }
        let results = await files(excluded + eligible, query: "te")
        #expect(results.map(\.url.path) == eligible.map(\.url.path))
    }

    /// The observed clutter: Spotlight has dozens of files named exactly "te"
    /// plus an extension in these locations. Catalog applications may remain.
    /// The substring stage has hundreds of thousands of candidates, so check
    /// every batch within a budget after the exact and prefix stages publish.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HANA_LIVE_INDEX"] != nil))
    func liveIndexedTeQueryOmitsDependencySystemAndApplicationSupportClutter() async throws {
        let search = Search(roots: ApplicationCatalog.conventionalRoots, indexedFiles: true, debounce: .zero)
        let consumer = Task {
            var batches: [Search.Batch] = []
            for await batch in search.search(.init(text: "te")) {
                batches.append(batch)
                if batch.appStatus != .loading, batch.fileStatus != .loading { break }
            }
            return batches
        }
        let budget = Task { try await Task.sleep(for: .seconds(40)); consumer.cancel() }
        let results = await consumer.value.flatMap(\.results)
        budget.cancel()
        #expect(results.contains { $0.kind != .application }, "No indexed file or folder arrived within the budget")
        let support = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support").path
        for result in results {
            let path = result.url.standardizedFileURL.path
            #expect(!result.url.pathComponents.contains { $0.lowercased() == "node_modules" }, "\(path)")
            #expect(!path.hasPrefix(support + "/"), "\(path)")
            #expect(!path.hasPrefix("/System/") || result.kind == .application, "\(path)")
        }
    }

    private func indexed(_ path: String, kind: SearchResult.Kind = .file) -> SearchResult {
        let url = URL(fileURLWithPath: path, isDirectory: kind != .file)
        return SearchResult(name: url.lastPathComponent, url: url, kind: kind)
    }

    private func files(_ values: [SearchResult], apps: [SearchResult] = [], query: String) async -> [SearchResult] {
        let search = Search(source: { AsyncStream { $0.yield(.init(results: apps, status: .ready)); $0.finish() } },
                            files: { _ in AsyncStream { $0.yield(.init(results: values, status: .ready)); $0.finish() } },
                            debounce: .zero)
        var last: Search.Batch?
        for await batch in search.search(.init(text: query)) { last = batch }
        return last?.results ?? []
    }
}
