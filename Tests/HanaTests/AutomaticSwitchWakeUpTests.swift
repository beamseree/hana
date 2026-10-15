import Foundation
import Testing
@testable import Hana

/// The policy reports when it next needs waking; ticks are sent only at those times.
@Suite @MainActor
struct AutomaticSwitchWakeUpTests {
    @Test(arguments: [(AutomaticSwitchOptions.Firing.everyKeystroke, Duration.zero),
                      (.debounced, .milliseconds(150)), (.onPause, .milliseconds(500))])
    func firingDeadlineIsTheReportedWakeUpAndFiresExactlyThen(firing: AutomaticSwitchOptions.Firing, delay: Duration) {
        var h = Harness { $0.firing = firing }
        #expect(h.policy.nextWakeUp == nil)
        h.clock.advance(by: .milliseconds(40))
        let changed = h.policy.handle(.bufferChanged(text: "call mom", composing: false))
        if delay == .zero {
            #expect(requests(changed).count == 1)
            #expect(h.policy.nextWakeUp == .milliseconds(1540))
            return
        }
        #expect(requests(changed).isEmpty)
        #expect(h.policy.nextWakeUp == .milliseconds(40) + delay)
        h.advance(to: .milliseconds(40) + delay - .milliseconds(1))
        #expect(requests(h.policy.handle(.tick)).isEmpty)
        h.advance(to: .milliseconds(40) + delay)
        #expect(requests(h.policy.handle(.tick)).map(\.text) == ["call mom"])
        // Only the in-flight request's timeout remains.
        #expect(h.policy.nextWakeUp == .milliseconds(40) + delay + .milliseconds(1500))
    }

    @Test func pipelineSpacingDeadlineIsReportedAndFullSlotsReportOnlyTimeouts() throws {
        var h = Harness { $0.classifier = .jev; $0.firing = .pipelinedJev }
        #expect(requests(h.policy.handle(.bufferChanged(text: "call mom", composing: false))).count == 1)
        #expect(h.policy.nextWakeUp == .milliseconds(1500))
        h.clock.advance(by: .milliseconds(40))
        #expect(requests(h.policy.handle(.bufferChanged(text: "call mom t", composing: false))).isEmpty)
        #expect(h.policy.nextWakeUp == .milliseconds(100))
        h.advance(to: .milliseconds(100))
        #expect(requests(h.policy.handle(.tick)).map(\.text) == ["call mom t"])
        h.advance(to: .milliseconds(200))
        #expect(requests(h.policy.handle(.bufferChanged(text: "call mom to", composing: false))).count == 1)
        h.advance(to: .milliseconds(300))
        // Three requests are in flight; the queued snapshot waits for a slot, not for time.
        #expect(requests(h.policy.handle(.bufferChanged(text: "call mom tomorrow", composing: false))).isEmpty)
        #expect(h.policy.nextWakeUp == .milliseconds(1500))
    }

    @Test func requestTimeoutIsReportedAndConsumedAtOnePointFiveSeconds() throws {
        var h = Harness()
        let id = try #require(requests(h.policy.handle(.bufferChanged(text: "call mom", composing: false))).first?.id)
        #expect(h.policy.nextWakeUp == .milliseconds(1500))
        h.advance(to: .milliseconds(1500))
        #expect(outcomes(h.policy.handle(.tick)) == [.timeout])
        #expect(h.policy.nextWakeUp == nil)
        _ = h.policy.handle(.failed(id: id, .other, latencyMilliseconds: 1600))
        #expect(h.policy.nextWakeUp == nil)
    }

    @Test func allSourcesWaitCapIsReportedOneSecondAfterTheEdit() throws {
        var h = Harness { $0.wait = .allSources; $0.enterBehavior = .saves }
        _ = h.policy.handle(.gateChanged(.init(decision: .allowed, settled: true, allSourcesSettled: false)))
        h.clock.advance(by: .milliseconds(20))
        let id = try #require(requests(h.policy.handle(.bufferChanged(text: "call mom", composing: false))).first?.id)
        h.advance(to: .milliseconds(220))
        #expect(modes(h.policy.handle(.verdict(id: id, .init(label: .task), latencyMilliseconds: 200))).isEmpty)
        #expect(h.policy.nextWakeUp == .milliseconds(1020))
        h.advance(to: .milliseconds(1019))
        #expect(modes(h.policy.handle(.tick)).isEmpty)
        h.advance(to: .milliseconds(1020))
        #expect(modes(h.policy.handle(.tick)) == [.task])
        #expect(h.policy.nextWakeUp == nil)
    }

    @Test func enterGraceWindowEndIsReportedThreeHundredMillisecondsAfterTheSwitch() throws {
        var h = Harness()
        let id = try #require(requests(h.policy.handle(.bufferChanged(text: "call mom", composing: false))).first?.id)
        h.advance(to: .milliseconds(80))
        #expect(modes(h.policy.handle(.verdict(id: id, .init(label: .note), latencyMilliseconds: 80))) == [.note])
        #expect(h.policy.nextWakeUp == .milliseconds(380))
        h.advance(to: .milliseconds(379))
        #expect(h.policy.handle(.enter).contains { if case .swallowEnter = $0 { true } else { false } })
        h.advance(to: .milliseconds(380))
        #expect(h.policy.handle(.tick).isEmpty)
        #expect(h.policy.nextWakeUp == nil)
        #expect(h.policy.handle(.enter).isEmpty)
    }

