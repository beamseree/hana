import Foundation
import Testing
@testable import Hana

@MainActor
struct TrickyInputCheckTests {
    @Test func fakeClassifierReportContainsFixedInputsGateLabelScoreAndLatency() async throws {
        let report = try await TrickyInputCheck.run(classifier: ReportClassifier(), options: .init())
        #expect(report.rows.count == 30)
        #expect(report.rows.first?.input == "term")
        #expect(report.rows.first?.gate == "blocked:one-word")
        #expect(report.rows.first?.label == "task")
        #expect(report.rows.first?.score == "0.900")
        #expect(report.rows.allSatisfy { ($0.latencyMilliseconds ?? -1) >= 0 })
        #expect(report.text.contains("Input\tGate\tLabel\tProbability/unsure\tLatency ms"))
        #expect(report.text.contains("Foundation Models"))
        #expect(report.text.contains("automatic-switch-v1"))
        #expect(report.text.contains("blocked:strong-match:note"))
        #expect(report.text.contains("blocked:strong-match:task"))
        #expect(report.text.contains("pasted paragraph\\nSecond line"))
    }
    @Test func timeoutAbandonsRunWithoutIssuingConcurrentInferenceOrInventingLatency() async throws {
        let classifier = DelayedReportClassifier()
        let report = try await TrickyInputCheck.run(classifier: classifier, options: .init(), requestTimeout: .milliseconds(10))
        #expect(classifier.inputs == ["term"])
        #expect(report.rows.first?.score == "timeout")
        #expect(report.rows.dropFirst().allSatisfy { $0.label == "not-run" && $0.latencyMilliseconds == nil })
        #expect(report.text.contains("unmeasured"))
        classifier.release()
    }

}

@MainActor private struct ReportClassifier: Classifier {
    func classify(_ text: String) async throws -> ClassifierVerdict {
        .init(label: .task, probabilities: [.task: 0.9])
    }
}

@MainActor private final class DelayedReportClassifier: Classifier {
    var inputs: [String] = []
    private var continuation: CheckedContinuation<Void, Never>?
    func classify(_ text: String) async throws -> ClassifierVerdict {
        inputs.append(text)
        await withCheckedContinuation { continuation = $0 }
        return .init(label: .task)
    }
    func release() { continuation?.resume(); continuation = nil }
}
