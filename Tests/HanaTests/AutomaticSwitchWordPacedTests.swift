import Foundation
import Testing
@testable import Hana

/// Word-paced Jev firing through the policy seam, with a fake clock and an
/// injected launch memory. No classifier is called.
@Suite @MainActor
struct AutomaticSwitchWordPacedTests {
    @Test(arguments: [(" ", "call mom"), (".", "call mom."), ("?", "call mom?")])
    func wordBoundarySendsImmediately(boundary: String, sent: String) throws {
        var h = Harness()
        for text in ["c", "ca", "cal", "call", "call ", "call m", "call mo", "call mom"] {
            #expect(requests(h.edit(text)).isEmpty)
        }
        #expect(requests(h.edit("call mom" + boundary)).map(\.text) == [sent])
    }

    @Test func apostrophesAndHyphensDoNotCompleteAWord() {
        var h = Harness()
        #expect(requests(h.edit("call mom'")).isEmpty)
        #expect(requests(h.edit("call mom's e-")).isEmpty)
        #expect(requests(h.edit("call mom's e-mail ")).map(\.text) == ["call mom's e-mail"])
    }

    @Test(arguments: [
        // 150 ms gaps → 1.4 × 150 = 210 ms.
        ("buy milk", Duration.milliseconds(150), Duration.milliseconds(210)),
        // 50 ms gaps → 70 ms, raised to the 120 ms floor.
        ("buy milk", Duration.milliseconds(50), Duration.milliseconds(120)),
        // Four gaps only: 180 ms until five gaps exist.
        ("go up", Duration.milliseconds(100), Duration.milliseconds(180)),
    ])
    func pauseSendsAtExactlyTheAdaptiveThreshold(text: String, gap: Duration, threshold: Duration) throws {
        var h = Harness()
        #expect(requests(h.type(text, gap: gap)).isEmpty)
        let lastEdit = h.clock.now.offset
        #expect(h.policy.nextWakeUp == lastEdit + threshold)
        h.advance(to: lastEdit + threshold - .milliseconds(1))
        #expect(requests(h.policy.handle(.tick)).isEmpty)
        h.advance(to: lastEdit + threshold)
        #expect(requests(h.policy.handle(.tick)).map(\.text) == [text])
    }

    @Test func typingGapsAreSharedAcrossSessionsInTheLaunch() {
        let memory = JevLaunchMemory()
        var first = Harness(memory: memory)
        _ = first.type("go up now", gap: .milliseconds(200))
        _ = first.policy.handle(.dismissed(.dismissed))
        var second = Harness(memory: memory)
        _ = second.edit("buy milk")
        // Eight gaps of 200 ms from the earlier session: 280 ms, not 180 ms.
        #expect(second.policy.nextWakeUp == .milliseconds(280))
    }

    @Test func noSendForOneNormalizedWord() {
        var h = Harness()
        #expect(requests(h.edit("remind ")).isEmpty)
        #expect(requests(h.edit("remind  ")).isEmpty)
        h.advance(to: .seconds(1))
        #expect(requests(h.policy.handle(.tick)).isEmpty)
        #expect(requests(h.edit("  remind")).isEmpty)
        h.advance(to: .seconds(2))
        #expect(requests(h.policy.handle(.tick)).isEmpty)
    }

    @Test func noSendForGateBlockedText() {
        var h = Harness()
        let blocked = StrongMatchGate.Evaluation(decision: .blocked(.strongMatch(.note)), settled: true, allSourcesSettled: true)
        let boundary = h.policy.handle(.bufferChanged(text: "existing note ", composing: false, gate: blocked))
        #expect(requests(boundary).isEmpty && outcomes(boundary) == [.blocked])
        _ = h.policy.handle(.bufferChanged(text: "existing note again", composing: false, gate: blocked))
        h.advance(to: .seconds(1))
        #expect(requests(h.policy.handle(.tick)).isEmpty)
    }

