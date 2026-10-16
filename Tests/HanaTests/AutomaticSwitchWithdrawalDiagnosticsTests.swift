import Foundation
import Testing
@testable import Hana

@Suite @MainActor
struct AutomaticSwitchWithdrawalDiagnosticsTests {
    @Test func withdrawnReturnsAndReversalsRemainDistinctAlongsideHistoricalRows() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = AutomaticSwitchDiagnostics(file: directory.appendingPathComponent("automatic-switch.jsonl"))
        var options = AutomaticSwitchOptions()
        options.isEnabled = true; options.classifier = .jev; options.firing = .wordPaced
        log.record(.switched(mode: .task), options: options)
        // Preserve a row from a build before the new reversal choice existed.
        let first = try Data(contentsOf: log.url)
        var historical = try #require(JSONSerialization.jsonObject(with: first) as? [String: Any])
        var oldOptions = try #require(historical["options"] as? [String: Any])
        oldOptions["reversalBehavior"] = nil; oldOptions["firing"] = "pipelinedJev"
        historical["options"] = oldOptions
        var contents = try JSONSerialization.data(withJSONObject: historical)
        contents.append(10)
        try contents.write(to: log.url)
        log.record(.withdrawn(mode: .task), options: options)
        log.record(.ended(.withdrawn), options: options)
        log.record(.switched(mode: .note), options: options)
        log.record(.reversed(method: .escape, millisecondsSinceSwitch: 100), options: options)
        log.record(.ended(.reversed), options: options)
        let counts = AutomaticSwitchDiagnostics(file: log.url).counts()
        #expect(counts.switches == 2 && counts.withdrawn == 1 && counts.reversals == 1 && counts.wrongSwitches == 1)
        #expect(counts.ambiguous == 0 && counts.latencies.isEmpty)
        let rows = try String(contentsOf: log.url, encoding: .utf8)
        #expect(!rows.contains("call mom") && !rows.contains("บ้าน"))
        let before = try Data(contentsOf: log.url)
        log.resetCounts(options: options)
        #expect(log.counts().withdrawn == 0 && log.counts().reversals == 0 && log.counts().wrongSwitches == 0)
        #expect(try Data(contentsOf: log.url).starts(with: before))
    }
}
