import Foundation
import Testing
@testable import Hana

@Suite @MainActor
struct AutomaticSwitchSubmissionTests {
    @Test(arguments: AutomaticSwitchOptions.Firing.allCases, [ClassifierVerdict.Label.note, .task])
    func enterFlushesTheFullTextAndSavesOnce(firing: AutomaticSwitchOptions.Firing, label: ClassifierVerdict.Label) throws {
        var h = Harness { $0.firing = firing }
        let edit = h.edit("call mom tomorrow")
        let enter = h.policy.handle(.submitRequested)
        let sends = requests(edit + enter)
        #expect(sends.map(\.text) == ["call mom tomorrow"])
        #expect(h.policy.isAwaitingSubmission)
        #expect(requests(h.policy.handle(.submitRequested)).isEmpty)
        let id = try #require(sends.first?.id)
        let answer = h.answer(id, label)
        #expect(commits(answer) == ["call mom tomorrow"])
        #expect(!h.policy.isAwaitingSubmission)
        #expect(commits(h.answer(id, label)).isEmpty)
    }

    @Test func prefixRepliesCannotSwitchOrSaveTheFinishedText() throws {
        var h = Harness()
        let prefix = try #require(requests(h.edit("call mom ")).first?.id)
        _ = h.edit("call mom tomorrow")
        let full = try #require(requests(h.policy.handle(.submitRequested)).first)
        #expect(full.text == "call mom tomorrow")
        let earlier = h.answer(prefix, .note)
        #expect(commits(earlier).isEmpty && modes(earlier).isEmpty)
        #expect(h.policy.isAwaitingSubmission)
        #expect(commits(h.answer(full.id, .task)) == ["call mom tomorrow"])
    }

    @Test func busySlotsKeepOnlyTheFullSubmissionWaiting() throws {
        var h = Harness()
        let first = try #require(requests(h.edit("call mom ")).first?.id)
        let second = try #require(requests(h.edit("call mom tomorrow ")).first?.id)
        _ = h.edit("call mom tomorrow at noon")
        #expect(requests(h.policy.handle(.submitRequested)).isEmpty)
        #expect(h.policy.isAwaitingSubmission && h.memory.inFlightCount == 2)
        let released = h.answer(first, .note)
        let full = try #require(requests(released).first)
        #expect(full.text == "call mom tomorrow at noon")
        #expect(modes(h.answer(second, .task)).isEmpty)
        #expect(commits(h.answer(full.id, .task)) == [full.text])
    }

    @Test func exactPendingRequestIsReusedAndRawTextIsSaved() throws {
        var h = Harness()
        let raw = "call  mom บ้าน "
        let id = try #require(requests(h.edit(raw)).first?.id)
        #expect(requests(h.policy.handle(.submitRequested)).isEmpty)
        #expect(commits(h.answer(id, .note)) == [raw])
    }

    @Test func exactCachedDecisionCanCommitWithoutANewRequest() {
        var h = Harness()
        h.memory.remember(.init(label: .task, probabilities: [.task: 0.95]),
                          for: "call mom", identity: .current)
        // Simulate a gate which was unsettled when the cache was read.
        _ = h.policy.handle(.gateChanged(.init(decision: .allowed, settled: false, allSourcesSettled: false)))
        _ = h.edit("call mom")
        let effects = h.policy.requestSubmission(gate: Harness.allowed)
        #expect(requests(effects).isEmpty && commits(effects) == ["call mom"])
    }

    @Test(arguments: [ClassifierVerdict.Label.search, .unsure, .task, .note])
    func rejectedDecisionsKeepTheBuffer(label: ClassifierVerdict.Label) throws {
        var h = Harness()
        _ = h.edit("call mom tomorrow")
        let id = try #require(requests(h.policy.handle(.submitRequested)).first?.id)
        let effects = h.answer(id, label, probability: label == .task || label == .note ? 0.4 : 0.95)
        #expect(commits(effects).isEmpty && modes(effects).isEmpty)
        #expect(!h.policy.isAwaitingSubmission && h.policy.submissionOutcome == .undecided)
    }

