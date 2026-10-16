import Foundation
import Testing
@testable import Hana

/// Fake-clock requests and diagnostic effects only; no adapter or live Jev.
struct JevBackoffTests {
    @Test func aReplyForTheOldKeyCannotRejectANewlySavedKey() throws {
        let clock = TestClock(), memory = JevLaunchMemory()
        var session = policy(memory: memory, clock: clock)
        let old = try #require(requests(session.handle(.bufferChanged(text: "call mom ", composing: false))).first)
        memory.keySaved()
        _ = session.handle(.failed(id: old, .authentication, latencyMilliseconds: 10))
        let fresh = try #require(requests(session.handle(.bufferChanged(text: "call mom tomorrow ", composing: false))).first)
        _ = session.handle(.failed(id: fresh, .authentication, latencyMilliseconds: 10))
        let skipped = session.handle(.bufferChanged(text: "call mom tomorrow morning ", composing: false))
        #expect(requests(skipped).isEmpty)
        #expect(rows(skipped).map(\.backoffReason) == [.keyRejected])
    }
    @Test func concurrentRateLimitsCannotShortenAnExistingRetryAfter() throws {
        let clock = TestClock()
        var session = policy(memory: JevLaunchMemory(), clock: clock)
        let first = try #require(requests(session.handle(.bufferChanged(text: "call mom ", composing: false))).first)
        let second = try #require(requests(session.handle(.bufferChanged(text: "call mom tomorrow ", composing: false))).first)
        _ = session.handle(.failed(id: first, .rateLimited, latencyMilliseconds: 10, retryAfter: .seconds(30)))
        _ = session.handle(.failed(id: second, .rateLimited, latencyMilliseconds: 10, retryAfter: .seconds(1)))
        clock.advance(by: .seconds(1))
        let paused = session.handle(.bufferChanged(text: "call mom tomorrow morning ", composing: false))
        #expect(requests(paused).isEmpty)
        #expect(rows(paused).map(\.backoffReason) == [.rateLimited])
        clock.advance(by: .seconds(29))
        #expect(requests(session.handle(.bufferChanged(text: "call mom tomorrow morning please ", composing: false))).count == 1)
    }
    @MainActor @Test func backoffRowsContainOnlyAReasonAndNoInputOrLatency() throws {
        let clock = TestClock()
        var session = policy(memory: JevLaunchMemory(), clock: clock)
        let first = try #require(requests(session.handle(.bufferChanged(text: "private banana ", composing: false))).first)
        _ = session.handle(.failed(id: first, .authentication, latencyMilliseconds: 10))
        let skipped = session.handle(.bufferChanged(text: "private banana tomorrow ", composing: false))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("events.jsonl")
        let diagnostics = AutomaticSwitchDiagnostics(file: url)
        var options = AutomaticSwitchOptions(); options.isEnabled = true
        for effect in skipped {
            if case .record(let event) = effect { diagnostics.record(event, options: options) }
        }
        let recorded = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        #expect(recorded.contains(#""outcome":"backoff""#))
        #expect(recorded.contains(#""backoffReason":"key-rejected""#))
        #expect(!recorded.contains("private banana"))
        #expect(!recorded.contains("latencyMilliseconds"))
    }
    @Test func anOlderRejectedKeyStillStopsSendsAfterANewerAnswer() throws {
        let clock = TestClock()
        var session = policy(memory: JevLaunchMemory(), clock: clock)
        let older = try #require(requests(session.handle(.bufferChanged(text: "call mom ", composing: false))).first)
        let newer = try #require(requests(session.handle(.bufferChanged(text: "call mom tomorrow ", composing: false))).first)
        _ = session.handle(.verdict(id: newer, .init(label: .search, probabilities: [.search: 0.95]), latencyMilliseconds: 10))
        _ = session.handle(.failed(id: older, .authentication, latencyMilliseconds: 20))
        let skipped = session.handle(.bufferChanged(text: "call mom tomorrow morning ", composing: false))
        #expect(requests(skipped).isEmpty)
        #expect(rows(skipped).map(\.backoffReason) == [.keyRejected])
    }
    @Test func twoNetworkErrorsPauseForTwoSecondsAcrossSessions() throws {
        let memory = JevLaunchMemory(), clock = TestClock()
        var first = policy(memory: memory, clock: clock)
        var id = try #require(requests(first.handle(.bufferChanged(text: "call mom ", composing: false))).first)
        _ = first.handle(.failed(id: id, .network, latencyMilliseconds: 20))
        id = try #require(requests(first.handle(.bufferChanged(text: "call mom tomorrow ", composing: false))).first)
        _ = first.handle(.failed(id: id, .network, latencyMilliseconds: 20))
        _ = first.handle(.dismissed(.dismissed))
        var next = policy(memory: memory, clock: clock)
        clock.advance(by: .milliseconds(1999))
        let paused = next.handle(.bufferChanged(text: "buy milk ", composing: false))
        #expect(requests(paused).isEmpty)
        #expect(rows(paused).map(\.backoffReason) == [.network])
        clock.advance(by: .milliseconds(1))
        id = try #require(requests(next.handle(.bufferChanged(text: "buy milk tomorrow ", composing: false))).first)
        _ = next.handle(.verdict(id: id, .init(label: .search, probabilities: [.search: 0.95]), latencyMilliseconds: 10))
        id = try #require(requests(next.handle(.bufferChanged(text: "buy milk tomorrow morning ", composing: false))).first)
        _ = next.handle(.failed(id: id, .network, latencyMilliseconds: 10))
        #expect(requests(next.handle(.bufferChanged(text: "buy milk tomorrow morning please ", composing: false))).count == 1)
    }
    @Test func rateLimitUsesRetryAfterAcrossBarSessions() throws {
        let memory = JevLaunchMemory(), clock = TestClock()
        var first = policy(memory: memory, clock: clock)
        let id = try #require(requests(first.handle(.bufferChanged(text: "call mom ", composing: false))).first)
        _ = first.handle(.failed(id: id, .rateLimited, latencyMilliseconds: 20, retryAfter: .seconds(5)))
        _ = first.handle(.dismissed(.dismissed))
        var next = policy(memory: memory, clock: clock)
        clock.advance(by: .milliseconds(4999))
        let paused = next.handle(.bufferChanged(text: "buy milk ", composing: false))
        #expect(requests(paused).isEmpty)
        #expect(rows(paused).map(\.backoffReason) == [.rateLimited])
        clock.advance(by: .milliseconds(1))
        #expect(requests(next.handle(.bufferChanged(text: "buy milk tomorrow ", composing: false))).count == 1)
    }

