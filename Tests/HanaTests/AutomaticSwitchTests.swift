import Foundation
import Testing
@testable import Hana

@Suite @MainActor
struct AutomaticSwitchTests {
    @Test func debounceClassifiesTheUnchangedBufferAfter150Milliseconds() {
        let clock = TestClock()
        var options = AutomaticSwitchOptions(); options.isEnabled = true
        var policy = AutomaticSwitch(options: options, now: { clock.now.offset })
        _ = policy.handle(.invoked)
        _ = policy.handle(.gateChanged(.init(decision: .allowed, settled: true, allSourcesSettled: true)))
        #expect(requests(policy.handle(.bufferChanged(text: "call mom", composing: false))).isEmpty)
        clock.advance(by: .milliseconds(149))
        #expect(requests(policy.handle(.tick)).isEmpty)
        clock.advance(by: .milliseconds(1))
        #expect(requests(policy.handle(.tick)).map(\.text) == ["call mom"])
    }

    @Test func lateStrongMatchWaitsUntilCompositionEndsBeforeRecordingAReturn() throws {
        var h = Harness { $0.lateStrongMatch = .returnToSearch }
        let id = try #require(requests(h.policy.handle(.bufferChanged(text: "call mom", composing: false))).first?.id)
        #expect(modes(h.policy.handle(.verdict(id: id, .init(label: .note), latencyMilliseconds: 12))) == [.note])
        _ = h.policy.handle(.bufferChanged(text: "call mom", composing: true))
        let match = StrongMatchGate.Evaluation(decision: .blocked(.strongMatch(.note)), settled: true, allSourcesSettled: true)
        let deferred = h.policy.handle(.gateChanged(match))
        #expect(!returns(deferred))
        #expect(lateOutcomes(deferred).isEmpty)
        _ = h.policy.handle(.bufferChanged(text: "call mom", composing: false))
        let completed = h.policy.handle(.gateChanged(match))
        #expect(returns(completed))
        #expect(lateOutcomes(completed) == [.returnedToSearch])
    }

    @Test(arguments: [AutomaticSwitchDiagnostics.ReversalMethod.escape, .backspace])
    func ineligibleAutomaticCaptureCannotReverseOrCountAsWrong(method: AutomaticSwitchDiagnostics.ReversalMethod) throws {
        var h = Harness()
        let id = try #require(requests(h.policy.handle(.bufferChanged(text: "call mom", composing: false))).first?.id)
        _ = h.policy.handle(.verdict(id: id, .init(label: .note), latencyMilliseconds: 12))
        _ = h.policy.handle(.eligibilityChanged(false))
        #expect(h.policy.handle(.reversed(method)).isEmpty)
        #expect(h.policy.lastModeChangeWasAutomatic)
        let finished = h.policy.handle(.dismissed(.saved))
        #expect(finished.contains { if case .record(.ended(.saved)) = $0 { true } else { false } })
    }

    @Test func responseAtTheTimeoutCannotSwitchBeforeTheNextTick() throws {
        var h = Harness()
        let id = try #require(requests(h.policy.handle(.bufferChanged(text: "call mom", composing: false))).first?.id)
        h.clock.advance(by: .milliseconds(1500))
        let effects = h.policy.handle(.verdict(id: id, .init(label: .task), latencyMilliseconds: 1500))
        #expect(modes(effects).isEmpty)
        #expect(outcomes(effects) == [.timeout])
    }

