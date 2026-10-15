import Foundation

/// Shared admission for pipelined Jev HTTP work, including work left running by
/// a cancelled invocation. A slot lasts until the transport actually exits.
@MainActor
final class JevPipelineTransport {
    static let live = JevPipelineTransport(transport: JevClassifier.liveTransport)

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }
    private let transport: JevClassifier.Transport
    private let now: () -> Duration
    private let sleep: (Duration) async throws -> Void
    private var waiters: [Waiter] = []
    private var active = 0
    private var admissionPending = false
    private var lastStart: Duration?
    private var wake: (id: UUID, task: Task<Void, Never>)?

    init(transport: @escaping JevClassifier.Transport,
         now: (() -> Duration)? = nil,
         sleep: @escaping (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.transport = transport
        let epoch = ContinuousClock.now
        self.now = now ?? { epoch.duration(to: ContinuousClock.now) }
        self.sleep = sleep
    }

    func perform(_ request: URLRequest) async throws -> (Data, Int) {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                waiters.append(Waiter(id: id, continuation: continuation))
                admitNext()
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiting(id) }
        }
        admissionPending = false
        defer { active -= 1; admitNext() }
        // Cancellation can race admission. It must never start queued HTTP work.
        try Task.checkCancellation()
        lastStart = now()
        admitNext()
        let response = try await transport(request)
        try Task.checkCancellation()
        return response
    }

    private func cancelWaiting(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
        admitNext()
    }

    private func admitNext() {
        guard active < 3, !waiters.isEmpty else {
            wake?.task.cancel(); wake = nil
            return
        }
        // Only one resumed caller may be between admission and transport entry.
        // Otherwise a delayed caller could start alongside the following one.
        guard !admissionPending else { return }
        let remaining = lastStart.map { $0 + .milliseconds(100) - now() } ?? .zero
        guard remaining <= .zero else {
            guard wake == nil else { return }
            let id = UUID()
            wake = (id, Task { [weak self, sleep] in
                do { try await sleep(remaining) } catch { return }
                guard let self, self.wake?.id == id else { return }
                self.wake = nil
                self.admitNext()
            })
            return
        }
        wake?.task.cancel(); wake = nil
        active += 1
        admissionPending = true
        waiters.removeFirst().continuation.resume()
    }
}
