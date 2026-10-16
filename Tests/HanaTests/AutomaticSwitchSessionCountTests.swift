import Foundation
import Testing
@testable import Hana

/// Session diagnostics through policy effects, without windows or a live classifier.
@Suite @MainActor
struct AutomaticSwitchSessionCountTests {
    @Test(arguments: [AutomaticSwitchOptions.Firing.everyKeystroke, .debounced, .onPause],
          [AutomaticSwitchOptions.Classifier.foundationModels, .jev])
    func sessionCountsRequestsForTheOtherFiringStrategies(firing: AutomaticSwitchOptions.Firing,
                                                          classifier: AutomaticSwitchOptions.Classifier) throws {
        let clock = TestClock()
        var options = AutomaticSwitchOptions()
        options.isEnabled = true; options.firing = firing; options.classifier = classifier
        var policy = AutomaticSwitch(options: options, now: { clock.now.offset })
        _ = policy.handle(.invoked)
        _ = policy.handle(.gateChanged(.init(decision: .allowed, settled: true, allSourcesSettled: true)))

        var first = policy.handle(.bufferChanged(text: "buy milk", composing: false))
        clock.advance(by: .milliseconds(500))
        first += policy.handle(.tick)
        let firstRequest = try #require(requests(first).first)
        #expect(requests(first).map(\.text) == ["buy milk"])
        _ = policy.handle(.verdict(id: firstRequest.id, .init(label: .search, probabilities: [.search: 0.95]),
                                  latencyMilliseconds: 40))

        var second = policy.handle(.bufferChanged(text: "buy milk tomorrow", composing: false))
        clock.advance(by: .milliseconds(500))
        second += policy.handle(.tick)
        #expect(requests(second).map(\.text) == ["buy milk tomorrow"])
        // Closing while the second request is running still counts it as sent.
        let dismissed = policy.handle(.dismissed(.dismissed))
        #expect(sessionCounts(dismissed) == [2])
        #expect(sessionCounts(policy.handle(.dismissed(.dismissed))).isEmpty)

        _ = policy.handle(.invoked)
        var next = policy.handle(.bufferChanged(text: "call mom", composing: false))
        clock.advance(by: .milliseconds(500))
        next += policy.handle(.tick)
        #expect(requests(next).map(\.text) == ["call mom"])
        #expect(sessionCounts(policy.handle(.dismissed(.dismissed))) == [1])
    }

    private func requests(_ effects: [AutomaticSwitch.Effect]) -> [(id: UUID, text: String)] {
        effects.compactMap { if case .classify(let id, let text) = $0 { (id, text) } else { nil } }
    }
    private func sessionCounts(_ effects: [AutomaticSwitch.Effect]) -> [Int] {
        effects.compactMap { if case .record(.session(let count)) = $0 { count } else { nil } }
    }
}