    @Test(arguments: AutomaticSwitchOptions.Firing.allCases)
    func firingStrategiesRespectTheirDelay(firing: AutomaticSwitchOptions.Firing) throws {
        var h = Harness { $0.firing = firing }
        let initial = h.policy.handle(.bufferChanged(text: "buy milk", composing: false))
        if firing == .everyKeystroke { #expect(requests(initial).map(\.text) == ["buy milk"]); return }
        #expect(requests(initial).isEmpty)
        h.clock.advance(by: firing == .debounced ? .milliseconds(149) : .milliseconds(499))
        #expect(requests(h.policy.handle(.tick)).isEmpty)
        h.clock.advance(by: .milliseconds(1))
        #expect(requests(h.policy.handle(.tick)).map(\.text) == ["buy milk"])
    }

    @Test func changedBufferCancelsAndMakesTheEarlierVerdictStale() throws {
        var h = Harness()
        let first = try #require(requests(h.policy.handle(.bufferChanged(text: "buy milk", composing: false))).first?.id)
        let edited = h.policy.handle(.bufferChanged(text: "buy milk tomorrow", composing: false))
        #expect(edited.contains { if case .cancel(first) = $0 { true } else { false } })
        #expect(requests(edited).map(\.text) == ["buy milk tomorrow"])
        #expect(outcomes(h.policy.handle(.verdict(id: first, .init(label: .task), latencyMilliseconds: 20))) == [.stale])
    }

    @Test func tickAbandonsARequestAtOnePointFiveSecondsAndErrorsKeepSearch() throws {
        var h = Harness()
        let id = try #require(requests(h.policy.handle(.bufferChanged(text: "buy milk", composing: false))).first?.id)
        h.clock.advance(by: .milliseconds(1499))
        #expect(h.policy.handle(.tick).isEmpty)
        h.clock.advance(by: .milliseconds(1))
        #expect(outcomes(h.policy.handle(.tick)) == [.timeout])
        #expect(outcomes(h.policy.handle(.failed(id: id, .network, latencyMilliseconds: 1501))) == [.stale])
        let next = try #require(requests(h.policy.handle(.bufferChanged(text: "buy milk tomorrow", composing: false))).first?.id)
        let error = h.policy.handle(.failed(id: next, .network, latencyMilliseconds: 10))
        #expect(modes(error).isEmpty && outcomes(error) == [.error])
    }

    @Test(arguments: AutomaticSwitchOptions.Threshold.allCases)
    func jevNeedsTheSelectedThreshold(threshold: AutomaticSwitchOptions.Threshold) throws {
        var h = Harness { $0.classifier = .jev; $0.jevThreshold = threshold }
        var id = try #require(requests(h.policy.handle(.bufferChanged(text: "buy milk", composing: false))).first?.id)
        #expect(outcomes(h.policy.handle(.verdict(id: id, .init(label: .task, probabilities: [.task: threshold.rawValue - 0.01]), latencyMilliseconds: 20))) == [.belowThreshold])
        id = try #require(requests(h.policy.handle(.bufferChanged(text: "buy milk tomorrow", composing: false))).first?.id)
        #expect(modes(h.policy.handle(.verdict(id: id, .init(label: .task, probabilities: [.task: threshold.rawValue]), latencyMilliseconds: 20))) == [.task])
    }

    @Test func unsureAndMissingProbabilityNeverSwitchAndAgreementRequiresTwoVerdicts() throws {
        var h = Harness { $0.agreeingVerdicts = .two }
        var id = try #require(requests(h.policy.handle(.bufferChanged(text: "buy milk", composing: false))).first?.id)
        #expect(outcomes(h.policy.handle(.verdict(id: id, .init(label: .unsure), latencyMilliseconds: 10))) == [.unsure])
        id = try #require(requests(h.policy.handle(.bufferChanged(text: "buy milk tomorrow", composing: false))).first?.id)
        #expect(outcomes(h.policy.handle(.verdict(id: id, .init(label: .task), latencyMilliseconds: 10))) == [.awaitingAgreement])
        h.clock.advance(by: .milliseconds(150))
        id = try #require(requests(h.policy.handle(.tick)).first?.id)
        #expect(modes(h.policy.handle(.verdict(id: id, .init(label: .task), latencyMilliseconds: 10))) == [.task])
        var missing = Harness { $0.classifier = .jev }
        id = try #require(requests(missing.policy.handle(.bufferChanged(text: "call mom", composing: false))).first?.id)
        #expect(outcomes(missing.policy.handle(.verdict(id: id, .init(label: .task), latencyMilliseconds: 10))) == [.belowThreshold])
    }

    @Test(arguments: AutomaticSwitchOptions.AfterSwitch.allCases)
    func afterSwitchStaysOrKeepsClassifying(option: AutomaticSwitchOptions.AfterSwitch) throws {
        var h = Harness { $0.afterSwitch = option }
        let first = try #require(requests(h.policy.handle(.bufferChanged(text: "call mom", composing: false))).first?.id)
        _ = h.policy.handle(.verdict(id: first, .init(label: .task), latencyMilliseconds: 10))
        let effects = h.policy.handle(.bufferChanged(text: "a long thought", composing: false))
        if option == .stay { #expect(requests(effects).isEmpty); return }
        let second = try #require(requests(effects).first?.id)
        #expect(modes(h.policy.handle(.verdict(id: second, .init(label: .note), latencyMilliseconds: 10))) == [.note])
        let third = try #require(requests(h.policy.handle(.bufferChanged(text: "find existing thing", composing: false))).first?.id)
        #expect(returns(h.policy.handle(.verdict(id: third, .init(label: .search), latencyMilliseconds: 10))))
    }

    @Test(arguments: [true, false])
    func navigationSuspensionIsAnOption(suspends: Bool) throws {
        var h = Harness { $0.navigationSuspends = suspends }
        _ = h.policy.handle(.navigated)
        #expect(requests(h.policy.handle(.bufferChanged(text: "buy milk", composing: false))).isEmpty == suspends)
    }

    @Test(arguments: [true, false], [AutomaticSwitchDiagnostics.ReversalMethod.escape, .backspace])
    func reversalKeepsSearchAndOptionallySuspends(suspends: Bool, method: AutomaticSwitchDiagnostics.ReversalMethod) throws {
        var h = Harness { $0.reversalSuspends = suspends }
        let id = try #require(requests(h.policy.handle(.bufferChanged(text: "buy milk", composing: false))).first?.id)
        _ = h.policy.handle(.verdict(id: id, .init(label: .task), latencyMilliseconds: 10))
        #expect(returns(h.policy.handle(.reversed(method))))
        #expect(requests(h.policy.handle(.bufferChanged(text: "buy milk tomorrow", composing: false))).isEmpty == suspends)
        #expect(!returns(h.policy.handle(.reversed(.escape))))
    }

    @Test(arguments: AutomaticSwitchOptions.EnterBehavior.allCases)
    func enterGraceEndsAt300Milliseconds(option: AutomaticSwitchOptions.EnterBehavior) throws {
        var h = Harness { $0.enterBehavior = option }
        let id = try #require(requests(h.policy.handle(.bufferChanged(text: "buy milk", composing: false))).first?.id)
        _ = h.policy.handle(.verdict(id: id, .init(label: .task), latencyMilliseconds: 10))
        #expect(h.policy.handle(.enter).isEmpty == (option == .saves))
        h.clock.advance(by: .milliseconds(300))
        #expect(h.policy.handle(.enter).isEmpty)
    }

    @Test(arguments: AutomaticSwitchOptions.Wait.allCases)
    func waitsForTheChosenSourcesAndAllSourcesHasAHardCap(wait: AutomaticSwitchOptions.Wait) throws {
        var h = Harness { $0.wait = wait }
        _ = h.policy.handle(.gateChanged(.init(decision: .allowed, settled: false, allSourcesSettled: false)))
        let id = try #require(requests(h.policy.handle(.bufferChanged(text: "buy milk", composing: false))).first?.id)
        let effects = h.policy.handle(.verdict(id: id, .init(label: .task), latencyMilliseconds: 10))
        if wait == .none { #expect(modes(effects) == [.task]); return }
        #expect(modes(effects).isEmpty)
        let apps = h.policy.handle(.gateChanged(.init(decision: .allowed, settled: true, allSourcesSettled: false)))
        if wait == .appsAndCollection { #expect(modes(apps) == [.task]); return }
        #expect(modes(apps).isEmpty)
        h.clock.advance(by: .milliseconds(999))
        #expect(modes(h.policy.handle(.tick)).isEmpty)
        h.clock.advance(by: .milliseconds(1))
        #expect(modes(h.policy.handle(.tick)) == [.task])
    }

    @Test(arguments: AutomaticSwitchOptions.LateStrongMatch.allCases)
    func lateMatchStaysOrReturnsAndRecordsExactlyOneOutcome(option: AutomaticSwitchOptions.LateStrongMatch) throws {
        var h = Harness { $0.lateStrongMatch = option }
        let id = try #require(requests(h.policy.handle(.bufferChanged(text: "buy milk", composing: false))).first?.id)
        _ = h.policy.handle(.verdict(id: id, .init(label: .task), latencyMilliseconds: 10))
        let gate = StrongMatchGate.Evaluation(decision: .blocked(.strongMatch(.file)), settled: true, allSourcesSettled: true)
        let effects = h.policy.handle(.gateChanged(gate))
        #expect(returns(effects) == (option == .returnToSearch))
        #expect(lateOutcomes(effects) == [option == .stay ? .stayed : .returnedToSearch])
        #expect(lateOutcomes(h.policy.handle(.gateChanged(gate))).isEmpty)
    }

    @Test func compositionAndCurrentGateBlockAndTaskRefusesMultiline() throws {
        var h = Harness()
        #expect(requests(h.policy.handle(.bufferChanged(text: "buy milk", composing: true))).isEmpty)
        let id = try #require(requests(h.policy.handle(.bufferChanged(text: "buy milk", composing: false))).first?.id)
        let blocked = h.policy.handle(.bufferChanged(text: "existing note", composing: false,
            gate: .init(decision: .blocked(.strongMatch(.note)), settled: true, allSourcesSettled: true)))
        #expect(requests(blocked).isEmpty && outcomes(blocked) == [.blocked])
        #expect(outcomes(h.policy.handle(.verdict(id: id, .init(label: .task), latencyMilliseconds: 10))) == [.stale])
        let multiline = try #require(requests(h.policy.handle(.bufferChanged(text: "a thought\nwith lines", composing: false,
            gate: .init(decision: .allowed, settled: true, allSourcesSettled: true)))).first?.id)
        #expect(outcomes(h.policy.handle(.verdict(id: multiline, .init(label: .task), latencyMilliseconds: 10))) == [.multiline])
    }

