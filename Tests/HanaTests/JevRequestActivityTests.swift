import Foundation
import Testing
@testable import Hana

@MainActor
struct JevRequestActivityTests {
    @Test func queuedAndCancelledWorkDoesNotCountAsSent() async throws {
        let activity = JevRequestActivity(), session = JevRequestActivity.Session(), gate = TransportGate()
        let transport = JevSharedTransport(transport: { _ in
            try await activity.perform { try await gate.wait() }
        })
        let first = request(transport, session: session)
        let second = request(transport, session: session)
        try await eventually { gate.pending.count == 2 }
        let queued = request(transport, session: session)
        // Yield to admission without using wall time to infer a send.
        for _ in 0..<10 { await Task.yield() }
        #expect(session.sent == 2 && session.activeIDs.count == 2 && activity.activeCount == 2)
        queued.cancel()
        await #expect(throws: CancellationError.self) { try await queued.value }
        #expect(session.sent == 2)
        gate.finishAll()
        _ = try await first.value; _ = try await second.value
        #expect(session.activeIDs.isEmpty && activity.activeCount == 0)
    }

    @Test func oldRequestsStayLiveWithoutInflatingTheNextSessionCount() async throws {
        let activity = JevRequestActivity(), old = JevRequestActivity.Session(), next = JevRequestActivity.Session()
        let gate = TransportGate()
        let transport = JevSharedTransport(transport: { _ in try await activity.perform { try await gate.wait() } })
        let oldTask = request(transport, session: old)
        try await eventually { old.sent == 1 }
        let nextTask = request(transport, session: next)
        try await eventually { next.sent == 1 }
        #expect(activity.activeCount == 2 && old.sent == 1 && next.sent == 1)
        gate.finishAll()
        _ = try await oldTask.value; _ = try await nextTask.value
        #expect(activity.activeCount == 0 && next.activeIDs.isEmpty && old.activeIDs.isEmpty)
    }

    @Test func failureAndPreStartCancellationReleaseCountsAndNotifyObservers() async throws {
        let activity = JevRequestActivity(), session = JevRequestActivity.Session(), id = UUID()
        var observed: [Int] = []
        let token = activity.observe { observed.append(activity.activeCount) }
        let context = JevRequestActivity.Context(session: session, requestID: id)
        do {
            _ = try await JevRequestActivity.$context.withValue(context) {
                try await activity.perform { throw URLError(.notConnectedToInternet) }
            }
            Issue.record("Expected transport error")
        } catch { #expect(error is URLError) }
        #expect(observed == [1, 0] && session.sent == 1 && session.activeIDs.isEmpty)
        activity.removeObserver(token)
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await JevRequestActivity.$context.withValue(context) {
                try await activity.perform {
                    Issue.record("Cancelled work must not enter the transport")
                    return .init(data: Data(), status: 200)
                }
            }
        }
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        #expect(session.sent == 1 && activity.activeCount == 0 && observed == [1, 0])
    }

    private func request(_ transport: JevSharedTransport, session: JevRequestActivity.Session) -> Task<JevClassifier.Response, any Error> {
        let context = JevRequestActivity.Context(session: session, requestID: UUID())
        return Task {
            try await JevRequestActivity.$context.withValue(context) {
                try await transport.perform(URLRequest(url: URL(string: "https://fixture.invalid")!))
            }
        }
    }

    @MainActor private final class TransportGate {
        var pending: [CheckedContinuation<JevClassifier.Response, any Error>] = []
        func wait() async throws -> JevClassifier.Response {
            try await withCheckedThrowingContinuation { pending.append($0) }
        }
        func finishAll() {
            let pending = pending; self.pending = []
            pending.forEach { $0.resume(returning: .init(data: Data(), status: 200)) }
        }
    }
}
