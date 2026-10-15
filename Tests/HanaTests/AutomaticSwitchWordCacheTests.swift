import Foundation
import Testing
@testable import Hana

/// Cache and confidence behavior through the agreed policy seam. No live Jev or native windows.
@Suite @MainActor
struct AutomaticSwitchWordCacheTests {
    @Test func anAnswerFromAnEarlierBarSessionSwitchesWithoutARequest() throws {
        let memory = JevLaunchMemory()
        var first = Harness(memory: memory)
        let id = try #require(requests(first.edit("call mom ")).first?.id)
        #expect(modes(first.answer(id, .task, 0.95)) == [.task])
        _ = first.policy.handle(.dismissed(.dismissed))

        var second = Harness(memory: memory)
        let cached = second.edit("call mom")
        #expect(requests(cached).isEmpty && modes(cached) == [.task])
    }

    @Test func cacheHitsAreMarkedWithoutLatencyOrInputText() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = AutomaticSwitchDiagnostics(file: directory.appendingPathComponent("automatic-switch.jsonl"))
        let memory = JevLaunchMemory()
        var first = Harness(memory: memory)
        let secret = "private บ้าน"
        let id = try #require(requests(first.edit(secret + " ")).first?.id)
        for effect in first.answer(id, .note, 0.95) {
            if case .record(let event) = effect { log.record(event, options: first.policy.options) }
        }
        _ = first.policy.handle(.dismissed(.dismissed))
        var second = Harness(memory: memory)
        let cached = second.edit(secret)
        for effect in cached {
            if case .record(let event) = effect { log.record(event, options: second.policy.options) }
        }
        let contents = try String(contentsOf: log.url, encoding: .utf8)
        let verdicts = try contents.split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }.filter { $0["event"] as? String == "autoswitch.verdict" }
        let hit = try #require(verdicts.last)
        #expect(hit["cached"] as? Bool == true && hit["latencyMilliseconds"] == nil)
        #expect(!contents.contains(secret) && !contents.contains("private"))
        #expect(verdicts.filter { $0["latencyMilliseconds"] != nil }.count == 1)
        #expect(log.counts().latencies[.jev]?.medianMilliseconds == 40)
    }

    @Test func theSixtyFifthAnswerEvictsTheLeastRecentlyUsedEntry() throws {
        let memory = JevLaunchMemory()
        for index in 0..<64 {
            var session = Harness(memory: memory)
            let id = try #require(requests(session.edit("note item \(index) ")).first?.id)
            _ = session.answer(id, .note, 0.95)
        }
        // Reading item 0 makes item 1 the least recently used answer.
        var touch = Harness(memory: memory)
        #expect(modes(touch.edit("note item 0")) == [.note])
        var extra = Harness(memory: memory)
        let extraID = try #require(requests(extra.edit("note item 64 ")).first?.id)
        _ = extra.answer(extraID, .note, 0.95)
        var evicted = Harness(memory: memory)
        #expect(requests(evicted.edit("note item 1 ")).map(\.text) == ["note item 1"])
        var retained = Harness(memory: memory)
        let cached = retained.edit("note item 0")
        #expect(requests(cached).isEmpty && modes(cached) == [.note])
    }

    @Test(arguments: [
        JevLaunchMemory.CacheIdentity(wordingVersion: "automatic-switch-v2", model: JevClassifier.model),
        JevLaunchMemory.CacheIdentity(wordingVersion: ClassifierWording.version.rawValue, model: "jev-future-model")
    ])
    func differentWordingOrModelMissesTheCache(identity: JevLaunchMemory.CacheIdentity) throws {
        let memory = JevLaunchMemory()
        var first = Harness(memory: memory)
        let id = try #require(requests(first.edit("call mom ")).first?.id)
        _ = first.answer(id, .task, 0.95)
        var changed = Harness(memory: memory, identity: identity)
        let miss = changed.edit("call mom ")
        #expect(modes(miss).isEmpty && requests(miss).map(\.text) == ["call mom"])
    }

    @Test func aBorderlineAnswerWaitsForTheNextAgreeingAnswerWithoutResending() throws {
        var h = Harness()
        let first = try #require(requests(h.edit("call mom ")).first?.id)
        let borderline = h.answer(first, .task, 0.80)
        #expect(modes(borderline).isEmpty && rows(borderline).map(\.outcome) == [.awaitingAgreement])
        h.clock.advance(by: .seconds(1))
        #expect(requests(h.policy.handle(.tick)).isEmpty)
        let next = try #require(requests(h.edit("call mom tomorrow ")).first?.id)
        #expect(modes(h.answer(next, .task, 0.80)) == [.task])
    }

    @Test func consecutiveBorderlineAnswersAgreeWhileSearchSourcesAreStillSettling() throws {
        var h = Harness()
        _ = h.policy.handle(.gateChanged(.init(decision: .allowed, settled: false, allSourcesSettled: false)))
        let first = try #require(requests(h.edit("call mom ")).first?.id)
        #expect(modes(h.answer(first, .task, 0.80)).isEmpty)
        let second = try #require(requests(h.edit("call mom tomorrow ")).first?.id)
        #expect(modes(h.answer(second, .task, 0.80)).isEmpty)
        let settled = h.policy.handle(.gateChanged(.init(decision: .allowed, settled: true, allSourcesSettled: true)))
        #expect(modes(settled) == [.task] && requests(settled).isEmpty)
    }

    @Test func aCachedAnswerAppliesAsSoonAsTheGateAllows() throws {
        let memory = JevLaunchMemory()
        var first = Harness(memory: memory)
        let id = try #require(requests(first.edit("call mom ")).first?.id)
        _ = first.answer(id, .task, 0.95)
        var second = Harness(memory: memory)
        _ = second.policy.handle(.gateChanged(.init(decision: .blocked(.collectionUnavailable), settled: false, allSourcesSettled: false)))
        let blocked = second.edit("call mom")
        #expect(requests(blocked).isEmpty && modes(blocked).isEmpty)
        let allowed = second.policy.handle(.gateChanged(.init(decision: .allowed, settled: true, allSourcesSettled: true)))
        #expect(requests(allowed).isEmpty && modes(allowed) == [.task])
    }

    @Test func anOlderSuccessfulAnswerIsCachedEvenWhenANewerAnswerAlreadyWon() throws {
        let memory = JevLaunchMemory()
        var first = Harness(memory: memory)
        let older = try #require(requests(first.edit("call mom ")).first?.id)
        let newer = try #require(requests(first.edit("call mom tomorrow ")).first?.id)
        _ = first.answer(newer, .search, 0.95)
        let stale = first.answer(older, .task, 0.95)
        #expect(modes(stale).isEmpty && rows(stale).map(\.outcome) == [.stale])
        var second = Harness(memory: memory)
        let cached = second.edit("call mom")
        #expect(requests(cached).isEmpty && modes(cached) == [.task])
    }

    @Test(arguments: [AutomaticSwitchDiagnostics.ErrorKind.network, .authentication, .rateLimited, .malformedResponse, .other])
    func failuresAreNeverCached(kind: AutomaticSwitchDiagnostics.ErrorKind) throws {
        let memory = JevLaunchMemory()
        var first = Harness(memory: memory)
        let id = try #require(requests(first.edit("call mom ")).first?.id)
        _ = first.policy.handle(.failed(id: id, kind, latencyMilliseconds: 40))
        var second = Harness(memory: memory)
        // This assertion isolates cache behavior from #126's launch-wide backoff.
        memory.keySaved()
        second.clock.advance(by: .seconds(30))
        let retry = second.edit("call mom ")
        #expect(modes(retry).isEmpty && requests(retry).map(\.text) == ["call mom"])
    }

    @Test(arguments: [0.90, 0.95, 1.0])
    func clearAnswersSwitchAtOnce(probability: Double) throws {
        var h = Harness()
        let id = try #require(requests(h.edit("call mom ")).first?.id)
        #expect(modes(h.answer(id, .task, probability)) == [.task])
    }

    @Test func thePointNineFiveThresholdStillGoverns() throws {
        var h = Harness { $0.jevThreshold = .p95 }
        let first = try #require(requests(h.edit("call mom ")).first?.id)
        let below = h.answer(first, .task, 0.94)
        #expect(modes(below).isEmpty && rows(below).map(\.outcome) == [.belowThreshold])
        let next = try #require(requests(h.edit("call mom tomorrow ")).first?.id)
        #expect(modes(h.answer(next, .task, 0.95)) == [.task])
    }

    @Test func disagreementRequiresANewConsecutivePair() throws {
        var h = Harness()
        let first = try #require(requests(h.edit("call mom ")).first?.id)
        #expect(modes(h.answer(first, .note, 0.80)).isEmpty)
        let second = try #require(requests(h.edit("call mom tomorrow ")).first?.id)
        #expect(modes(h.answer(second, .task, 0.80)).isEmpty)
        let third = try #require(requests(h.edit("call mom tomorrow at ")).first?.id)
        #expect(modes(h.answer(third, .task, 0.80)) == [.task])
    }

    @Test(arguments: [ClassifierVerdict.Label.unsure, .note])
    func unsureAndBelowThresholdAnswersBreakAgreement(label: ClassifierVerdict.Label) throws {
        var h = Harness()
        let first = try #require(requests(h.edit("call mom ")).first?.id)
        _ = h.answer(first, .task, 0.80)
        let second = try #require(requests(h.edit("call mom tomorrow ")).first?.id)
        _ = h.answer(second, label, 0.60)
        let third = try #require(requests(h.edit("call mom tomorrow at ")).first?.id)
        let waiting = h.answer(third, .task, 0.80)
        #expect(modes(waiting).isEmpty && rows(waiting).map(\.outcome) == [.awaitingAgreement])
    }

    @Test func twoAgreeingClearAnswersDoNotResendTheSameText() throws {
        var h = Harness { $0.agreeingVerdicts = .two }
        let first = try #require(requests(h.edit("call mom ")).first?.id)
        let waiting = h.answer(first, .task, 0.95)
        #expect(modes(waiting).isEmpty && rows(waiting).map(\.outcome) == [.awaitingAgreement])
        let repeated = h.edit("call mom  ")
        #expect(requests(repeated).isEmpty && modes(repeated).isEmpty)
        h.clock.advance(by: .seconds(1))
        #expect(requests(h.policy.handle(.tick)).isEmpty)
        let second = try #require(requests(h.edit("call mom  tomorrow ")).first?.id)
        #expect(modes(h.answer(second, .task, 0.95)) == [.task])
    }

    @Test func normalizationSharesTheCacheButPreservesCase() throws {
        let memory = JevLaunchMemory()
        var first = Harness(memory: memory)
        let id = try #require(requests(first.edit("caf\u{E9} notes ")).first?.id)
        _ = first.answer(id, .note, 0.95)
        var equivalent = Harness(memory: memory)
        let cached = equivalent.edit("  cafe\u{301}   notes ")
        #expect(requests(cached).isEmpty && modes(cached) == [.note])
        var differentCase = Harness(memory: memory)
        #expect(requests(differentCase.edit("Caf\u{E9} notes ")).map(\.text) == ["Caf\u{E9} notes"])
    }

    @Test func multilineTaskCacheHitsStillCannotSwitch() throws {
        let memory = JevLaunchMemory()
        var first = Harness(memory: memory)
        let id = try #require(requests(first.edit("call mom ")).first?.id)
        _ = first.answer(id, .task, 0.95)
        var multiline = Harness(memory: memory)
        let hit = multiline.edit("call\nmom")
        #expect(requests(hit).isEmpty && modes(hit).isEmpty && rows(hit).map(\.outcome) == [.multiline])
    }

    private struct Harness {
        let clock = TestClock()
        var policy: AutomaticSwitch
        init(memory: JevLaunchMemory = JevLaunchMemory(), identity: JevLaunchMemory.CacheIdentity = .current,
             _ configure: (inout AutomaticSwitchOptions) -> Void = { _ in }) {
            var options = AutomaticSwitchOptions()
            options.isEnabled = true; options.classifier = .jev; options.firing = .wordPaced
            configure(&options)
            let clock = clock
            policy = AutomaticSwitch(options: options, memory: memory, cacheIdentity: identity, now: { clock.now.offset })
            _ = policy.handle(.invoked)
            _ = policy.handle(.gateChanged(.init(decision: .allowed, settled: true, allSourcesSettled: true)))
        }
        mutating func edit(_ text: String) -> [AutomaticSwitch.Effect] {
            policy.handle(.bufferChanged(text: text, composing: false))
        }
        mutating func answer(_ id: UUID, _ label: ClassifierVerdict.Label, _ probability: Double) -> [AutomaticSwitch.Effect] {
            policy.handle(.verdict(id: id, .init(label: label, probabilities: [label: probability]), latencyMilliseconds: 40))
        }
    }

    private func requests(_ effects: [AutomaticSwitch.Effect]) -> [(id: UUID, text: String)] {
        effects.compactMap { if case .classify(let id, let text) = $0 { (id, text) } else { nil } }
    }
    private func modes(_ effects: [AutomaticSwitch.Effect]) -> [CaptureSession.Mode] {
        effects.compactMap { if case .enterMode(let mode) = $0 { mode } else { nil } }
    }
    private func rows(_ effects: [AutomaticSwitch.Effect]) -> [AutomaticSwitchDiagnostics.Verdict] {
        effects.compactMap { if case .record(.verdict(let value)) = $0 { value } else { nil } }
    }
}