    @Test func disabledAndIneligibleSessionsNeverSwitch() throws {
        let clock = TestClock()
        var disabled = AutomaticSwitch(options: AutomaticSwitchOptions(), now: { clock.now.offset })
        #expect(disabled.handle(.invoked).isEmpty)
        #expect(disabled.handle(.bufferChanged(text: "buy milk", composing: false)).isEmpty)
        var h = Harness()
        let id = try #require(requests(h.policy.handle(.bufferChanged(text: "buy milk", composing: false))).first?.id)
        _ = h.policy.handle(.eligibilityChanged(false))
        #expect(modes(h.policy.handle(.verdict(id: id, .init(label: .task), latencyMilliseconds: 10))).isEmpty)
    }

    @Test func collectionBecomingAvailableCanClassifyWithoutAnotherKeystroke() {
        var h = Harness()
        let blocked = StrongMatchGate.Evaluation(decision: .blocked(.collectionUnavailable), settled: false, allSourcesSettled: false)
        #expect(requests(h.policy.handle(.bufferChanged(text: "buy milk", composing: false, gate: blocked))).isEmpty)
        let ready = h.policy.handle(.gateChanged(.init(decision: .allowed, settled: true, allSourcesSettled: true)))
        #expect(requests(ready).map(\.text) == ["buy milk"])
    }