    @Test func noSendWhileComposing() {
        var h = Harness()
        #expect(requests(h.edit("call mom ", composing: true)).isEmpty)
        #expect(h.policy.nextWakeUp == nil)
        h.advance(to: .seconds(1))
        #expect(requests(h.policy.handle(.tick)).isEmpty)
        // Committing the composition is an edit; its pause may send.
        _ = h.edit("call mom ")
        h.advance(to: .milliseconds(1180))
        #expect(requests(h.policy.handle(.tick)).map(\.text) == ["call mom"])
    }

    @Test func noSendAfterASwitchThatStays() throws {
        var h = Harness()
        let first = try #require(requests(h.edit("call mom ")).first?.id)
        let second = try #require(requests(h.edit("call mom tomorrow ")).first?.id)
        let switched = h.policy.handle(.verdict(id: first, task, latencyMilliseconds: 40))
        #expect(modes(switched) == [.task])
        #expect(cancels(switched) == [second])
        #expect(requests(h.edit("call mom tomorrow at ")).isEmpty)
        #expect(requests(h.edit("call mom tomorrow at noon")).isEmpty)
        h.advance(to: .seconds(2))
        #expect(requests(h.policy.handle(.tick)).isEmpty)
    }

    @Test func aPauseFollowedByASpaceSendsOnce() throws {
        var h = Harness()
        _ = h.edit("call mom")
        h.advance(to: .milliseconds(180))
        let first = try #require(requests(h.policy.handle(.tick)).first)
        #expect(first.text == "call mom")
        // Identical to the request in flight.
        #expect(requests(h.edit("call mom ")).isEmpty)
        _ = h.policy.handle(.verdict(id: first.id, search, latencyMilliseconds: 40))
        // Identical to the answered text: repeated spaces are invisible.
        _ = h.edit("call mom  ")
        h.advance(to: .seconds(1))
        #expect(requests(h.policy.handle(.tick)).isEmpty)
    }

    @Test func nfdAndNfcAreTheSameText() throws {
        var h = Harness()
        // Typed decomposed (e + combining acute); sent composed.
        _ = h.edit("cafe\u{301} notes")
        h.advance(to: .milliseconds(180))
        let first = try #require(requests(h.policy.handle(.tick)).first)
        #expect(first.text.unicodeScalars.elementsEqual("caf\u{E9} notes".unicodeScalars))
        #expect(requests(h.edit("cafe\u{301} notes ")).isEmpty)
        // Replacing the decomposed form with the composed one keeps the request and sends nothing new.
        let recomposed = h.edit("caf\u{E9} notes ")
        #expect(cancels(recomposed).isEmpty && requests(recomposed).isEmpty)
        h.advance(to: .seconds(1))
        #expect(requests(h.policy.handle(.tick)).isEmpty)
        #expect(modes(h.policy.handle(.verdict(id: first.id, note, latencyMilliseconds: 40))) == [.note])
    }

    @Test func capacityIsTwoPlusOneWaitingSlotHoldingOnlyTheNewestText() throws {
        var h = Harness()
        let first = try #require(requests(h.edit("call mom ")).first?.id)
        #expect(requests(h.edit("call mom tomorrow ")).map(\.text) == ["call mom tomorrow"])
        #expect(requests(h.edit("call mom tomorrow at ")).isEmpty)
        #expect(requests(h.edit("call mom tomorrow at noon ")).isEmpty)
        #expect(h.memory.inFlightCount == 2)
        let freed = h.policy.handle(.verdict(id: first, search, latencyMilliseconds: 40))
        #expect(requests(freed).map(\.text) == ["call mom tomorrow at noon"])
        #expect(h.memory.inFlightCount == 2)
    }

    @Test func waitingTextIsDroppedWhenItIsRemoved() throws {
        var h = Harness()
        let first = try #require(requests(h.edit("call mom ")).first?.id)
        _ = h.edit("call mom tomorrow ")
        #expect(requests(h.edit("call mom tomorrow at ")).isEmpty)
        _ = h.edit("call mom tomorrow")
        #expect(requests(h.policy.handle(.verdict(id: first, search, latencyMilliseconds: 40))).isEmpty)
    }

