import Foundation
import Testing
@testable import Hana

/// Display observations must not change firing, cache admission or switching.
@MainActor
struct AutomaticSwitchDebugTests {
    @Test func preferencePersistsSeparatelyFromTheSessionPolicy() throws {
        let name = "Hana.DebugPreference.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AutomaticSwitchOptionsStore(defaults: defaults)
        let before = store.read()
        #expect(!store.debugMode)
        store.debugMode = true
        #expect(AutomaticSwitchOptionsStore(defaults: defaults).debugMode)
        #expect(store.read() == before)
        store.debugMode = false
        #expect(!store.debugMode)
    }

    @Test func waitingAndQueueSnapshotsDoNotFireOrAdvanceThePolicy() throws {
        var h = Harness()
        _ = h.edit("private input")
        let wake = h.policy.nextWakeUp
        #expect(h.policy.debugSnapshot.state == "waiting for typing pause")
        #expect(h.policy.debugSnapshot.remainingMilliseconds == 180)
        for _ in 0..<10 { _ = h.policy.debugSnapshot }
        #expect(h.policy.nextWakeUp == wake && h.memory.inFlightCount == 0)
        h.clock.advance(by: .milliseconds(180))
        let first = try #require(requests(h.policy.handle(.tick)).first)
        #expect(h.policy.debugSnapshot.request?.id == first)
        #expect(h.policy.debugSnapshot.request?.number == 1)
        #expect(h.policy.debugSnapshot.request?.characters == 13)
        _ = h.edit("private input again ")
        #expect(h.memory.inFlightCount == 2)
        #expect(requests(h.edit("private input again later ")).isEmpty)
        #expect(h.policy.debugSnapshot.queued)
        #expect(h.policy.debugSnapshot.request?.relevance == .prefix)
        let lines = h.policy.debugSnapshot.lines(sent: 2, activeHTTP: 2, startedIDs: [])
        #expect(lines.summary.contains("sent 2") && lines.detail.contains("newer queued"))
        #expect(!lines.summary.contains("private") && !lines.detail.contains("private"))
    }

    @Test(arguments: [ClassifierVerdict.Label.note, .task])
    func switchCauseSurvivesCaptureEditsAndCancelledLateReplies(label: ClassifierVerdict.Label) throws {
        var h = Harness()
        let first = try #require(requests(h.edit("call mom ")).first)
        let second = try #require(requests(h.edit("call mom tomorrow ")).first)
        _ = h.answer(first, label, 0.95)
        let before = try #require(h.policy.debugSnapshot.answer)
        #expect(before.number == 1 && before.relevance == .prefix && before.outcome == .switched)
        #expect(before.characters == 8 && before.agreement == 1)
        _ = h.edit("call mom tomorrow with a longer body")
        _ = h.answer(second, .search, 0.99)
        let after = try #require(h.policy.debugSnapshot.answer)
        #expect(after.number == before.number && after.label == before.label)
        #expect(after.reason == before.reason && after.relevance == before.relevance)
        #expect(h.policy.debugSnapshot.request == nil && !h.policy.debugSnapshot.needsClockUpdates)
    }

    @Test func cachedAnswerHasNoNetworkLatencyOrRequestNumber() throws {
        let memory = JevLaunchMemory()
        var first = Harness(memory: memory)
        let id = try #require(requests(first.edit("call mom ")).first)
        _ = first.answer(id, .task, 0.95)
        var next = Harness(memory: memory)
        #expect(requests(next.edit("call mom")).isEmpty)
        let snapshot = next.policy.debugSnapshot
        let answer = try #require(snapshot.answer)
        #expect(answer.cached && answer.number == nil && answer.latencyMilliseconds == nil)
        #expect(snapshot.cacheHits == 1 && answer.outcome == .switched)
        #expect(snapshot.lines(sent: 0, activeHTTP: 0, startedIDs: []).summary.contains("sent 0"))
    }

    @Test func agreementAndWaitingForSourcesShowTheActualAnswer() throws {
        var h = Harness { $0.agreeingVerdicts = .two }
        let id = try #require(requests(h.edit("call mom ")).first)
        _ = h.answer(id, .note, 0.86)
        let first = try #require(h.policy.debugSnapshot.answer)
        #expect(first.agreement == 1 && first.requiredAgreement == 2 && first.reason == "agreement 1/2")
        _ = h.policy.handle(.gateChanged(.init(decision: .allowed, settled: false, allSourcesSettled: false)))
        let next = try #require(requests(h.edit("call mom tomorrow ")).first)
        _ = h.answer(next, .note, 0.86)
        #expect(h.policy.debugSnapshot.state == "waiting for Search results")
        #expect(h.policy.debugSnapshot.answer?.number == 2)
        _ = h.policy.handle(.gateChanged(Harness.allowed))
        #expect(h.policy.debugSnapshot.answer?.reason == "switched · agreement 2/2")
    }

    @Test func anOldReplyDoesNotReplaceANewerDecisionAndRelevanceTracksEdits() throws {
        var h = Harness()
        let old = try #require(requests(h.edit("call mom ")).first)
        let new = try #require(requests(h.edit("call mom tomorrow ")).first)
        _ = h.answer(new, .search, 0.95)
        _ = h.answer(old, .task, 0.95)
        #expect(h.policy.debugSnapshot.answer?.number == 2)
        #expect(h.policy.debugSnapshot.answer?.label == .search)
        _ = h.edit("different private input")
        #expect(h.policy.debugSnapshot.answer?.relevance == .stale)
    }

