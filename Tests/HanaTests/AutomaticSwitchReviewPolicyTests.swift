import Foundation
import Testing
@testable import Hana

/// Integration-review regressions at the agreed policy seam. Terminal callbacks are deliberately withheld.
@Suite @MainActor
struct AutomaticSwitchReviewPolicyTests {
    @Test(arguments: ["buy milk ", "call mo "])
    func replacingThePreviousAnswersWordsBreaksBorderlineAgreement(replacement: String) throws {
        var h = Harness()
        let first = try #require(requests(h.edit("call mom ")).first?.id)
        #expect(modes(h.answer(first)).isEmpty)
        #expect(requests(h.edit(replacement, replacement: true)).isEmpty)
        h.clock.advance(by: .milliseconds(180))
        let next = try #require(requests(h.policy.handle(.tick)).first?.id)
        let newAnswer = h.answer(next)
        #expect(modes(newAnswer).isEmpty && outcomes(newAnswer) == [.awaitingAgreement])
        let confirming = try #require(requests(h.edit(replacement + "tomorrow ")).first?.id)
        #expect(modes(h.answer(confirming)) == [.task])
    }

    @Test func retypingCancelledTextWaitsUntilItsRequestActuallyFinishes() throws {
        var h = Harness()
        let original = try #require(requests(h.edit("call mom ")).first?.id)
        let deleted = h.edit("call m", replacement: true)
        #expect(cancels(deleted) == [original])
        #expect(requests(h.edit("call mom ")).isEmpty)
        h.clock.advance(by: .milliseconds(180))
        #expect(requests(h.policy.handle(.tick)).isEmpty)
        // The cancellation-delaying provider only now acknowledges the cancelled work.
        let finished = h.policy.handle(.failed(id: original, .other, latencyMilliseconds: 180))
        #expect(requests(finished).map(\.text) == ["call mom"])
    }

    @Test func anIdenticalRequestFromAClosedBarWaitsForItsTerminalCallback() throws {
        let memory = JevLaunchMemory()
        var first = Harness(memory: memory)
        let original = try #require(requests(first.edit("cafe\u{301} notes ")).first?.id)
        #expect(cancels(first.policy.handle(.dismissed(.dismissed))) == [original])
        var second = Harness(memory: memory)
        // The spelling differs in whitespace and Unicode representation but asks the same question.
        #expect(requests(second.edit("  caf\u{E9}  notes ")).isEmpty)
        second.clock.advance(by: .milliseconds(180))
        #expect(requests(second.policy.handle(.tick)).isEmpty)
        _ = first.policy.handle(.failed(id: original, .other, latencyMilliseconds: 180))
        let released = second.policy.handle(.slotReleased)
        #expect(requests(released).map(\.text) == ["caf\u{E9} notes"])
    }

    private struct Harness {
        let clock = TestClock()
        var policy: AutomaticSwitch
        init(memory: JevLaunchMemory = JevLaunchMemory()) {
            var options = AutomaticSwitchOptions()
            options.isEnabled = true; options.classifier = .jev; options.firing = .wordPaced
            let clock = clock
            policy = AutomaticSwitch(options: options, memory: memory, now: { clock.now.offset })
            _ = policy.handle(.invoked)
            _ = policy.handle(.gateChanged(.init(decision: .allowed, settled: true, allSourcesSettled: true)))
        }
        mutating func edit(_ text: String, replacement: Bool = false) -> [AutomaticSwitch.Effect] {
            policy.handle(.bufferChanged(text: text, composing: false,
                edit: replacement ? .replacement(caretAtEnd: true) : .append))
        }
        mutating func answer(_ id: UUID) -> [AutomaticSwitch.Effect] {
            policy.handle(.verdict(id: id, .init(label: .task, probabilities: [.task: 0.80]), latencyMilliseconds: 40))
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
    private func outcomes(_ effects: [AutomaticSwitch.Effect]) -> [AutomaticSwitchDiagnostics.Outcome] {
        effects.compactMap { if case .record(.verdict(let value)) = $0 { value.outcome } else { nil } }
    }
}
