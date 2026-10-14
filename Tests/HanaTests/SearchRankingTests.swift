import Foundation
import Testing
@testable import Hana

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct SearchRankingTests {
    @Test func wordStartsBeatShorterMidwordMatches() async {
        let visual = app("Visual Studio Code", "/Applications/Visual Studio Code.app")
        let xcode = app("Xcode", "/Applications/Xcode.app")
        #expect(await results("code", [xcode, visual]) == [visual, xcode])
    }

    @Test func extensionsAreFallbackMatchesAndKindsBreakEqualTiers() async {
        let expert = app("PDF Expert Professional", "/Applications/PDF Expert.app")
        let guide = item("pdf-guide.txt")
        let taxes = item("Taxes.pdf")
        let midword = item("Xpdf.txt")
        #expect(await results("pdf", [taxes, guide, expert, midword]) == [expert, guide, midword, taxes])

        let safari = app("Safari", "/Applications/Safari.app")
        let folder = SearchResult(name: "Safari", url: URL(fileURLWithPath: "/000/Safari"), kind: .folder)
        let file = item("Safari.png")
        #expect(await results("safari", [file, folder, safari]) == [safari, folder, file])
        // A prefix application name beats an exact file name (#55).
        let exact = item("PDF.txt")
        #expect(await results("pdf", [exact, expert]) == [expert, exact])
    }

    @Test func applicationsMatchingByNameOrWordStartPrecedeExactFiles() async {
        let telegram = app("Telegram", "/Applications/Telegram.app")
        let terminal = app("Terminal", "/Applications/Utilities/Terminal.app")
        let textEdit = app("TextEdit", "/Applications/TextEdit.app")
        let js = item("te.js"), json = item("te.json")
        // Equal prefix closeness falls through to the path tie-break.
        #expect(await results("te", [js, json, textEdit, terminal, telegram]) == [telegram, textEdit, terminal, js, json])

        // No Visual Studio Code alias is an exact or prefix match for "code".
        let visual = app("Visual Studio Code", "/Applications/Visual Studio Code.app")
        let text = item("code.txt")
        #expect(await results("code", [text, visual]) == [visual, text])
        let runner = app("Code Runner", "/Applications/Code Runner.app")
        #expect(await results("code", [text, visual, runner]) == [runner, visual, text])
    }

    @Test func promotedApplicationsKeepTheirOwnOrderAboveFoldersThenFiles() async {
        let notes = app("Notes", "/Applications/Notes.app")
        let pro = app("Notes Pro", "/Applications/Notes Pro.app")
        let sticky = app("Sticky Notes", "/Applications/Sticky Notes.app")
        let folder = SearchResult(name: "Notes", url: URL(fileURLWithPath: "/000/Notes"), kind: .folder)
        let file = item("notes.txt")
        // The folder and file share a kind slot; their existing path tie-break decides.
        #expect(await results("notes", [file, folder, sticky, pro, notes]) == [notes, pro, sticky, folder, file])
    }

    @Test func substringApplicationsAndUnmatchedApplicationsAreNotPromoted() async {
        let safari = app("Safari", "/Applications/Safari.app")
        let far = item("far.txt")
        #expect(await results("far", [safari, far]) == [far, safari])
        let reporter = app("Reporter", "/Applications/Reporter.app")
        let report = item("report.pdf")
        #expect(await results("report.pdf", [reporter, report]).first == report)
    }

    @Test func adapterShortlistKeepsPromotedApplicationsAheadOfExactCandidatesUnderItsLimit() async {
        let exact = (0..<50).map { SearchResult(name: "te", url: URL(fileURLWithPath: "/000/\($0)/te"), kind: .folder) }
            + (0..<50).map { SearchResult(name: "te.js", url: URL(fileURLWithPath: "/000/\($0)/te.js"), kind: .file) }
        let terminal = app("Terminal", "/Applications/Utilities/Terminal.app")
        let shortlist = await Search.compactCandidates(exact + [terminal], query: "te", limit: 10)
        #expect(shortlist.count == 10)
        #expect(shortlist.first == terminal)
    }

    private func item(_ name: String, kind: SearchResult.Kind = .file) -> SearchResult {
        SearchResult(name: name, url: URL(fileURLWithPath: "/fixture/" + name), kind: kind)
    }

    @Test func wordOrderWinsBeforeUsageAndPathOnlyAfterCloseness() async {
        let ordered = app("My Studio Code", "/Applications/Z.app")
        let reversed = app("My Code Studio", "/Applications/A.app")
        let shorter = app("Code Studio", "/Applications/B.app")
        #expect(await results("studio code", [reversed, ordered, shorter], opened: [reversed]) == [shorter, ordered, reversed])
    }

    @Test(arguments: [
        ("studio code", "Visual Studio Code", "xstudio xcode"),
        ("code studio", "Visual Studio Code", "xcode xstudio"),
        ("point", "PowerPoint", "Checkpoint"),
        ("time", "FaceTime", "Overtime"),
        ("udio", "Another udio tool", "Visual Studio Code"),
        ("ภาษา", "บันทึกภาษาไทย", "เอกสารยาวมาก ภาษา"),
        ("ทึก", "เอกสาร ทึก สรุป", "บันทึก"),
        // The system groups ภาษาไทย as one word on this OS. Even when the
        // intended word ไทย has no tokenizer boundary, substring fallback works.
        ("ไทย", "เอกสาร ไทย มากมาย", "ภาษาไทย"),
        ("studio", "Android Studio", "Visual Studio Code")
    ])
    func languageAwareWordStartsAndSubstringFallback(query: String, first: String, second: String) async {
        let winner = app(first, "/Applications/Z.app")
        let other = app(second, "/Applications/A.app")
        #expect(await results(query, [other, winner]) == [winner, other])
    }

    @Test func fullFilenamesAndUnrecognizedDottedSuffixesRemainLiteral() async {
        let report = item("report.pdf")
        let longer = item("report.pdf copy.txt")
        #expect(await results("report.pdf", [longer, report]) == [report, longer])
        let version = item("Meeting notes 10.14")
        let versionFolder = SearchResult(name: version.name, url: URL(fileURLWithPath: "/z/" + version.name), kind: .folder)
        #expect(await results("14", [versionFolder, version]) == [version, versionFolder])
        #expect(await results("Meeting notes 10.14", [version]) == [version])
        let folder = SearchResult(name: "Taxes.pdf", url: URL(fileURLWithPath: "/folders/Taxes.pdf"), kind: .folder)
        let application = app("Taxes.pdf", "/Applications/Taxes.pdf.app")
        let file = item("Taxes.pdf")
        #expect(await results("pdf", [file, folder, application]) == [application, folder, file])
    }

    @Test func fileClosenessIgnoresDeclaredExtensionAndFilesShareFolderRank() async {
        let file = item("My Report.jpeg")
        let folder = item("Our Report", kind: .folder)
        #expect(await results("report", [folder, file]) == [file, folder])
        let equalFolder = SearchResult(name: "My Report", url: URL(fileURLWithPath: "/000/My Report"), kind: .folder)
        #expect(await results("report", [equalFolder, file], opened: [file]) == [file, equalFolder])
        #expect(await results("report", [file, equalFolder]) == [equalFolder, file])
        let fullFilenameFolder = SearchResult(name: file.name, url: URL(fileURLWithPath: "/000/" + file.name), kind: .folder)
        #expect(await results(file.name, [fullFilenameFolder, file]) == [file, fullFilenameFolder])
    }

    @Test func usageCannotCrossTierKindClosenessOrWordOrderAndTiesAreStable() async {
        let exact = app("Code", "/Applications/Exact.app")
        let first = app("My Code", "/Applications/A.app")
        let second = app("My Code", "/Applications/B.app")
        let midword = app("Xcode", "/Applications/Weak.app")
        let opened = Array(repeating: midword, count: 12) + Array(repeating: first, count: 12) + [second]
        #expect(await results("code", [midword, second, first, exact], opened: opened) == [exact, second, first, midword])
        #expect(await results("code", [midword, second, first, exact]) == [exact, first, second, midword])
        #expect(await results("code", [first, exact, second, midword]) == [exact, first, second, midword])
    }

    @Test func catalogMatchesDisplayBundleAndInstallationNames() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let contents = root.appendingPathComponent("Visual Studio Code.app/Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let info = try PropertyListSerialization.data(fromPropertyList:
            ["CFBundleDisplayName": "Friendly Editor", "CFBundleName": "PowerPoint"], format: .xml, options: 0)
        try info.write(to: contents.appendingPathComponent("Info.plist"))
        let search = Search(roots: [root], debounce: .zero)
        for query in ["friendly", "point", "code studio"] {
            for await batch in search.search(.init(text: query)) where batch.appStatus != .loading {
                #expect(batch.results.map(\.name) == ["Friendly Editor"])
                break
            }
        }
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["HANA_RANKING_FIXTURE"] != nil))
    func indexedShortlistKeepsWordStartsAheadOfMidwordAndExtensionOnlyMatches() async throws {
        let root = URL(fileURLWithPath: try #require(ProcessInfo.processInfo.environment["HANA_RANKING_FIXTURE"]))
        let search = Search(roots: [], indexedFiles: true, debounce: .zero)
        var last: Search.Batch?
        for await batch in search.search(.init(text: "aifc")) {
            last = batch
            if batch.fileStatus != .loading { break }
        }
        let batch = try #require(last)
        #expect(batch.fileStatus != .failed)
        let paths = batch.results.map(\.url)
        let expected = ["aifc.txt", "aifc-guide.txt", "zzzz aifc best.txt"].map { root.appendingPathComponent($0) }
        #expect(paths.filter { expected.contains($0) } == expected, "Visible paths: \(paths.map(\.path))")
        #expect(batch.results.count <= 20)
    }

    private func results(_ text: String, _ candidates: [SearchResult], opened: [SearchResult] = []) async -> [SearchResult] {
        let search = Search(source: {
            AsyncStream { $0.yield(.init(results: candidates.filter { $0.kind == .application }, status: .ready)); $0.finish() }
        }, files: { _ in
            AsyncStream { $0.yield(.init(results: candidates.filter { $0.kind != .application }, status: .ready)); $0.finish() }
        }, debounce: .zero)
        for result in opened { search.recordOpened(result.id) }
        var results: [SearchResult] = []
        for await batch in search.search(.init(text: text)) { results = batch.results }
        return results
    }
}
