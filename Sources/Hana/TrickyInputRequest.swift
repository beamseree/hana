import Foundation

/// An independent timeout task returns promptly even if the provider ignores cancellation.
/// A timed-out check must stop issuing further requests: hardware cleanup is not proven synchronous.
@MainActor
private final class PendingTrickyInputRequest {
    var continuation: CheckedContinuation<ClassifierVerdict, any Error>?
    var inference: Task<Void, Never>?
    var timeout: Task<Void, Never>?
    func finish(_ result: Result<ClassifierVerdict, any Error>) {
        guard let continuation else { return }
        self.continuation = nil
        inference?.cancel(); inference = nil
        timeout?.cancel(); timeout = nil
        continuation.resume(with: result)
    }
}

enum TrickyInputTimeout: Error { case exceeded }

@MainActor
func trickyInputVerdict(classifier: any Classifier, input: String, deadline: Duration) async throws -> ClassifierVerdict {
    let pending = PendingTrickyInputRequest()
    return try await withTaskCancellationHandler {
        try Task.checkCancellation()
        return try await withCheckedThrowingContinuation { continuation in
            pending.continuation = continuation
            pending.inference = Task {
                do { pending.finish(.success(try await classifier.classify(input))) }
                catch { pending.finish(.failure(error)) }
            }
            pending.timeout = Task {
                do { try await Task.sleep(for: deadline) }
                catch { return }
                pending.finish(.failure(TrickyInputTimeout.exceeded))
            }
        }
    } onCancel: {
        Task { @MainActor in pending.finish(.failure(CancellationError())) }
    }
}
