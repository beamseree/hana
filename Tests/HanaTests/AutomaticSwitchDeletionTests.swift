import Foundation
import Testing
@testable import Hana

/// Deletion behavior through the agreed policy seam. The clock and answers
/// are controlled; no AppKit window or real classifier is used.
@Suite @MainActor
struct AutomaticSwitchDeletionTests {
    @Test func aQualifyingAnswerWaitsUntilTheDeletionPause() throws {
        var h = Harness()
        let id = try #require(requests(h.edit("call mom ")).first?.id)
        _ = h.edit("call mom tomorrow")
        _ = h.edit("call mom tomorro")
        #expect(modes(h.policy.handle(.verdict(id: id, task, latencyMilliseconds: 40))).isEmpty)
        #expect(h.policy.nextWakeUp == .milliseconds(180))
        h.advance(to: .milliseconds(179))
        #expect(modes(h.policy.handle(.tick)).isEmpty)
        h.advance(to: .milliseconds(180))
        #expect(modes(h.policy.handle(.tick)) == [.task])
    }

    @Test(arguments: ["call mom tomorr", "call mo"])
    func heldAnswersAreRecheckedAgainstTheFinalText(finalText: String) throws {
        var h = Harness()
        let id = try #require(requests(h.edit("call mom ")).first?.id)
        _ = h.edit("call mom tomorrow")
        _ = h.edit("call mom tomorro")
        #expect(modes(h.policy.handle(.verdict(id: id, task, latencyMilliseconds: 40))).isEmpty)
        h.advance(to: .milliseconds(100))
        _ = h.edit(finalText)
        h.advance(to: .milliseconds(279))
        #expect(modes(h.policy.handle(.tick)).isEmpty)
        h.advance(to: .milliseconds(280))
        #expect(modes(h.policy.handle(.tick)) == (finalText == "call mo" ? [] : [.task]))
    }

    @Test func twoConsecutiveHeldAnswersCanAgreeAtThePause() throws {
        var h = Harness { $0.agreeingVerdicts = .two }
        let first = try #require(requests(h.edit("call mom ")).first?.id)
        let second = try #require(requests(h.edit("call mom tomorrow ")).first?.id)
        _ = h.edit("call mom tomorrow at")
        _ = h.edit("call mom tomorrow a")
        #expect(modes(h.policy.handle(.verdict(id: first, task, latencyMilliseconds: 40))).isEmpty)
        #expect(modes(h.policy.handle(.verdict(id: second, task, latencyMilliseconds: 50))).isEmpty)
        h.advance(to: .milliseconds(180))
        #expect(modes(h.policy.handle(.tick)) == [.task])
    }

    @Test(arguments: ["call mo", "call mom "])
    func nativeReplacementStartsABurstEvenWhenTheTextLooksAppendedOrUnchanged(before: String) throws {
        var h = Harness()
        let initial = h.edit(before)
        h.advance(to: .milliseconds(180))
        let id = try #require(requests(initial + h.policy.handle(.tick)).first?.id)
        let replaced = h.policy.handle(.bufferChanged(text: "call mom ", composing: false,
            edit: .replacement(caretAtEnd: true)))
        #expect(requests(replaced).isEmpty)
        #expect(modes(h.policy.handle(.verdict(id: id, task, latencyMilliseconds: 40))).isEmpty)
        h.advance(to: .milliseconds(360))
        #expect(modes(h.policy.handle(.tick)) == [.task])
    }

    @Test func aWordBoundaryDuringACorrectionWaitsForThePauseThenSendingResumes() throws {
        var h = Harness()
        let id = try #require(requests(h.edit("call mom tomorrow ")).first?.id)
        _ = h.edit("call mom tomorro")
        _ = h.policy.handle(.failed(id: id, .other, latencyMilliseconds: 20))
        h.advance(to: .milliseconds(100))
        #expect(requests(h.edit("call mom tomorrow ")).isEmpty)
        h.advance(to: .milliseconds(279))
        #expect(requests(h.policy.handle(.tick)).isEmpty)
        h.advance(to: .milliseconds(280))
        #expect(requests(h.policy.handle(.tick)).map(\.text) == ["call mom tomorrow"])
        #expect(requests(h.edit("call mom tomorrow at ")).map(\.text) == ["call mom tomorrow at"])
    }

    @Test func aNewerFailureDiscardsAnOlderHeldAnswer() throws {
        var h = Harness()
        let first = try #require(requests(h.edit("call mom ")).first?.id)
        let second = try #require(requests(h.edit("call mom tomorrow ")).first?.id)
        _ = h.edit("call mom tomorrow at")
        _ = h.edit("call mom tomorrow a")
        _ = h.policy.handle(.verdict(id: first, task, latencyMilliseconds: 40))
        _ = h.policy.handle(.failed(id: second, .network, latencyMilliseconds: 50))
        h.advance(to: .milliseconds(180))
        #expect(modes(h.policy.handle(.tick)).isEmpty)
    }

