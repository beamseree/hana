import Foundation
@testable import Hana

/// The classifier boundary is controlled by each test, including delayed answers and cancellation.
@MainActor
final class ScriptedClassifier: Classifier {
    private(set) var inputs: [String] = []
    private var pending: [(UUID, CheckedContinuation<ClassifierVerdict, any Error>)] = []
    var pendingCount: Int { pending.count }

    func classify(_ text: String) async throws -> ClassifierVerdict {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                inputs.append(text)
                pending.append((id, continuation))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self, let index = self.pending.firstIndex(where: { $0.0 == id }) else { return }
                self.pending.remove(at: index).1.resume(throwing: CancellationError())
            }
        }
    }

    func reply(_ label: ClassifierVerdict.Label, probability: Double? = nil) {
        guard !pending.isEmpty else { return }
        pending.removeFirst().1.resume(returning: .init(label: label,
            probabilities: probability.map { [label: $0] }))
    }

    func fail(_ kind: AutomaticSwitchDiagnostics.ErrorKind) {
        guard !pending.isEmpty else { return }
        pending.removeFirst().1.resume(throwing: ClassifierFailure(kind: kind))
    }
}
