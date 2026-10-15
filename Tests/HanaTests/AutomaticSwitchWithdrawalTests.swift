import Foundation
import Testing
@testable import Hana

@Suite @MainActor
struct AutomaticSwitchWithdrawalTests {
    @Test func deletingPastTheSwitchPointWithdrawsAtThePauseAndRetypingUsesTheCache() throws {
        var h = Harness()
        let id = try #require(requests(h.edit("call mom tomorrow ")).first?.id)
        #expect(modes(h.answer(id, .task)) == [.task])
        let deletion = h.edit("call mom tomorro", edit: .replacement(caretAtEnd: true))
        #expect(!returns(deletion) && requests(deletion).isEmpty)
        #expect(h.policy.nextWakeUp == .milliseconds(180))
        h.advance(to: .milliseconds(179))
        #expect(!returns(h.policy.handle(.tick)))
        h.advance(to: .milliseconds(180))
        let withdrawn = h.policy.handle(.tick)
        #expect(returns(withdrawn))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = AutomaticSwitchDiagnostics(file: directory.appendingPathComponent("automatic-switch.jsonl"))
        for effect in withdrawn {
            if case .record(let event) = effect { log.record(event, options: h.policy.options) }
        }
        let rows = try String(contentsOf: log.url, encoding: .utf8)
        #expect(rows.contains("autoswitch.withdrawn") && !rows.contains("call mom"))
        #expect(log.counts().withdrawn == 1 && log.counts().wrongSwitches == 0 && log.counts().reversals == 0)
        let retyped = h.edit("call mom tomorrow ")
        #expect(modes(retyped) == [.task] && requests(retyped).isEmpty)
    }

    @Test func aLateStrongMatchCannotChangeModeDuringTheDeletionBurst() throws {
        var h = Harness { $0.lateStrongMatch = .returnToSearch }
        let id = try #require(requests(h.edit("call mom ")).first?.id)
        _ = h.answer(id, .task)
        _ = h.edit("call mom tomorrow at")
        _ = h.edit("call mom tomorrow a", edit: .replacement(caretAtEnd: true))
        let gate = StrongMatchGate.Evaluation(decision: .blocked(.strongMatch(.application)), settled: true, allSourcesSettled: true)
        #expect(!returns(h.policy.handle(.gateChanged(gate))))
        h.advance(to: .milliseconds(179))
        #expect(!returns(h.policy.handle(.tick)))
        h.advance(to: .milliseconds(180))
        #expect(returns(h.policy.handle(.tick)))
    }

    @Test(arguments: [AutomaticSwitchDiagnostics.ReversalMethod.backspace, .escape])
    func reversingBlocksTheRejectedModeButAllowsTheOtherCaptureMode(method: AutomaticSwitchDiagnostics.ReversalMethod) throws {
        var h = Harness()
        let first = try #require(requests(h.edit("call mom ")).first?.id)
        _ = h.answer(first, .task)
        #expect(returns(h.policy.handle(.reversed(method))))
        #expect(modes(h.edit("call mom  ")).isEmpty)
        h.advance(to: .milliseconds(180))
        #expect(modes(h.policy.handle(.tick)).isEmpty)
        let next = try #require(requests(h.edit("call mom  tomorrow ")).first?.id)
        #expect(modes(h.answer(next, .note)) == [.note])
    }

    @Test func stopUntilClearedStillSuspendsBothModes() throws {
        var h = Harness { $0.reversalBehavior = .stopUntilCleared }
        let id = try #require(requests(h.edit("call mom ")).first?.id)
        _ = h.answer(id, .task)
        _ = h.policy.handle(.reversed(.backspace))
        #expect(requests(h.edit("call mom tomorrow ")).isEmpty)
        h.advance(to: .seconds(1))
        #expect(requests(h.policy.handle(.tick)).isEmpty)
        _ = h.edit("")
        let fresh = try #require(requests(h.edit("buy milk ")).first?.id)
        #expect(modes(h.answer(fresh, .note)) == [.note])
    }

    @Test func clearingAutomaticCaptureWithdrawsAtThePauseAndRearms() throws {
        var h = Harness()
        let first = try #require(requests(h.edit("call mom ")).first?.id)
        _ = h.answer(first, .task)
        #expect(!returns(h.edit("", edit: .replacement(caretAtEnd: true))))
        h.advance(to: .milliseconds(179))
        #expect(!returns(h.policy.handle(.tick)))
        h.advance(to: .milliseconds(180))
        #expect(returns(h.policy.handle(.tick)))
        let next = try #require(requests(h.edit("buy milk ")).first?.id)
        #expect(modes(h.answer(next, .note)) == [.note])
    }

