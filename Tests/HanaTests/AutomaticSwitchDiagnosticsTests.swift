import Foundation
import Testing
@testable import Hana

struct AutomaticSwitchDiagnosticsTests {
    @Test func optionsDefaultOffAndPersistAcrossStoreInstances() throws {
        let name = "Hana.AutomaticSwitchTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AutomaticSwitchOptionsStore(defaults: defaults)
        #expect(store.read() == AutomaticSwitchOptions())
        #expect(!store.read().isEnabled)
        var options = store.read()
        options.isEnabled = true
        store.write(options)
        #expect(AutomaticSwitchOptionsStore(defaults: defaults).read().isEnabled)
    }
    @Test @MainActor func disabledLoggingCreatesNothingAndEnabledScriptNeverRecordsInput() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("automatic-switch.jsonl")
        let log = AutomaticSwitchDiagnostics(file: url)
        var options = AutomaticSwitchOptions()
        log.record(.missed(mode: .note, lastVerdict: .none), options: options)
        #expect(!FileManager.default.fileExists(atPath: url.path))
        options.isEnabled = true
        var session = CaptureSession()
        let input = "private capture บ้าน unique-secret"
        _ = session.handle(.edited(text: input, selection: NSRange(location: 0, length: 0)))
        _ = session.handle(.chooseSuggestion(.note))
        log.record(.missed(mode: .note, lastVerdict: .none), options: options)
        let recorded = try String(contentsOf: url, encoding: .utf8)
        #expect(recorded.contains("autoswitch.missed"))
        #expect(!recorded.contains(input))
        let rows = try recorded.split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        #expect(rows.count == 1)
        #expect(rows[0]["lastVerdict"] as? String == "none")
        #expect(rows[0]["options"] != nil)
        let directoryMode = try FileManager.default.attributesOfItem(atPath: directory.path)[.posixPermissions] as? Int
        let fileMode = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? Int
        #expect(directoryMode == 0o700 && fileMode == 0o600)
    }
    @Test @MainActor func countsAndPerClassifierLatenciesRebuildFromLogAndResetWithoutDeletingHistory() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("automatic-switch.jsonl")
        let log = AutomaticSwitchDiagnostics(file: url)
        var options = AutomaticSwitchOptions(); options.isEnabled = true
        #expect(log.counts().switches == 0)
        log.record(.switched(mode: .note), options: options)
        log.record(.ended(.saved), options: options)
        log.record(.switched(mode: .task), options: options)
        log.record(.reversed(method: .escape, millisecondsSinceSwitch: 120), options: options)
        log.record(.ended(.reversed), options: options)
        log.record(.switched(mode: .note), options: options)
        log.record(.lateStrongMatch(kind: .application, outcome: .returnedToSearch), options: options)
        log.record(.lateStrongMatch(kind: .file, outcome: .stayed), options: options)
        log.record(.switched(mode: .note), options: options)
        log.record(.ended(.dismissed), options: options)
        log.record(.missed(mode: .task, lastVerdict: .search), options: options)
        for latency in [100.0, 300, 200, 400] {
            log.record(.verdict(.init(classifier: .foundationModels, label: .note,
                latencyMilliseconds: latency, outcome: .switched)), options: options)
        }
        log.record(.verdict(.init(classifier: .jev, label: .none,
            latencyMilliseconds: 50, outcome: .error, errorKind: .network)), options: options)
        log.record(.verdict(.init(classifier: .jev, label: .none,
            latencyMilliseconds: 1500, outcome: .timeout)), options: options)
        let counts = AutomaticSwitchDiagnostics(file: url).counts()
        #expect(counts.switches == 4 && counts.wrongSwitches == 2 && counts.reversals == 1)
        #expect(counts.ambiguous == 1 && counts.missed == 1 && counts.errors == 1 && counts.timeouts == 1)
        #expect(counts.latencies[.foundationModels]?.medianMilliseconds == 250)
        #expect(counts.latencies[.foundationModels]?.maximumMilliseconds == 400)
        #expect(counts.latencies[.jev]?.medianMilliseconds == 775)
        let before = try Data(contentsOf: url)
        log.resetCounts(options: options)
        #expect(log.counts().switches == 0 && log.counts().latencies.isEmpty)
        #expect(try Data(contentsOf: url).starts(with: before))
        log.record(.missed(mode: .note, lastVerdict: .unsure), options: options)
        #expect(AutomaticSwitchDiagnostics(file: url).counts().missed == 1)
    }

    @Test func storedPipelineChoiceMigratesToWordPaced() throws {
        let name = "Hana.AutomaticSwitchTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var legacy = AutomaticSwitchOptions(); legacy.isEnabled = true; legacy.classifier = .jev
        legacy.firing = .wordPaced; legacy.jevThreshold = .p90
        let encoded = try #require(String(data: JSONEncoder().encode(legacy), encoding: .utf8))
        let stored = encoded.replacingOccurrences(of: "\"wordPaced\"", with: "\"pipelinedJev\"")
        #expect(stored.contains("pipelinedJev"))
        defaults.set(Data(stored.utf8), forKey: "automaticSwitch.prototype.options.v1")
        let store = AutomaticSwitchOptionsStore(defaults: defaults)
        // The rest of the snapshot survives; it is not reset to defaults.
        #expect(store.read() == legacy)
        store.write(store.read())
        let rewritten = try #require(defaults.data(forKey: "automaticSwitch.prototype.options.v1"))
        #expect(!String(decoding: rewritten, as: UTF8.self).contains("pipelinedJev"))
    }

    @Test @MainActor func sessionRowCountsRequestsAndLegacyPipelineRowsStillCount() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("automatic-switch.jsonl")
        let log = AutomaticSwitchDiagnostics(file: url)
        var options = AutomaticSwitchOptions(); options.isEnabled = true
        options.classifier = .jev; options.firing = .wordPaced
        log.record(.switched(mode: .task), options: options)
        // A row written by the pipeline build still decodes after migration.
        let current = try String(contentsOf: url, encoding: .utf8)
        try (current + current.replacingOccurrences(of: "\"wordPaced\"", with: "\"pipelinedJev\""))
            .write(to: url, atomically: true, encoding: .utf8)
        log.record(.session(requestsSent: 4), options: options)
        #expect(log.counts().switches == 2)
        let rows = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        let session = try #require(rows.last)
        #expect(session["event"] as? String == "autoswitch.session" && session["requestsSent"] as? Int == 4)
        #expect(session["latencyMilliseconds"] == nil)
    }

    @Test @MainActor func cancelledRequestsOfEveryStrategyAddNoLatencySample() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = AutomaticSwitchDiagnostics(file: directory.appendingPathComponent("automatic-switch.jsonl"))
        let clock = TestClock()
        var options = AutomaticSwitchOptions(); options.isEnabled = true; options.firing = .everyKeystroke
        var policy = AutomaticSwitch(options: options, now: { clock.now.offset })
        func record(_ effects: [AutomaticSwitch.Effect]) {
            for effect in effects { if case .record(let event) = effect { log.record(event, options: options) } }
        }
        _ = policy.handle(.invoked)
        _ = policy.handle(.gateChanged(.init(decision: .allowed, settled: true, allSourcesSettled: true)))
        let first = policy.handle(.bufferChanged(text: "buy milk", composing: false))
        let id = try #require(first.compactMap { if case .classify(let id, _) = $0 { id } else { nil } }.first)
        record(policy.handle(.bufferChanged(text: "buy milk tomorrow", composing: false)))
        record(policy.handle(.failed(id: id, .other, latencyMilliseconds: 70)))
        record(policy.handle(.dismissed(.dismissed)))
        #expect(log.counts().latencies.isEmpty)
        let text = try String(contentsOf: log.url, encoding: .utf8)
        #expect(text.contains("\"stale\"") && text.contains("autoswitch.session") && !text.contains("buy milk"))
    }
}
