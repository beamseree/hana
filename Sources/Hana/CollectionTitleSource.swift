import Foundation

/// Prepared titles for the prototype's gate. Does not publish Search rows.
@MainActor
final class CollectionTitleSource {
    typealias Snapshot = StrongMatchGate.Titles
    private(set) var snapshot: Snapshot
    private var observation: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<Snapshot>.Continuation] = [:]

    init(store: CollectionStore?) {
        snapshot = Snapshot(status: store == nil ? .unavailable : .loading)
        guard let store else { return }
        let entries = store.observe(.activeSearchEntries, in: store.generation)
        observation = Task { [weak self] in
            do {
                for try await value in entries {
                    guard !Task.isCancelled else { return }
                    self?.receive(Snapshot(status: .ready,
                        notes: value.notes.compactMap(\.title).map { SearchName($0) },
                        tasks: value.tasks.map { SearchName($0.title) }))
                }
                if !Task.isCancelled { self?.receive(Snapshot(status: .unavailable)) }
            } catch {
                if !Task.isCancelled { self?.receive(Snapshot(status: .unavailable)) }
            }
        }
    }

    deinit {
        observation?.cancel()
        for subscriber in subscribers.values { subscriber.finish() }
    }

    /// Current value first, then committed updates. Intermediate commits may coalesce.
    func snapshots() -> AsyncStream<Snapshot> {
        let key = UUID()
        let (stream, continuation) = AsyncStream<Snapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        subscribers[key] = continuation
        continuation.yield(snapshot)
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in self?.subscribers.removeValue(forKey: key) }
        }
        return stream
    }

    private func receive(_ value: Snapshot) {
        guard value != snapshot else { return }
        snapshot = value
        for subscriber in subscribers.values { subscriber.yield(value) }
    }
}
