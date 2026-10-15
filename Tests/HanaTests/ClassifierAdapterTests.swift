import Foundation
import Testing
@testable import Hana

@MainActor
struct ClassifierAdapterTests {
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
            return (Data(Self.taskResponse.utf8), 200)
        })
        let verdict = try await adapter.classify("call mom tomorrow")
        #expect(verdict.label == .task)
        #expect(verdict.probability == 0.9)
        #expect(verdict.probabilities?[.search] == 0.03)
        #expect(verdict.wordingVersion == .v1)
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
        let adapter = JevClassifier(key: "secret", transport: { _ in (Data("private input".utf8), status) })
        do { _ = try await adapter.classify("private input"); Issue.record("Expected failure") }
        catch { #expect((error as? ClassifierFailure)?.kind == kind) }
    }
    @Test func jevOtherMapsToUnsure() async throws {
        let json = Self.taskResponse.replacingOccurrences(of: #""choice":"Task""#, with: #""choice":"Other""#)
            .replacingOccurrences(of: #""Task":0.9,"Other":0.03"#, with: #""Task":0.03,"Other":0.9"#)
        let adapter = JevClassifier(key: "secret", transport: { _ in (Data(json.utf8), 200) })
        let verdict = try await adapter.classify("unclear input")
        #expect(verdict.label == .unsure && verdict.probability == 0.9)
    }
    @Test(arguments: ["{}", "not json", taskResponse.replacingOccurrences(of: "0.9", with: "1.9"),
        taskResponse.replacingOccurrences(of: #""Task":0.9"#, with: #""Task":0.8"#),
        taskResponse.replacingOccurrences(of: #""choice":"Task""#, with: #""choice":"Search""#),
        taskResponse.replacingOccurrences(of: "jev-1.13.0", with: "jev-latest"),
        taskResponse.replacingOccurrences(of: #""Other":0.03"#, with: #""Unknown":0.03"#)])
    func jevMalformedResponsesFail(_ body: String) async {
        let adapter = JevClassifier(key: "secret", transport: { _ in (Data(body.utf8), 200) })
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
            return (Data(Self.taskResponse.utf8), 200)
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

    nonisolated static let taskResponse = #"{"model":"jev-1.13.0","answers":{"classify_input":{"type":"choice","choice":"Task","probabilities":{"Search":0.03,"Note":0.04,"Task":0.9,"Other":0.03},"confidence":0.86}}}"#
}