    @Test func aSingleModerateConfidenceAnswerDoesNotBypassWordPacedAgreement() throws {
        var h = Harness()
        _ = h.edit("call mom tomorrow")
        let id = try #require(requests(h.policy.handle(.submitRequested)).first?.id)
        #expect(commits(h.answer(id, .task, probability: 0.8)).isEmpty)
        #expect(h.policy.submissionOutcome == .undecided)
    }

    @Test func reusingTheSameAnswerOnEnterCannotManufactureAgreement() throws {
        var h = Harness()
        let id = try #require(requests(h.edit("call mom tomorrow ")).first?.id)
        #expect(modes(h.answer(id, .task, probability: 0.8)).isEmpty)
        let effects = h.policy.handle(.submitRequested)
        #expect(requests(effects).isEmpty && commits(effects).isEmpty)
        #expect(h.policy.submissionOutcome == .undecided)
    }

    @Test func multilineTaskIsNeverFlattenedOrSaved() throws {
        var h = Harness()
        _ = h.edit("call mom\ntomorrow")
        let id = try #require(requests(h.policy.handle(.submitRequested)).first?.id)
        #expect(commits(h.answer(id, .task)).isEmpty)
        #expect(h.policy.submissionOutcome == .undecided)
    }

    @Test(arguments: ["edit", "replace", "navigate", "dismiss", "mode", "compose"])
    func changingIntentCancelsTheQueuedSave(action: String) throws {
        var h = Harness { $0.navigationSuspends = false }
        _ = h.edit("call mom tomorrow")
        let id = try #require(requests(h.policy.handle(.submitRequested)).first?.id)
        switch action {
        case "edit": _ = h.edit("call mom tomorrow please")
        case "replace": _ = h.policy.handle(.bufferChanged(text: "call mom tomorrow", composing: false, edit: .replacement(caretAtEnd: true)))
        case "navigate": _ = h.policy.handle(.navigated)
        case "dismiss": _ = h.policy.handle(.dismissed(.dismissed))
        case "mode": _ = h.policy.handle(.manualModeChanged(.note))
        default: _ = h.policy.handle(.bufferChanged(text: "call mom tomorrow", composing: true))
        }
        #expect(!h.policy.isAwaitingSubmission)
        #expect(commits(h.answer(id, .task)).isEmpty)
    }

    @Test func timeoutAndLateAnswerCannotSave() throws {
        var h = Harness()
        _ = h.edit("call mom tomorrow")
        let id = try #require(requests(h.policy.handle(.submitRequested)).first?.id)
        h.clock.advance(by: .milliseconds(1200))
        #expect(commits(h.policy.handle(.tick)).isEmpty)
        #expect(h.policy.submissionOutcome == .timedOut && !h.policy.isAwaitingSubmission)
        #expect(commits(h.answer(id, .task)).isEmpty)
    }

    @Test func failureAndBackoffEndTheWait() throws {
        var h = Harness()
        _ = h.edit("call mom tomorrow")
        let id = try #require(requests(h.policy.handle(.submitRequested)).first?.id)
        _ = h.policy.handle(.failed(id: id, .authentication, latencyMilliseconds: 20))
        #expect(h.policy.submissionOutcome == .failed && !h.policy.isAwaitingSubmission)
        let retry = h.policy.handle(.submitRequested)
        #expect(requests(retry).isEmpty && !h.policy.isAwaitingSubmission)
        #expect(h.policy.submissionOutcome == .failed)
    }

    @Test func lateStrongMatchCancelsSaveWithoutOpeningAnything() throws {
        var h = Harness()
        _ = h.edit("call mom tomorrow")
        let id = try #require(requests(h.policy.handle(.submitRequested)).first?.id)
        _ = h.policy.handle(.gateChanged(.init(decision: .blocked(.strongMatch(.file)), settled: true, allSourcesSettled: true)))
        #expect(h.policy.submissionOutcome == .blocked && !h.policy.isAwaitingSubmission)
        #expect(commits(h.answer(id, .task)).isEmpty)
    }

    @Test func fullDecisionWaitsForTheSearchGateToSettle() throws {
        var h = Harness()
        _ = h.edit("call mom tomorrow")
        _ = h.policy.handle(.gateChanged(.init(decision: .allowed, settled: false, allSourcesSettled: false)))
        let id = try #require(requests(h.policy.handle(.submitRequested)).first?.id)
        #expect(commits(h.answer(id, .task)).isEmpty && h.policy.isAwaitingSubmission)
        #expect(commits(h.policy.handle(.gateChanged(Harness.allowed))) == ["call mom tomorrow"])
    }