    @Test func enterThatSavesReportsNoGraceWindow() throws {
        var h = Harness { $0.enterBehavior = .saves }
        let id = try #require(requests(h.policy.handle(.bufferChanged(text: "call mom", composing: false))).first?.id)
        #expect(modes(h.policy.handle(.verdict(id: id, .init(label: .note), latencyMilliseconds: 80))) == [.note])
        #expect(h.policy.nextWakeUp == nil)
    }

    @Test func earliestOfSeveralPendingDeadlinesIsReported() throws {
        var h = Harness { $0.firing = .debounced; $0.afterSwitch = .keepClassifying }
        _ = h.policy.handle(.bufferChanged(text: "call mom", composing: false))
        h.advance(to: .milliseconds(150))
        let first = try #require(requests(h.policy.handle(.tick)).first?.id)
        h.advance(to: .milliseconds(200))
        #expect(modes(h.policy.handle(.verdict(id: first, .init(label: .note), latencyMilliseconds: 50))) == [.note])
        #expect(h.policy.nextWakeUp == .milliseconds(500))
        h.advance(to: .milliseconds(210))
        _ = h.policy.handle(.bufferChanged(text: "call mom today", composing: false))
        // Debounce at 360 ms precedes the Enter grace end at 500 ms.
        #expect(h.policy.nextWakeUp == .milliseconds(360))
        h.advance(to: .milliseconds(360))
        #expect(requests(h.policy.handle(.tick)).map(\.text) == ["call mom today"])
        // Grace end at 500 ms precedes the new request's timeout at 1860 ms.
        #expect(h.policy.nextWakeUp == .milliseconds(500))
        h.advance(to: .milliseconds(500))
        _ = h.policy.handle(.tick)
        #expect(h.policy.nextWakeUp == .milliseconds(1860))
    }

    @Test func nothingPendingReportsNone() throws {
        var h = Harness()
        #expect(h.policy.nextWakeUp == nil)
        let id = try #require(requests(h.policy.handle(.bufferChanged(text: "call mom", composing: false))).first?.id)
        _ = h.policy.handle(.verdict(id: id, .init(label: .search), latencyMilliseconds: 10))
        #expect(h.policy.nextWakeUp == nil)
        _ = h.policy.handle(.bufferChanged(text: "call mom now", composing: false))
        #expect(h.policy.nextWakeUp != nil)
        _ = h.policy.handle(.dismissed(.dismissed))
        #expect(h.policy.nextWakeUp == nil)

        var disabled = AutomaticSwitch(options: AutomaticSwitchOptions(), now: { .zero })
        _ = disabled.handle(.invoked)
        _ = disabled.handle(.bufferChanged(text: "call mom", composing: false))
        #expect(disabled.nextWakeUp == nil)
    }

    @Test func wakingOnlyAtReportedTimesMatchesTheEarlier25MillisecondTicks() {
        // One script driven both ways yields the same effects at the same moments.
        func run(periodic: Bool) -> [String] {
            let h = Harness { $0.firing = .debounced; $0.agreeingVerdicts = .two }
            var policy = h.policy, log: [String] = [], wakes = 0
            var inFlight: UUID? = nil
            func note(_ effects: [AutomaticSwitch.Effect]) {
                let at = h.clock.now.offset
                for effect in effects {
                    switch effect {
                    case .classify(let id, let text): inFlight = id; log.append("classify \(text) at \(at)")
                    case .enterMode(let mode): log.append("enter \(mode) at \(at)")
                    case .record(.verdict(let row)): log.append("\(row.outcome) at \(at)")
                    default: break
                    }
                }
            }
            func until(_ time: Duration) {
                if periodic {
                    while h.clock.now.offset + .milliseconds(25) <= time {
                        h.clock.advance(by: .milliseconds(25)); note(policy.handle(.tick))
                    }
                } else {
                    while let wake = policy.nextWakeUp, wake <= time, wakes < 100 {
                        wakes += 1; h.advance(to: wake); note(policy.handle(.tick))
                    }
                }
                h.advance(to: time)
            }
            func reply() {
                guard let id = inFlight else { return }
                inFlight = nil
                note(policy.handle(.verdict(id: id, .init(label: .task), latencyMilliseconds: 100)))
            }
            note(policy.handle(.bufferChanged(text: "call mom", composing: false)))
            until(.milliseconds(250)); reply()
            until(.milliseconds(600)); reply()
            until(.milliseconds(1000))
            if !periodic { #expect(wakes == 3) } // debounce, agreement retry, Enter grace end
            return log
        }
        let woken = run(periodic: false), ticked = run(periodic: true)
        #expect(woken == ticked)
        #expect(woken.contains { $0.hasPrefix("enter task") })
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
        func advance(to time: Duration) {
            if time > clock.now.offset { clock.advance(by: time - clock.now.offset) }
        }
    }

    private func outcomes(_ effects: [AutomaticSwitch.Effect]) -> [AutomaticSwitchDiagnostics.Outcome] {
        effects.compactMap { if case .record(.verdict(let value)) = $0 { value.outcome } else { nil } }
    }
    private func modes(_ effects: [AutomaticSwitch.Effect]) -> [CaptureSession.Mode] {
        effects.compactMap { if case .enterMode(let mode) = $0 { mode } else { nil } }
    }
    private func requests(_ effects: [AutomaticSwitch.Effect]) -> [(id: UUID, text: String)] {
        effects.compactMap { if case .classify(let id, let text) = $0 { (id, text) } else { nil } }
    }
}
