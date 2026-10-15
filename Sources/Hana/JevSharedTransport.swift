import Foundation

/// Shared admission for Word-paced Jev HTTP work, including work left running
/// by a cancelled invocation. At most two requests run at once, started as soon
/// as a slot is free. A slot lasts until the transport actually exits.
@MainActor
final class JevSharedTransport {
    static let live = JevSharedTransport(transport: JevClassifier.liveTransport)
    static let capacity = 2

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, any Error>
    }
    private let transport: JevClassifier.Transport
    private var waiters: [Waiter] = []
    private var active = 0

    init(transport: @escaping JevClassifier.Transport) {
        self.transport = transport
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
        defer { active -= 1; admitNext() }
        // Cancellation can race admission. It must never start queued HTTP work.
        try Task.checkCancellation()
        let response = try await transport(request)
        try Task.checkCancellation()
        return response
    }

    private func cancelWaiting(_ id: UUID) {
        guard let index = waiters.firstIndex(where: { $0.id == id }) else { return }
        waiters.remove(at: index).continuation.resume(throwing: CancellationError())
    }

    private func admitNext() {
        // A slot is taken at admission, so a resumed caller that then finds
        // itself cancelled still releases exactly the slot it was given.
        while active < Self.capacity, !waiters.isEmpty {
            active += 1
            waiters.removeFirst().continuation.resume()
        }
    }
}