    @Test func capacityCountsRequestsLeftOverFromAnEarlierSession() throws {
        let memory = JevLaunchMemory()
        var first = Harness(memory: memory)
        let a = try #require(requests(first.edit("call mom ")).first?.id)
        let b = try #require(requests(first.edit("call mom tomorrow ")).first?.id)
        #expect(cancels(first.policy.handle(.dismissed(.dismissed))) == [a, b])

        var second = Harness(memory: memory)
        #expect(requests(second.edit("buy milk ")).isEmpty)
        // Mac Interaction reports that the earlier session's work has ended.
        memory.requestFinished(a)
        #expect(requests(second.policy.handle(.slotReleased)).map(\.text) == ["buy milk"])
        #expect(requests(second.edit("buy milk now ")).isEmpty)
        // A completion reaching the closed session's policy also frees its slot.
        _ = first.policy.handle(.failed(id: b, .other, latencyMilliseconds: 90))
        #expect(requests(second.policy.handle(.slotReleased)).map(\.text) == ["buy milk now"])
    }

    @Test func answerForEarlierWordsSwitches() throws {
        var h = Harness()
        let first = try #require(requests(h.edit("call mom ")).first?.id)
        #expect(requests(h.edit("call mom tomorrow")).isEmpty)
        #expect(modes(h.policy.handle(.verdict(id: first, task, latencyMilliseconds: 40))) == [.task])
    }

    @Test(arguments: ["call mo", "call", "buy milk"])
    func answerForRemovedTextDoesNotSwitch(replacement: String) throws {
        var h = Harness()
        let first = try #require(requests(h.edit("call mom ")).first?.id)
        #expect(cancels(h.edit(replacement)) == [first])
        let late = h.policy.handle(.verdict(id: first, task, latencyMilliseconds: 40))
        #expect(outcomes(late) == [.stale] && modes(late).isEmpty)
    }

    @Test func appendingKeepsEveryRequestRunning() throws {
        var h = Harness()
        _ = h.edit("call mom ")
        #expect(cancels(h.edit("call mom tomorrow ")).isEmpty)
        #expect(cancels(h.edit("call mom tomorrow at noon")).isEmpty)
    }

    @Test(arguments: [false, true])
    func answerOlderThanAHandledAnswerDoesNotSwitch(newerFails: Bool) throws {
        var h = Harness()
        let first = try #require(requests(h.edit("call mom ")).first?.id)
        let second = try #require(requests(h.edit("call mom recipes ")).first?.id)
        _ = h.policy.handle(newerFails ? .failed(id: second, .network, latencyMilliseconds: 20)
            : .verdict(id: second, search, latencyMilliseconds: 20))
        let old = h.policy.handle(.verdict(id: first, task, latencyMilliseconds: 200))
        #expect(outcomes(old) == [.stale] && modes(old).isEmpty)
    }

    @Test(arguments: [1199, 1200])
    func answerLaterThanOnePointTwoSecondsIsATimeout(answerAt: Int) throws {
        var h = Harness()
        let first = try #require(requests(h.edit("call mom ")).first?.id)
        #expect(h.policy.nextWakeUp == .milliseconds(1200))
        h.advance(to: .milliseconds(answerAt))
        let answered = h.policy.handle(.verdict(id: first, task, latencyMilliseconds: Double(answerAt)))
        if answerAt < 1200 {
            #expect(modes(answered) == [.task])
        } else {
            #expect(modes(answered).isEmpty && outcomes(answered) == [.timeout])
        }
    }