    @Test func blockedSuspendedBackoffAndTimeoutStatesAreContentFree() throws {
        var h = Harness()
        _ = h.policy.handle(.bufferChanged(text: "Safari", composing: false,
            gate: .init(decision: .blocked(.strongMatch(.application)), settled: true, allSourcesSettled: true)))
        #expect(h.policy.debugSnapshot.state == "blocked: strong application match")
        _ = h.policy.handle(.bufferChanged(text: "remind", composing: false,
            gate: .init(decision: .blocked(.oneWord), settled: true, allSourcesSettled: true)))
        #expect(h.policy.debugSnapshot.state == "not sent: one word")
        _ = h.policy.handle(.gateChanged(Harness.allowed))
        _ = h.edit("call mom ")
        h.clock.advance(by: .milliseconds(180))
        let id = try #require(requests(h.policy.handle(.tick)).first)
        _ = h.policy.handle(.failed(id: id, .rateLimited, latencyMilliseconds: 30, retryAfter: .seconds(5)))
        #expect(h.policy.debugSnapshot.state == "backoff: rate-limited")
        #expect(h.policy.debugSnapshot.remainingMilliseconds == 5000)
        h.clock.advance(by: .seconds(5))
        #expect(h.policy.debugSnapshot.remainingMilliseconds == nil)

        var timeout = Harness()
        let pending = try #require(requests(timeout.edit("call mom ")).first)
        timeout.clock.advance(by: .milliseconds(1200))
        _ = timeout.policy.handle(.tick)
        #expect(timeout.policy.debugSnapshot.answer?.outcome == .timeout)
        #expect(timeout.policy.debugSnapshot.answer?.number == 1)
        _ = timeout.answer(pending, .task, 0.95)
        #expect(timeout.policy.debugSnapshot.answer?.outcome == .timeout)
        _ = timeout.policy.handle(.navigated)
        #expect(timeout.policy.debugSnapshot.state == "suspended after navigation")
    }

    @Test func legacyStrategiesCorrelateRawRequestsAndFreezeTheirSwitchAgreement() throws {
        let clock = TestClock()
        var options = AutomaticSwitchOptions()
        options.isEnabled = true; options.classifier = .jev; options.firing = .everyKeystroke
        var policy = AutomaticSwitch(options: options, now: { clock.now.offset })
        _ = policy.handle(.invoked)
        let raw = "call  mom "
        let effects = policy.handle(.bufferChanged(text: raw, composing: false, gate: Harness.allowed))
        let id = try #require(requests(effects).first)
        #expect(policy.debugSnapshot.request?.characters == raw.count)
        #expect(policy.debugSnapshot.request?.relevance == .current)
        _ = policy.handle(.verdict(id: id, .init(label: .task, probabilities: [.task: 0.95]), latencyMilliseconds: 50))
        #expect(policy.debugSnapshot.answer?.number == 1)
        #expect(policy.debugSnapshot.answer?.agreement == 1)
        #expect(policy.debugSnapshot.answer?.reason == "switched · agreement 1/1")
        _ = policy.handle(.bufferChanged(text: "different body", composing: false))
        #expect(policy.debugSnapshot.answer?.relevance == .current)
    }

    @Test func foundationModelsIsLabeledLocalAndUnavailableJevIsNotLabeledNetwork() throws {
        let clock = TestClock()
        var options = AutomaticSwitchOptions()
        options.isEnabled = true; options.firing = .everyKeystroke
        var local = AutomaticSwitch(options: options, now: { clock.now.offset })
        _ = local.handle(.invoked)
        let id = try #require(requests(local.handle(.bufferChanged(text: "call mom", composing: false, gate: Harness.allowed))).first)
        _ = local.handle(.verdict(id: id, .init(label: .search), latencyMilliseconds: 50))
        let lines = local.debugSnapshot.lines(sent: 0, activeHTTP: 0, startedIDs: [])
        #expect(lines.summary.contains("Foundation Models") && !lines.summary.contains("sent"))
        #expect(lines.detail.contains("local") && !lines.detail.contains("network"))

        var jev = Harness()
        let request = try #require(requests(jev.edit("call mom ")).first)
        _ = jev.policy.handle(.failed(id: request, .unavailable, latencyMilliseconds: 0))
        let failed = jev.policy.debugSnapshot.lines(sent: 0, activeHTTP: 0, startedIDs: [])
        #expect(failed.detail.contains("not sent") && !failed.detail.contains("network"))
    }

    private struct Harness {
        static let allowed = StrongMatchGate.Evaluation(decision: .allowed, settled: true, allSourcesSettled: true)
        let clock = TestClock()
        let memory: JevLaunchMemory
        var policy: AutomaticSwitch
        init(memory: JevLaunchMemory = JevLaunchMemory(), _ configure: (inout AutomaticSwitchOptions) -> Void = { _ in }) {
            self.memory = memory
            var options = AutomaticSwitchOptions()
            options.isEnabled = true; options.classifier = .jev; options.firing = .wordPaced
            configure(&options)
            let clock = clock
            policy = AutomaticSwitch(options: options, memory: memory, now: { clock.now.offset })
            _ = policy.handle(.invoked)
            _ = policy.handle(.gateChanged(Self.allowed))
        }
        mutating func edit(_ text: String) -> [AutomaticSwitch.Effect] {
            policy.handle(.bufferChanged(text: text, composing: false))
        }
        mutating func answer(_ id: UUID, _ label: ClassifierVerdict.Label, _ probability: Double) -> [AutomaticSwitch.Effect] {
            policy.handle(.verdict(id: id, .init(label: label, probabilities: [label: probability]), latencyMilliseconds: 182))
        }
    }
    private func requests(_ effects: [AutomaticSwitch.Effect]) -> [UUID] {
        effects.compactMap { if case .classify(let id, _) = $0 { id } else { nil } }
    }
}