    @Test func changingOnlyUnicodeNormalizationStillCancelsTheOldRequest() throws {
        var h = Harness()
        let id = try #require(requests(h.policy.handle(.bufferChanged(text: "café notes", composing: false))).first?.id)
        let changed = h.policy.handle(.bufferChanged(text: "cafe\u{301} notes", composing: false))
        #expect(requests(changed).count == 1)
        #expect(outcomes(h.policy.handle(.verdict(id: id, .init(label: .note), latencyMilliseconds: 10))) == [.stale])
    }

    @Test func escapeDismissOptionDoesNotReverseAndReinvocationClearsSuspension() throws {
        var h = Harness { $0.escapeBehavior = .dismisses }
        let id = try #require(requests(h.policy.handle(.bufferChanged(text: "buy milk", composing: false))).first?.id)
        _ = h.policy.handle(.verdict(id: id, .init(label: .task), latencyMilliseconds: 10))
        #expect(h.policy.handle(.reversed(.escape)).isEmpty)
        _ = h.policy.handle(.reversed(.backspace))
        #expect(outcomes(h.policy.handle(.bufferChanged(text: "buy milk later", composing: false))) == [.suspended])
        _ = h.policy.handle(.dismissed(.dismissed)); _ = h.policy.handle(.invoked)
        #expect(requests(h.policy.handle(.bufferChanged(text: "buy milk", composing: false))).count == 1)
    }

