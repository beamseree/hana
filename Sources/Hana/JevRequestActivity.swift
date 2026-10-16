import Foundation

/// Counts actual transport starts, after shared admission, independently of
/// policy requests and cache hits. Carries no text, credentials or HTTP bodies.
@MainActor
final class JevRequestActivity {
    static let live = JevRequestActivity()

    @MainActor final class Session {
        private(set) var sent = 0
        private(set) var activeIDs: Set<UUID> = []
        /// Kept until the classifier's terminal policy callback, so response
        /// decoding is never mistaken for work still awaiting HTTP admission.
        private(set) var startedIDs: Set<UUID> = []

        fileprivate func started(_ id: UUID) { sent += 1; activeIDs.insert(id); startedIDs.insert(id) }
        fileprivate func finished(_ id: UUID) { activeIDs.remove(id) }
        func finishedProcessing(_ id: UUID) { startedIDs.remove(id) }
    }

    struct Context: Sendable {
        let session: Session
        let requestID: UUID
    }

    @TaskLocal static var context: Context?
    private(set) var activeCount = 0
    private var observers: [UUID: @MainActor () -> Void] = [:]

    func observe(_ changed: @escaping @MainActor () -> Void) -> UUID {
        let token = UUID()
        observers[token] = changed
        return token
    }

    func removeObserver(_ token: UUID) { observers[token] = nil }

    func perform(_ operation: () async throws -> JevClassifier.Response) async throws -> JevClassifier.Response {
        try Task.checkCancellation()
        let context = Self.context
        activeCount += 1
        if let context { context.session.started(context.requestID) }
        notify()
        defer {
            activeCount -= 1
            if let context { context.session.finished(context.requestID) }
            notify()
        }
        return try await operation()
    }

    private func notify() {
        for observer in Array(observers.values) { observer() }
    }
}
