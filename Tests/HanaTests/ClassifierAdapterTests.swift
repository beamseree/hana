import Foundation
import Testing
@testable import Hana

@MainActor
struct ClassifierAdapterTests {
    @Test func savedOrRemovedKeyTakesEffectOnAnAlreadyCreatedAdapter() async throws {
        var key: String? = "first-key"
        var authorizations: [String?] = []
        let adapter = JevClassifier(keyProvider: { key }, transport: { request in
            authorizations.append(request.value(forHTTPHeaderField: "Authorization"))
            return .init(data: Data(Self.taskResponse.utf8), status: 200)
        })
        _ = try await adapter.classify("call mom")
        key = "replacement-key"
        _ = try await adapter.classify("call mom tomorrow")
        key = nil
        do { _ = try await adapter.classify("call mom tomorrow morning"); Issue.record("Expected missing key") }
        catch { #expect((error as? ClassifierFailure)?.kind == .unavailable) }
        #expect(authorizations == ["Bearer first-key", "Bearer replacement-key"])
    }
    @Test(arguments: ["5", "Thu, 15 Oct 2026 12:00:05 GMT", "invalid", ""])
    func jevRateLimitCarriesAUsableRetryAfter(_ header: String) async {
        let adapter = JevClassifier(key: "secret", now: { Date(timeIntervalSince1970: 1792065600) },
            transport: { _ in .init(data: Data(), status: 429, retryAfter: header) })
        do { _ = try await adapter.classify("call mom"); Issue.record("Expected rate limit") }
        catch {
            let failure = error as? ClassifierFailure
            #expect(failure?.kind == .rateLimited)
            #expect(failure?.retryAfter == (header == "5" || header.hasPrefix("Thu,") ? .seconds(5) : nil))
        }
    }
    @Test func jevSerializesRequestAndChoiceKeysInStableAlphabeticalOrder() async throws {
        let adapter = JevClassifier(key: "test-secret", transport: { request in
            let body = String(decoding: try #require(request.httpBody), as: UTF8.self)
            #expect(body.hasPrefix(#"{"model":"jev-1.13.0","questions":{"classify_input":{"criteria":{"Other":"#))
            let other = try #require(body.range(of: #""Other":"#))
            let search = try #require(body.range(of: #""Search":"#))
            let task = try #require(body.range(of: #""Task":"#))
            #expect(other.lowerBound < search.lowerBound && search.lowerBound < task.lowerBound)
            #expect(body.hasSuffix(#","state":"call mom"}"#))
            return .init(data: Data(Self.taskResponse.utf8), status: 200)
        })
        _ = try await adapter.classify("call mom")
    }
    @Test func jevUsesPinnedChoiceRequestAndWinningProbability() async throws {
        let adapter = JevClassifier(key: "test-secret", transport: { request in
            #expect(request.url?.absoluteString == "https://api.typesafe.ai/v1/systemone")
            #expect(request.httpMethod == "POST")
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer test-secret")
            let data = try #require(request.httpBody)
            let body = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            #expect(body["model"] as? String == "jev-1.13.0")
            #expect(body["state"] as? String == "call mom tomorrow")
            let questions = try #require(body["questions"] as? [String: [String: Any]])
            #expect(questions.count == 1)
            #expect(questions["classify_input"]?["type"] as? String == "choice")
            let criteria = try #require(questions["classify_input"]?["criteria"] as? [String: String])
            #expect(criteria["Search"] == "Find an app, file, or an existing note or task on this Mac")
            #expect(Set(criteria.keys) == ["Search", "Task", "Other"])
            #expect(criteria["Note"] == nil)
            #expect(criteria["Other"] == "Information, observations, ideas, incomplete or ambiguous text, or anything that is not clearly a search or a new task")
            return .init(data: Data(Self.taskResponse.utf8), status: 200)
        })
        let verdict = try await adapter.classify("call mom tomorrow")
        #expect(verdict.label == .task)
        #expect(verdict.probability == 0.9)
        #expect(verdict.probabilities?[.search] == 0.03)
        #expect(verdict.wordingVersion == .jevTaskFocusedV1)
        #expect(verdict.probabilities?[.note] == nil)
    }

    @Test func foundationUnavailableNeverRunsModel() async throws {
        let adapter = FoundationModelsClassifier(unsure: true, availability: { .appleIntelligenceOff }, makeSession: {
            Issue.record("Unavailable model must not create a session")
            return .init(prewarm: {}, respond: { _ in .task })
        })
        adapter.prewarm()
        await #expect(throws: ClassifierFailure.self) { try await adapter.classify("call mom") }
        #expect(FoundationModelAvailability.appleIntelligenceOff.menuText == "Apple Intelligence is off")
    }

    @Test(arguments: [(401, AutomaticSwitchDiagnostics.ErrorKind.authentication), (429, .rateLimited), (503, .network)])
    func jevHTTPFailuresAreContentFree(status: Int, kind: AutomaticSwitchDiagnostics.ErrorKind) async {
        let adapter = JevClassifier(key: "secret", transport: { _ in .init(data: Data("private input".utf8), status: status) })
        do { _ = try await adapter.classify("private input"); Issue.record("Expected failure") }
        catch { #expect((error as? ClassifierFailure)?.kind == kind) }
    }
    @Test func jevOtherMapsToUnsure() async throws {
        let json = Self.taskResponse.replacingOccurrences(of: #""choice":"Task""#, with: #""choice":"Other""#)
            .replacingOccurrences(of: #""Task":0.9,"Other":0.07"#, with: #""Task":0.07,"Other":0.9"#)
        let adapter = JevClassifier(key: "secret", transport: { _ in .init(data: Data(json.utf8), status: 200) })
        let verdict = try await adapter.classify("unclear input")
        #expect(verdict.label == .unsure && verdict.probability == 0.9)
    }
    @Test(arguments: ["{}", "not json", taskResponse.replacingOccurrences(of: "0.9", with: "1.9"),
        taskResponse.replacingOccurrences(of: #""Task":0.9"#, with: #""Task":0.8"#),
        taskResponse.replacingOccurrences(of: #""choice":"Task""#, with: #""choice":"Search""#),
        taskResponse.replacingOccurrences(of: "jev-1.13.0", with: "jev-latest"),
        taskResponse.replacingOccurrences(of: #""Other":0.07"#, with: #""Unknown":0.07"#)])
    func jevMalformedResponsesFail(_ body: String) async {
        let adapter = JevClassifier(key: "secret", transport: { _ in .init(data: Data(body.utf8), status: 200) })
        do { _ = try await adapter.classify("private input"); Issue.record("Expected malformed failure") }
        catch { #expect((error as? ClassifierFailure)?.kind == .malformedResponse) }
    }
    @Test func jevTimeoutAndCancellationFailWithoutVerdict() async {
        let timedOut = JevClassifier(key: "secret", transport: { _ in throw URLError(.timedOut) })
        await #expect(throws: ClassifierFailure.self) { try await timedOut.classify("private input") }
        let cancelled = JevClassifier(key: "secret", transport: { _ in throw URLError(.cancelled) })
        await #expect(throws: CancellationError.self) { try await cancelled.classify("private input") }
        let ignoresCancellation = JevClassifier(key: "secret", transport: { _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return .init(data: Data(Self.taskResponse.utf8), status: 200)
        })
        let task = Task { try await ignoresCancellation.classify("private input") }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
    @Test func foundationConsumesWarmedSessionThenUsesFreshSessions() async throws {
        var created = 0, warmed = 0
        let adapter = FoundationModelsClassifier(unsure: true, availability: { .available }, makeSession: {
            created += 1
            let identifier = created
            return .init(prewarm: { warmed = identifier }, respond: { _ in identifier == 1 ? .note : .task })
        })
        adapter.prewarm(); adapter.prewarm()
        #expect(warmed == 1)
        #expect(try await adapter.classify("a thought").label == .note)
        #expect(try await adapter.classify("do something").label == .task)
        #expect(created == 2)
    }
    @Test(arguments: [AutomaticSwitchDiagnostics.ErrorKind.guardrail, .refusal, .other])
    func foundationRunnerFailuresStayTyped(_ kind: AutomaticSwitchDiagnostics.ErrorKind) async {
        let adapter = FoundationModelsClassifier(unsure: true, availability: { .available }, makeSession: {
            .init(prewarm: {}, respond: { _ in throw ClassifierFailure(kind: kind) })
        })
        do { _ = try await adapter.classify("private input"); Issue.record("Expected failure") }
        catch { #expect((error as? ClassifierFailure)?.kind == kind) }
    }
    @Test func foundationCancelledRunnerCannotPublishVerdict() async {
        let adapter = FoundationModelsClassifier(unsure: false, availability: { .available }, makeSession: {
            .init(prewarm: {}, respond: { _ in withUnsafeCurrentTask { $0?.cancel() }; return .task })
        })
        let task = Task { try await adapter.classify("private input") }
        await #expect(throws: CancellationError.self) { try await task.value }
    }
    @Test(arguments: [(FoundationModelAvailability.available, Optional<String>.none),
        (.deviceNotEligible, "Mac not eligible for Apple Intelligence"), (.modelNotReady, "Foundation Models is not ready"),
        (.unknown, "Foundation Models is unavailable")])
    func availabilityText(availability: FoundationModelAvailability, text: String?) {
        #expect(availability.menuText == text)
    }

    @Test func jevRejectsTheOldFourChoiceResponse() async {
        let old = Self.taskResponse.replacingOccurrences(of: #""Other":0.07"#, with: #""Note":0.04,"Other":0.03"#)
        let adapter = JevClassifier(key: "fixture", transport: { _ in .init(data: Data(old.utf8), status: 200) })
        do { _ = try await adapter.classify("new thought"); Issue.record("Expected old choice set to be rejected") }
        catch { #expect((error as? ClassifierFailure)?.kind == .malformedResponse) }
    }

    @Test func jevTaskFocusedWordingKeepsFoundationOptionsAndInvalidatesEarlierCaches() {
        #expect(ClassifierWording.foundationInstructions(unsure: true).contains("Note: Capture a thought or information as a new note"))
        #expect(ClassifierWording.version == .v1)
        #expect(ClassifierWording.foundationInstructions(unsure: true).contains("unsure: Unclear, incomplete, or none of the other options fits"))
        #expect(JevLaunchMemory.CacheIdentity.current.wordingVersion == "jev-task-focused-v1")
        let memory = JevLaunchMemory()
        memory.remember(.init(label: .note, probabilities: [.note: 0.95]), for: "new thought",
            identity: .init(wordingVersion: ClassifierWording.version.rawValue, model: JevClassifier.model))
        memory.remember(.init(label: .task, probabilities: [.task: 0.95], wordingVersion: .jevWithoutNoteV1), for: "new thought",
            identity: .init(wordingVersion: AutomaticSwitchDiagnostics.WordingVersion.jevWithoutNoteV1.rawValue, model: JevClassifier.model))
        var options = AutomaticSwitchOptions()
        options.isEnabled = true; options.classifier = .jev; options.firing = .wordPaced
        var policy = AutomaticSwitch(options: options, memory: memory, now: { .zero })
        _ = policy.handle(.invoked)
        let effects = policy.handle(.bufferChanged(text: "new thought ", composing: false,
            gate: .init(decision: .allowed, settled: true, allSourcesSettled: true)))
        #expect(effects.contains { if case .classify = $0 { true } else { false } })
        #expect(!effects.contains { if case .enterMode = $0 { true } else { false } })
        #expect(policy.debugSnapshot.cacheHits == 0)
    }

    @Test(arguments: ["error", "timeout", "backoff"])
    func jevTrialDiagnosticsIdentifyTheWordingEvenWithoutAnAnswer(outcome: String) throws {
        let clock = TestClock(), memory = JevLaunchMemory()
        var options = AutomaticSwitchOptions()
        options.isEnabled = true; options.classifier = .jev; options.firing = .wordPaced
        var policy = AutomaticSwitch(options: options, memory: memory, now: { clock.now.offset })
        _ = policy.handle(.invoked)
        if outcome == "backoff" { memory.recordFailure(kind: .rateLimited, at: .zero) }
        let sent = policy.handle(.bufferChanged(text: "new thought ", composing: false,
            gate: .init(decision: .allowed, settled: true, allSourcesSettled: true)))
        let effects: [AutomaticSwitch.Effect]
        if outcome == "backoff" { effects = sent }
        else {
            let id = try #require(sent.compactMap { if case .classify(let id, _) = $0 { id } else { nil } }.first)
            if outcome == "error" { effects = policy.handle(.failed(id: id, .network, latencyMilliseconds: 20)) }
            else { clock.advance(by: .milliseconds(1200)); effects = policy.handle(.tick) }
        }
        let row = try #require(effects.compactMap { if case .record(.verdict(let row)) = $0 { row } else { nil } }.first)
        #expect(row.outcome.rawValue == outcome && row.wordingVersion == .jevTaskFocusedV1)
    }

    nonisolated static let taskResponse = #"{"model":"jev-1.13.0","answers":{"classify_input":{"type":"choice","choice":"Task","probabilities":{"Search":0.03,"Task":0.9,"Other":0.07},"confidence":0.86}}}"#
}