    @Test func recordedPolicySessionHasNoInputAndGateOnlyEventsDoNotAddLatencySamples() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = AutomaticSwitchDiagnostics(file: directory.appendingPathComponent("automatic-switch.jsonl"))
        var h = Harness()
        func record(_ effects: [AutomaticSwitch.Effect]) {
            for effect in effects { if case .record(let event) = effect { log.record(event, options: h.policy.options) } }
        }
        let secret = "private policy บ้าน secret"
        record(h.policy.handle(.bufferChanged(text: secret, composing: false,
            gate: .init(decision: .blocked(.collectionUnavailable), settled: false, allSourcesSettled: false))))
        let ready = h.policy.handle(.gateChanged(.init(decision: .allowed, settled: true, allSourcesSettled: true)))
        let id = try #require(requests(ready).first?.id)
        record(h.policy.handle(.verdict(id: id, .init(label: .note), latencyMilliseconds: 12)))
        record(h.policy.handle(.reversed(.escape)))
        record(h.policy.handle(.bufferChanged(text: secret + " edited", composing: false)))
        record(h.policy.handle(.dismissed(.dismissed)))
        let counts = log.counts()
        #expect(counts.switches == 1 && counts.wrongSwitches == 1 && counts.reversals == 1 && counts.ambiguous == 0)
        #expect(counts.latencies[.foundationModels]?.medianMilliseconds == 12)
        #expect(counts.latencies[.foundationModels]?.maximumMilliseconds == 12)
        let rows = try String(contentsOf: log.url, encoding: .utf8)
        #expect(!rows.contains(secret) && !rows.contains("private policy"))
        #expect(rows.contains("suspended") && rows.contains("blocked") && rows.contains("autoswitch.ended"))
    }

    @Test(arguments: [false, true])
    func timeoutAndStaleTerminalCallbackContributeOneLatencySample(lateVerdict: Bool) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = AutomaticSwitchDiagnostics(file: directory.appendingPathComponent("automatic-switch.jsonl"))
        var h = Harness()
        func record(_ effects: [AutomaticSwitch.Effect]) {
            for effect in effects { if case .record(let event) = effect { log.record(event, options: h.policy.options) } }
        }
        let first = try #require(requests(h.policy.handle(.bufferChanged(text: "call mom", composing: false))).first?.id)
        h.clock.advance(by: .milliseconds(1500))
        record(h.policy.handle(.tick))
        let stale = h.policy.handle(lateVerdict
            ? .verdict(id: first, .init(label: .task), latencyMilliseconds: 1700)
            : .failed(id: first, .other, latencyMilliseconds: 1700))
        #expect(outcomes(stale) == [.stale])
        record(stale)
        let second = try #require(requests(h.policy.handle(.bufferChanged(text: "call mom tomorrow", composing: false))).first?.id)
        record(h.policy.handle(.verdict(id: second, .init(label: .search), latencyMilliseconds: 100)))
        let counts = AutomaticSwitchDiagnostics(file: log.url).counts()
        #expect(counts.timeouts == 1 && counts.errors == 0)
        // Exactly two observations: the 1500 ms abandonment and the 100 ms normal verdict.
        #expect(counts.latencies[.foundationModels]?.medianMilliseconds == 800)
        #expect(counts.latencies[.foundationModels]?.maximumMilliseconds == 1500)
        let rows = try String(contentsOf: log.url, encoding: .utf8).split(separator: "\n")
            .map { try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any]) }
        #expect(rows.filter { $0["latencyMilliseconds"] != nil }.count == 2)
        #expect(rows.filter { $0["outcome"] as? String == "stale" }.count == 1)
    }

    private func outcomes(_ effects: [AutomaticSwitch.Effect]) -> [AutomaticSwitchDiagnostics.Outcome] {
        effects.compactMap { if case .record(.verdict(let value)) = $0 { value.outcome } else { nil } }
    }

    private struct Harness {
        let clock = TestClock()
        var policy: AutomaticSwitch
        init(_ configure: (inout AutomaticSwitchOptions) -> Void = { _ in }) {
            var options = AutomaticSwitchOptions(); options.isEnabled = true; options.firing = .everyKeystroke
            configure(&options)
            let clock = clock
            policy = AutomaticSwitch(options: options, now: { clock.now.offset })
            _ = policy.handle(.invoked)
            _ = policy.handle(.gateChanged(.init(decision: .allowed, settled: true, allSourcesSettled: true)))
        }
    }
    private func modes(_ effects: [AutomaticSwitch.Effect]) -> [CaptureSession.Mode] {
        effects.compactMap { if case .enterMode(let mode) = $0 { mode } else { nil } }
    }
    private func returns(_ effects: [AutomaticSwitch.Effect]) -> Bool {
        effects.contains { if case .returnToSearch = $0 { true } else { false } }
    }
    private func lateOutcomes(_ effects: [AutomaticSwitch.Effect]) -> [AutomaticSwitchDiagnostics.LateOutcome] {
        effects.compactMap { if case .record(.lateStrongMatch(_, let outcome)) = $0 { outcome } else { nil } }
    }

    private func requests(_ effects: [AutomaticSwitch.Effect]) -> [(id: UUID, text: String)] {
        effects.compactMap { if case .classify(let id, let text) = $0 { (id, text) } else { nil } }
    }
}