    @Test func missingRetryAfterGrowsToThirtySecondsAndSuccessResetsIt() throws {
        let clock = TestClock()
        var session = policy(memory: JevLaunchMemory(), clock: clock)
        var text = "call mom "
        var id = try #require(requests(session.handle(.bufferChanged(text: text, composing: false))).first)
        for seconds in [1, 2, 4, 8, 16, 30, 30] {
            _ = session.handle(.failed(id: id, .rateLimited, latencyMilliseconds: 10))
            clock.advance(by: .seconds(seconds) - .milliseconds(1))
            text += "soon "
            let paused = session.handle(.bufferChanged(text: text, composing: false))
            #expect(requests(paused).isEmpty)
            #expect(rows(paused).map(\.backoffReason) == [.rateLimited])
            clock.advance(by: .milliseconds(1))
            text += "then "
            id = try #require(requests(session.handle(.bufferChanged(text: text, composing: false))).first)
        }
        _ = session.handle(.verdict(id: id, .init(label: .search, probabilities: [.search: 0.95]), latencyMilliseconds: 10))
        text += "tomorrow "
        id = try #require(requests(session.handle(.bufferChanged(text: text, composing: false))).first)
        _ = session.handle(.failed(id: id, .rateLimited, latencyMilliseconds: 10))
        clock.advance(by: .seconds(1))
        text += "again "
        #expect(requests(session.handle(.bufferChanged(text: text, composing: false))).count == 1)
    }
    @Test func rejectedKeyStopsAcrossSessionsUntilANewKeyIsSaved() throws {
        let memory = JevLaunchMemory(), clock = TestClock()
        var first = policy(memory: memory, clock: clock)
        let request = try #require(requests(first.handle(.bufferChanged(text: "call mom ", composing: false))).first)
        let failure = first.handle(.failed(id: request, .authentication, latencyMilliseconds: 20))
        #expect(rows(failure).map(\.outcome) == [.error])
        #expect(requests(first.handle(.bufferChanged(text: "call mom tomorrow ", composing: false))).isEmpty)
        _ = first.handle(.dismissed(.dismissed))
        var second = policy(memory: memory, clock: clock)
        let skipped = second.handle(.bufferChanged(text: "buy milk ", composing: false))
        #expect(requests(skipped).isEmpty)
        #expect(rows(skipped).map(\.outcome) == [.backoff])
        #expect(rows(skipped).map(\.backoffReason) == [.keyRejected])
        #expect(rows(skipped).first?.latencyMilliseconds == nil)
        memory.keySaved()
        #expect(requests(second.handle(.bufferChanged(text: "buy milk tomorrow ", composing: false))).count == 1)
    }

    private func policy(memory: JevLaunchMemory, clock: TestClock) -> AutomaticSwitch {
        var options = AutomaticSwitchOptions()
        options.isEnabled = true; options.classifier = .jev; options.firing = .wordPaced
        var policy = AutomaticSwitch(options: options, memory: memory, now: { clock.now.offset })
        _ = policy.handle(.invoked)
        _ = policy.handle(.gateChanged(.init(decision: .allowed, settled: true, allSourcesSettled: true)))
        return policy
    }
    private func requests(_ effects: [AutomaticSwitch.Effect]) -> [UUID] {
        effects.compactMap { if case .classify(let id, _) = $0 { id } else { nil } }
    }
    private func rows(_ effects: [AutomaticSwitch.Effect]) -> [AutomaticSwitchDiagnostics.Verdict] {
        effects.compactMap { if case .record(.verdict(let value)) = $0 { value } else { nil } }
    }
}