    @Test(arguments: [("call mom ", false), ("call mom mom", true), ("call mom mom edited", true)])
    func editingEarlierOrKeepingTheSwitchPointKeepsTheMode(text: String, atEnd: Bool) throws {
        var h = Harness()
        let id = try #require(requests(h.edit("call mom mom ")).first?.id)
        _ = h.answer(id, .task)
        #expect(!returns(h.edit(text, edit: .replacement(caretAtEnd: atEnd))))
        h.advance(to: .milliseconds(180))
        #expect(!returns(h.policy.handle(.tick)) && h.policy.lastModeChangeWasAutomatic)
    }

    @Test func theSwitchPointIsTheAnswersPrefixRatherThanTheLaterBuffer() throws {
        var h = Harness()
        let id = try #require(requests(h.edit("call mom ")).first?.id)
        _ = h.edit("call mom tomorrow")
        _ = h.answer(id, .task)
        _ = h.edit("call mom", edit: .replacement(caretAtEnd: true))
        h.advance(to: .milliseconds(180))
        #expect(!returns(h.policy.handle(.tick)))
        _ = h.edit("call mo", edit: .replacement(caretAtEnd: true))
        h.advance(to: .milliseconds(360))
        #expect(returns(h.policy.handle(.tick)))
    }

    @Test(arguments: [false, true])
    func deletingBeforeRejectedTextOrClearingLiftsTheVeto(clear: Bool) throws {
        var h = Harness()
        let id = try #require(requests(h.edit("call mom ")).first?.id)
        _ = h.answer(id, .task)
        _ = h.policy.handle(.reversed(.backspace))
        let next = try #require(requests(h.edit("call mom tomorrow ")).first?.id)
        #expect(modes(h.answer(next, .task)).isEmpty)
        _ = h.edit(clear ? "" : "call mo", edit: .replacement(caretAtEnd: true))
        h.advance(to: .milliseconds(180))
        _ = h.policy.handle(.tick)
        let retyped = h.edit("call mom ")
        #expect(modes(retyped) == [.task] && requests(retyped).isEmpty)
    }

    @Test func anExplicitlyEnteredModeNeverWithdraws() {
        var h = Harness()
        _ = h.policy.handle(.manualModeChanged(.note))
        _ = h.edit("call mom mom ")
        _ = h.edit("call ", edit: .replacement(caretAtEnd: true))
        h.advance(to: .milliseconds(180))
        #expect(!returns(h.policy.handle(.tick)))
    }

    @Test func enterSavingTheShownModePreventsPendingWithdrawal() throws {
        var h = Harness()
        let id = try #require(requests(h.edit("call mom ")).first?.id)
        _ = h.answer(id, .task)
        _ = h.edit("call mo", edit: .replacement(caretAtEnd: true))
        _ = h.policy.handle(.eligibilityChanged(false))
        h.advance(to: .milliseconds(180))
        #expect(!returns(h.policy.handle(.tick)) && h.policy.nextWakeUp == nil)
    }

    private struct Harness {
        let clock = TestClock()
        var policy: AutomaticSwitch
        init(_ configure: (inout AutomaticSwitchOptions) -> Void = { _ in }) {
            var options = AutomaticSwitchOptions()
            options.isEnabled = true; options.classifier = .jev; options.firing = .wordPaced
            options.afterSwitch = .stay; options.wait = .none; options.enterBehavior = .saves
            configure(&options)
            let clock = clock
            policy = AutomaticSwitch(options: options, now: { clock.now.offset })
            _ = policy.handle(.invoked)
            _ = policy.handle(.gateChanged(.init(decision: .allowed, settled: true, allSourcesSettled: true)))
        }
        mutating func edit(_ text: String, edit: AutomaticSwitch.Edit? = nil) -> [AutomaticSwitch.Effect] {
            policy.handle(.bufferChanged(text: text, composing: false, edit: edit))
        }
        mutating func answer(_ id: UUID, _ label: ClassifierVerdict.Label, probability: Double = 0.95) -> [AutomaticSwitch.Effect] {
            policy.handle(.verdict(id: id, .init(label: label, probabilities: [label: probability]), latencyMilliseconds: 40))
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
    private func returns(_ effects: [AutomaticSwitch.Effect]) -> Bool {
        effects.contains { if case .returnToSearch = $0 { true } else { false } }
    }
}