    @Test func anEarlierFailureCannotEraseTheFullDecisionWaitingForSearch() throws {
        var h = Harness()
        let prefix = try #require(requests(h.edit("call mom ")).first?.id)
        _ = h.edit("call mom tomorrow")
        _ = h.policy.handle(.gateChanged(.init(decision: .allowed, settled: false, allSourcesSettled: false)))
        let full = try #require(requests(h.policy.handle(.submitRequested)).first?.id)
        #expect(commits(h.answer(full, .task)).isEmpty)
        _ = h.policy.handle(.failed(id: prefix, .network, latencyMilliseconds: 20))
        #expect(h.policy.isAwaitingSubmission)
        #expect(commits(h.policy.handle(.gateChanged(Harness.allowed))) == ["call mom tomorrow"])
    }

    @Test(arguments: [AutomaticSwitchOptions.Firing.wordPaced, .everyKeystroke])
    func enterReusesAFullAnswerAlreadyWaitingForSearch(firing: AutomaticSwitchOptions.Firing) throws {
        var h = Harness { $0.firing = firing }
        _ = h.policy.handle(.gateChanged(.init(decision: .allowed, settled: false, allSourcesSettled: false)))
        let edited = h.edit("call mom tomorrow ")
        let id = try #require(requests(edited).first?.id)
        #expect(modes(h.answer(id, .task)).isEmpty)
        let enter = h.policy.handle(.submitRequested)
        #expect(requests(enter).isEmpty && h.policy.isAwaitingSubmission)
        #expect(commits(h.policy.handle(.gateChanged(Harness.allowed))) == ["call mom tomorrow "])
    }

    @Test(arguments: [StrongMatchGate.Reason.oneWord, .strongMatch(.application), .strongMatch(.note), .strongMatch(.task), .strongMatch(.file), .collectionUnavailable])
    func blockedSearchKeepsNormalEnter(reason: StrongMatchGate.Reason) {
        var h = Harness()
        _ = h.edit("call mom tomorrow")
        let effects = h.policy.requestSubmission(gate: .init(decision: .blocked(reason), settled: true, allSourcesSettled: true))
        #expect(effects.isEmpty && !h.policy.isAwaitingSubmission)
    }

    private struct Harness {
        static let allowed = StrongMatchGate.Evaluation(decision: .allowed, settled: true, allSourcesSettled: true)
        let clock = TestClock()
        let memory = JevLaunchMemory()
        var policy: AutomaticSwitch
        init(_ configure: (inout AutomaticSwitchOptions) -> Void = { _ in }) {
            var options = AutomaticSwitchOptions()
            options.isEnabled = true; options.classifier = .jev; options.firing = .wordPaced
            options.wait = .appsAndCollection
            configure(&options)
            let clock = clock
            policy = AutomaticSwitch(options: options, memory: memory, now: { clock.now.offset })
            _ = policy.handle(.invoked)
            _ = policy.handle(.gateChanged(Self.allowed))
        }
        mutating func edit(_ text: String) -> [AutomaticSwitch.Effect] {
            policy.handle(.bufferChanged(text: text, composing: false, edit: .append))
        }
        mutating func answer(_ id: UUID, _ label: ClassifierVerdict.Label, probability: Double = 0.95) -> [AutomaticSwitch.Effect] {
            policy.handle(.verdict(id: id, .init(label: label, probabilities: [label: probability]), latencyMilliseconds: 20))
        }
    }
    private func requests(_ effects: [AutomaticSwitch.Effect]) -> [(id: UUID, text: String)] {
        effects.compactMap { if case .classify(let id, let text) = $0 { (id, text) } else { nil } }
    }
    private func commits(_ effects: [AutomaticSwitch.Effect]) -> [String] {
        effects.compactMap { if case .submitCapture(let text, _) = $0 { text } else { nil } }
    }
    private func modes(_ effects: [AutomaticSwitch.Effect]) -> [CaptureSession.Mode] {
        effects.compactMap { if case .enterMode(let mode) = $0 { mode } else { nil } }
    }
}