    @Test func holdingBackspaceSendsNothingUntilThePause() throws {
        var h = Harness()
        let id = try #require(requests(h.edit("call mom tomorrow ")).first?.id)
        for (index, text) in ["call mom tomorrow", "call mom tomorro", "call mom tomorr", "call mom tomor"].enumerated() {
            h.advance(to: .milliseconds(index * 100))
            #expect(requests(h.edit(text)).isEmpty)
            #expect(requests(h.policy.handle(.tick)).isEmpty)
        }
        _ = h.policy.handle(.failed(id: id, .other, latencyMilliseconds: 300))
        h.advance(to: .milliseconds(479))
        #expect(requests(h.policy.handle(.tick)).isEmpty)
        h.advance(to: .milliseconds(480))
        #expect(requests(h.policy.handle(.tick)).map(\.text) == ["call mom tomor"])
    }

    @Test func onlyRemovedRequestsAreCancelledAndCancellationHasNoLatencyOrContent() throws {
        var h = Harness()
        let first = try #require(requests(h.edit("call mom ")).first?.id)
        let second = try #require(requests(h.edit("call mom tomorrow ")).first?.id)
        #expect(cancels(h.edit("call mom tomorro")) == [second])
        #expect(cancels(h.edit("call mom tomorr")).isEmpty)
        let cancelled = h.policy.handle(.failed(id: second, .other, latencyMilliseconds: 90))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = AutomaticSwitchDiagnostics(file: directory.appendingPathComponent("automatic-switch.jsonl"))
        for effect in cancelled {
            if case .record(let event) = effect { log.record(event, options: h.policy.options) }
        }
        #expect(log.counts().latencies[.jev] == nil)
        let contents = try String(contentsOf: log.url, encoding: .utf8)
        #expect(!contents.contains("call mom") && !contents.contains("tomorrow"))
        #expect(modes(h.policy.handle(.verdict(id: first, task, latencyMilliseconds: 40))).isEmpty)
        h.advance(to: .milliseconds(180))
        #expect(modes(h.policy.handle(.tick)) == [.task])
    }

    @Test func clearingResetsConfidenceAndNavigationSuspension() throws {
        var h = Harness { $0.agreeingVerdicts = .two; $0.navigationSuspends = true }
        let first = try #require(requests(h.edit("call mom ")).first?.id)
        #expect(modes(h.policy.handle(.verdict(id: first, task, latencyMilliseconds: 40))).isEmpty)
        _ = h.policy.handle(.navigated)
        #expect(requests(h.edit("call mom tomorrow ")).isEmpty)
        _ = h.edit("")
        let fresh = try #require(requests(h.edit("buy milk ")).first?.id)
        #expect(modes(h.policy.handle(.verdict(id: fresh, task, latencyMilliseconds: 40))).isEmpty)
        let next = try #require(requests(h.edit("buy milk today ")).first?.id)
        #expect(modes(h.policy.handle(.verdict(id: next, task, latencyMilliseconds: 40))) == [.task])
    }

    @Test func enterHoldingAnOpenDiscardsHeldAnswersAndCancelsRemainingRequests() throws {
        var h = Harness()
        let first = try #require(requests(h.edit("call mom ")).first?.id)
        let second = try #require(requests(h.edit("call mom tomorrow ")).first?.id)
        _ = h.edit("call mom tomorrow at")
        _ = h.edit("call mom tomorrow a")
        _ = h.policy.handle(.verdict(id: first, task, latencyMilliseconds: 40))
        #expect(cancels(h.policy.handle(.eligibilityChanged(false))) == [second])
        #expect(modes(h.policy.handle(.verdict(id: second, task, latencyMilliseconds: 50))).isEmpty)
        h.advance(to: .milliseconds(180))
        #expect(modes(h.policy.handle(.tick)).isEmpty)
        _ = h.policy.handle(.eligibilityChanged(true))
        #expect(modes(h.policy.handle(.tick)).isEmpty)
    }

    private let task = ClassifierVerdict(label: .task, probabilities: [.task: 0.95])

    private struct Harness {
        let clock = TestClock()
        var policy: AutomaticSwitch
        init(_ configure: (inout AutomaticSwitchOptions) -> Void = { _ in }) {
            var options = AutomaticSwitchOptions()
            options.isEnabled = true; options.classifier = .jev; options.firing = .wordPaced
            configure(&options)
            let clock = clock
            policy = AutomaticSwitch(options: options, now: { clock.now.offset })
            _ = policy.handle(.invoked)
            _ = policy.handle(.gateChanged(.init(decision: .allowed, settled: true, allSourcesSettled: true)))
        }
        mutating func edit(_ text: String) -> [AutomaticSwitch.Effect] {
            policy.handle(.bufferChanged(text: text, composing: false))
        }
        func advance(to time: Duration) {
            if time > clock.now.offset { clock.advance(by: time - clock.now.offset) }
        }
    }

    private func requests(_ effects: [AutomaticSwitch.Effect]) -> [(id: UUID, text: String)] {
        effects.compactMap { if case .classify(let id, let text) = $0 { (id, text) } else { nil } }
    }
    private func modes(_ effects: [AutomaticSwitch.Effect]) -> [CaptureSession.Mode] {
        effects.compactMap { if case .enterMode(let mode) = $0 { mode } else { nil } }
    }
    private func cancels(_ effects: [AutomaticSwitch.Effect]) -> [UUID] {
        effects.compactMap { if case .cancel(let id) = $0 { id } else { nil } }
    }
}