    @Test func deadlineTimesOutAndKeepsTheSlotUntilTheProviderAcknowledges() throws {
        var h = Harness()
        let first = try #require(requests(h.edit("call mom ")).first?.id)
        h.advance(to: .milliseconds(1199))
        #expect(outcomes(h.policy.handle(.tick)).isEmpty)
        h.advance(to: .milliseconds(1200))
        let timeout = h.policy.handle(.tick)
        #expect(outcomes(timeout) == [.timeout] && cancels(timeout) == [first])
        #expect(h.memory.inFlightCount == 1)
        let acknowledged = h.policy.handle(.failed(id: first, .other, latencyMilliseconds: 1250))
        #expect(outcomes(acknowledged) == [.stale])
        #expect(rows(acknowledged).first?.latencyMilliseconds == nil)
        #expect(h.memory.inFlightCount == 0)
    }

    @Test(arguments: [false, true])
    func clearingAutomaticCaptureReturnsSearchAndRearmsDespiteReversalSuspension(reverseFirst: Bool) throws {
        var h = Harness { $0.reversalBehavior = .stopUntilCleared }
        let first = try #require(requests(h.edit("call mom ")).first?.id)
        _ = h.policy.handle(.verdict(id: first, task, latencyMilliseconds: 20))
        if reverseFirst {
            #expect(returns(h.policy.handle(.reversed(.backspace))))
            #expect(requests(h.edit("call mom tomorrow ")).isEmpty)
        }
        let cleared = h.edit("")
        #expect(!returns(cleared))
        h.advance(to: .milliseconds(180))
        #expect(returns(h.policy.handle(.tick)) == !reverseFirst)
        #expect(!h.policy.lastModeChangeWasAutomatic)
        #expect(requests(h.edit("buy milk ")).map(\.text) == ["buy milk"])
    }

    @Test func gateBecomingAllowedSendsAfterThePause() {
        var h = Harness()
        let unavailable = StrongMatchGate.Evaluation(decision: .blocked(.collectionUnavailable), settled: false, allSourcesSettled: false)
        _ = h.policy.handle(.bufferChanged(text: "buy milk", composing: false, gate: unavailable))
        h.advance(to: .milliseconds(50))
        #expect(requests(h.policy.handle(.gateChanged(Harness.allowed))).isEmpty)
        #expect(h.policy.nextWakeUp == .milliseconds(180))
        h.advance(to: .milliseconds(180))
        #expect(requests(h.policy.handle(.tick)).map(\.text) == ["buy milk"])
    }

    @Test func secondAgreeingVerdictComesFromTheNextAnswerNeverAResend() throws {
        var h = Harness { $0.agreeingVerdicts = .two }
        let first = try #require(requests(h.edit("call mom ")).first?.id)
        #expect(outcomes(h.policy.handle(.verdict(id: first, task, latencyMilliseconds: 20))) == [.awaitingAgreement])
        h.advance(to: .seconds(1))
        #expect(requests(h.policy.handle(.tick)).isEmpty)
        let second = try #require(requests(h.edit("call mom tomorrow ")).first?.id)
        #expect(modes(h.policy.handle(.verdict(id: second, task, latencyMilliseconds: 20))) == [.task])
    }

    @Test func sessionRecordsRequestsSentAndCancelledRequestsAddNoLatency() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = AutomaticSwitchDiagnostics(file: directory.appendingPathComponent("automatic-switch.jsonl"))
        var h = Harness()
        func record(_ effects: [AutomaticSwitch.Effect]) {
            for effect in effects { if case .record(let event) = effect { log.record(event, options: h.policy.options) } }
        }
        let secret = "private word บ้าน"
        let first = try #require(requests(h.edit(secret + " ")).first?.id)
        record(h.policy.handle(.verdict(id: first, search, latencyMilliseconds: 40)))
        let second = try #require(requests(h.edit(secret + " secret ")).first?.id)
        #expect(cancels(h.edit("private word")) == [second])
        record(h.policy.handle(.failed(id: second, .other, latencyMilliseconds: 90)))
        _ = h.edit("private word again ")
        h.advance(to: .milliseconds(180))
        let third = try #require(requests(h.policy.handle(.tick)).first?.id)
        let dismissed = h.policy.handle(.dismissed(.dismissed))
        #expect(cancels(dismissed) == [third])
        record(dismissed)
        record(h.policy.handle(.failed(id: third, .other, latencyMilliseconds: 30)))

