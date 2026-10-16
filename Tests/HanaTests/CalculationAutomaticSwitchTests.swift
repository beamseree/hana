import Foundation
import Testing
@testable import Hana

@MainActor
struct CalculationAutomaticSwitchTests {
    @Test(arguments: AutomaticSwitchOptions.Firing.allCases,
          ["12 * 4", "12 *", "(3 + 4", "sqrt", "1 / 0", "sqrt(-1)", "9^9^9", "3 + * 4", "1..2"])
    func calculationsNeverRequestClassificationOrQueueASave(firing: AutomaticSwitchOptions.Firing, text: String) {
        let clock = TestClock()
        var options = AutomaticSwitchOptions()
        options.isEnabled = true; options.classifier = .jev; options.firing = firing; options.wait = .none
        var policy = AutomaticSwitch(options: options, now: { clock.now.offset })
        _ = policy.handle(.invoked)
        var effects = policy.handle(.bufferChanged(text: text, composing: false, gate: gate(text), edit: .append))
        clock.advance(by: .seconds(2))
        effects += policy.handle(.tick)
        effects += policy.handle(.submitRequested)
        #expect(requests(effects).isEmpty)
        #expect(!effects.contains { if case .enterMode = $0 { true } else { false } })
        #expect(!effects.contains { if case .submitCapture = $0 { true } else { false } })
        #expect(!policy.isAwaitingSubmission)
        #expect(policy.debugSnapshot.state == "blocked: Calculation")
        let lines = policy.debugSnapshot.lines(sent: 0, activeHTTP: 0, startedIDs: [])
        #expect(lines.detail == "blocked: Calculation")
        #expect(lines.summary.contains("sent 0"))
    }

    @Test(arguments: AutomaticSwitchOptions.Firing.allCases)
    func addingAWordRestoresClassification(firing: AutomaticSwitchOptions.Firing) {
        let clock = TestClock()
        var options = AutomaticSwitchOptions()
        options.isEnabled = true; options.classifier = .jev; options.firing = firing; options.wait = .none
        var policy = AutomaticSwitch(options: options, now: { clock.now.offset })
        _ = policy.handle(.invoked)
        #expect(requests(policy.handle(.bufferChanged(text: "1200 / 3", composing: false,
            gate: gate("1200 / 3"), edit: .append))).isEmpty)
        let text = "1200 / 3 rent "
        var effects = policy.handle(.bufferChanged(text: text, composing: false, gate: gate(text), edit: .append))
        clock.advance(by: .seconds(1))
        effects += policy.handle(.tick)
        #expect(requests(effects) == [firing == .wordPaced ? "1200 / 3 rent" : text])
    }

    private func gate(_ text: String) -> StrongMatchGate.Evaluation {
        StrongMatchGate.evaluate(rawBuffer: text, results: [], appStatus: .ready,
            fileStatus: .ready, titles: .init(status: .ready))
    }

    private func requests(_ effects: [AutomaticSwitch.Effect]) -> [String] {
        effects.compactMap { if case .classify(_, let text) = $0 { text } else { nil } }
    }
}
