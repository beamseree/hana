import Foundation
import Testing
@testable import Hana

struct StrongMatchGateTests {
    @Test(arguments: ["12 * 4", "12 *", "(3 + 4", "sqrt", "1 / 0", "sqrt(-1)", "9^9^9", "3 + * 4", "1..2"])
    func everyRecognizedCalculationBlocksBeforeOtherReasons(_ buffer: String) {
        let match = SearchResult(name: buffer, url: URL(fileURLWithPath: "/fixture/calculation"), kind: .application)
        let evaluation = StrongMatchGate.evaluate(rawBuffer: buffer, results: [match], appStatus: .ready,
            fileStatus: .ready, titles: .init(status: .unavailable))
        #expect(evaluation.decision == .blocked(.calculation))
        #expect(!evaluation.settled && !evaluation.allSourcesSettled)
    }

    @Test func anOrdinaryWordRestoresTheExistingGateRules() {
        let buffer = "rent 1200 / 3"
        #expect(StrongMatchGate.evaluate(rawBuffer: buffer, results: [], appStatus: .ready,
            fileStatus: .ready, titles: .init(status: .ready)).decision == .allowed)
        let match = SearchResult(name: buffer, url: URL(fileURLWithPath: "/fixture/Rent.app"), kind: .application)
        #expect(StrongMatchGate.evaluate(rawBuffer: buffer, results: [match], appStatus: .ready,
            fileStatus: .ready, titles: .init(status: .ready)).decision == .blocked(.strongMatch(.application)))
        #expect(StrongMatchGate.evaluate(rawBuffer: buffer, results: [], appStatus: .ready,
            fileStatus: .ready, titles: .init(status: .unavailable)).decision == .blocked(.collectionUnavailable))
    }

    struct MatchCase: Sendable {
        let buffer: String
        let name: String
        let kind: StrongMatchGate.Kind
        let blocks: Bool
    }

    @Test(arguments: [
        MatchCase(buffer: "Visual Studio", name: "Visual Studio", kind: .application, blocks: true),
        MatchCase(buffer: "visual st", name: "Visual Studio", kind: .application, blocks: true),
        MatchCase(buffer: "Studio ", name: "Visual Studio", kind: .application, blocks: false),
        MatchCase(buffer: "isual st", name: "Visual Studio", kind: .application, blocks: false),
        MatchCase(buffer: "Budget plan", name: "Budget plan", kind: .note, blocks: true),
        MatchCase(buffer: "Budget p", name: "Budget plan", kind: .note, blocks: true),
        MatchCase(buffer: "plan ", name: "Budget plan", kind: .note, blocks: false),
        MatchCase(buffer: "udget p", name: "Budget plan", kind: .note, blocks: false),
        MatchCase(buffer: "Call mom", name: "Call mom", kind: .task, blocks: true),
        MatchCase(buffer: "Call m", name: "Call mom", kind: .task, blocks: true),
        MatchCase(buffer: "mom ", name: "Call mom", kind: .task, blocks: false),
        MatchCase(buffer: "all m", name: "Call mom", kind: .task, blocks: false),
        MatchCase(buffer: "budget ", name: "budget.xlsx", kind: .file, blocks: true),
        MatchCase(buffer: "budget.xlsx ", name: "budget.xlsx", kind: .file, blocks: true),
        MatchCase(buffer: "budget p", name: "budget plan.xlsx", kind: .file, blocks: false),
        MatchCase(buffer: "plan ", name: "budget plan.xlsx", kind: .file, blocks: false),
        MatchCase(buffer: "udget p", name: "budget plan.xlsx", kind: .file, blocks: false),
        MatchCase(buffer: "xlsx ", name: "budget.xlsx", kind: .file, blocks: false)
    ])
    func onlyStrongNameTiersBlock(_ item: MatchCase) {
        var titles = StrongMatchGate.Titles(status: .ready)
        var results: [SearchResult] = []
        switch item.kind {
        case .note: titles.notes = [SearchName(item.name)]
        case .task: titles.tasks = [SearchName(item.name)]
        case .application, .file:
            results = [.init(name: item.name, url: URL(fileURLWithPath: "/fixture/\(item.name)"),
                             kind: item.kind == .application ? .application : .file)]
        }
        let evaluation = StrongMatchGate.evaluate(rawBuffer: item.buffer, results: results, appStatus: .ready,
            fileStatus: .ready, titles: titles)
        #expect(evaluation.decision == (item.blocks ? .blocked(.strongMatch(item.kind)) : .allowed))
    }

    @Test(arguments: [
        ("remind", false), ("remind ", true), ("  remind", false),
        ("\t remind\t", true), ("call mom", true), (" \n", false)
    ])
    func rawBufferKeepsTrailingWhitespaceSignificant(buffer: String, allowed: Bool) {
        let evaluation = StrongMatchGate.evaluate(rawBuffer: buffer, results: [], appStatus: .ready,
            fileStatus: .ready, titles: .init(status: .ready))
        #expect(evaluation.decision == (allowed ? .allowed : .blocked(.oneWord)))
    }

    @Test(arguments: ["remind", "remind ", "Visual Studio"])
    func unavailableCollectionAlwaysBlocks(_ buffer: String) {
        let evaluation = StrongMatchGate.evaluate(rawBuffer: buffer, results: [], appStatus: .ready,
            fileStatus: .ready, titles: .init(status: .unavailable))
        #expect(evaluation.decision == .blocked(.collectionUnavailable))
        #expect(!evaluation.settled && !evaluation.allSourcesSettled)
    }

    @Test(arguments: [
        (SourceStatus.loading, StrongMatchGate.Titles.Status.ready, SourceStatus.ready, false, false),
        (.partial, .ready, .ready, false, false), (.ready, .loading, .ready, false, false),
        (.ready, .ready, .loading, true, false), (.ready, .ready, .partial, true, false),
        (.ready, .ready, .ready, true, true), (.failed, .ready, .failed, true, true)
    ])
    func sourceReadinessIsSeparateFromPermission(app: SourceStatus, titles: StrongMatchGate.Titles.Status,
                                                files: SourceStatus, settled: Bool, allSettled: Bool) {
        let evaluation = StrongMatchGate.evaluate(rawBuffer: "call mom", results: [], appStatus: app,
            fileStatus: files, titles: .init(status: titles))
        #expect(evaluation.settled == settled)
        #expect(evaluation.allSourcesSettled == allSettled)
    }

    @Test func aliasesAndExactFolderNamesBlock() {
        let app = SearchResult(name: "Different name", url: URL(fileURLWithPath: "/fixture/app"),
                               alternateNames: ["Visual Studio"], kind: .application)
        let folder = SearchResult(name: "Budget plan", url: URL(fileURLWithPath: "/fixture/folder"), kind: .folder)
        #expect(StrongMatchGate.evaluate(rawBuffer: "visual st", results: [app], appStatus: .ready,
            fileStatus: .ready, titles: .init(status: .ready)).decision == .blocked(.strongMatch(.application)))
        #expect(StrongMatchGate.evaluate(rawBuffer: "Budget plan", results: [folder], appStatus: .ready,
            fileStatus: .ready, titles: .init(status: .ready)).decision == .blocked(.strongMatch(.file)))
        #expect(StrongMatchGate.evaluate(rawBuffer: "Budget p", results: [folder], appStatus: .ready,
            fileStatus: .ready, titles: .init(status: .ready)).decision == .allowed)
    }
}