        let counts = log.counts()
        #expect(counts.latencies[.jev]?.medianMilliseconds == 40 && counts.latencies[.jev]?.maximumMilliseconds == 40)
        let text = try String(contentsOf: log.url, encoding: .utf8)
        #expect(!text.contains(secret) && !text.contains("private word") && !text.contains("secret"))
        let decoded = try text.split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        #expect(decoded.filter { $0["latencyMilliseconds"] != nil }.count == 1)
        let sessions = decoded.filter { $0["event"] as? String == "autoswitch.session" }
        #expect(sessions.count == 1 && sessions.first?["requestsSent"] as? Int == 3)
    }

    private let search = ClassifierVerdict(label: .search, probabilities: [.search: 0.95])
    private let note = ClassifierVerdict(label: .note, probabilities: [.note: 0.95])
    private let task = ClassifierVerdict(label: .task, probabilities: [.task: 0.95])

    private struct Harness {
        static let allowed = StrongMatchGate.Evaluation(decision: .allowed, settled: true, allSourcesSettled: true)
        let clock = TestClock()
        let memory: JevLaunchMemory
        var policy: AutomaticSwitch
        init(memory: JevLaunchMemory = JevLaunchMemory(), _ configure: (inout AutomaticSwitchOptions) -> Void = { _ in }) {
            var options = AutomaticSwitchOptions()
            options.isEnabled = true; options.classifier = .jev; options.firing = .wordPaced
            configure(&options)
            self.memory = memory
            let clock = clock
            policy = AutomaticSwitch(options: options, memory: memory, now: { clock.now.offset })
            _ = policy.handle(.invoked)
            _ = policy.handle(.gateChanged(Self.allowed))
        }
        mutating func edit(_ text: String, composing: Bool = false) -> [AutomaticSwitch.Effect] {
            policy.handle(.bufferChanged(text: text, composing: composing))
        }
        /// Types `text` into an empty buffer one character at a time, `gap` apart, without ticks.
        mutating func type(_ text: String, gap: Duration) -> [AutomaticSwitch.Effect] {
            var typed = "", effects: [AutomaticSwitch.Effect] = []
            for character in text {
                if !typed.isEmpty { clock.advance(by: gap) }
                typed.append(character)
                effects += edit(typed)
            }
            return effects
        }
        func advance(to time: Duration) {
            if time > clock.now.offset { clock.advance(by: time - clock.now.offset) }
        }
    }

    private func requests(_ effects: [AutomaticSwitch.Effect]) -> [(id: UUID, text: String)] {
        effects.compactMap { if case .classify(let id, let text) = $0 { (id, text) } else { nil } }
    }
    private func cancels(_ effects: [AutomaticSwitch.Effect]) -> [UUID] {
        effects.compactMap { if case .cancel(let id) = $0 { id } else { nil } }
    }
    private func modes(_ effects: [AutomaticSwitch.Effect]) -> [CaptureSession.Mode] {
        effects.compactMap { if case .enterMode(let mode) = $0 { mode } else { nil } }
    }
    private func returns(_ effects: [AutomaticSwitch.Effect]) -> Bool {
        effects.contains { if case .returnToSearch = $0 { true } else { false } }
    }
    private func rows(_ effects: [AutomaticSwitch.Effect]) -> [AutomaticSwitchDiagnostics.Verdict] {
        effects.compactMap { if case .record(.verdict(let value)) = $0 { value } else { nil } }
    }
    private func outcomes(_ effects: [AutomaticSwitch.Effect]) -> [AutomaticSwitchDiagnostics.Outcome] {
        rows(effects).map(\.outcome)
    }
}
