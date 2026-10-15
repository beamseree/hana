import Foundation
import Testing
@testable import Hana

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct JevSharedTransportTests {
    @Test func independentClientsShareTwoSlotsWithNoStartSpacing() async throws {
        let runner = HeldTransport()
        let limiter = JevSharedTransport(transport: runner.perform)
        let clients = (0..<4).map { index in Task { try await limiter.perform(request(index)) } }
        defer { clients.forEach { $0.cancel() }; runner.finishAll() }
        try await eventually { runner.starts.count == 2 }
        try await Task.sleep(for: .milliseconds(50))
        #expect(runner.starts.count == 2 && runner.pending.count == 2)
        // A freed slot starts the next waiter at once: no 100 ms spacing remains.
        runner.finishFirst()
        try await eventually { runner.starts.count == 3 }
        runner.finishFirst()
        try await eventually { runner.starts.count == 4 }
        #expect(runner.maximumActive == 2)
        // The first two clients start together.
        #expect(runner.starts[0].time.duration(to: runner.starts[1].time) < .milliseconds(100))
        runner.finishAll()
        for client in clients { _ = try await client.value }
    }

    @Test func cancelledActiveRequestsHoldSlotsUntilNoncooperativeTransportExits() async throws {
        let runner = HeldTransport()
        let limiter = JevSharedTransport(transport: runner.perform)
        let old = (0..<2).map { index in Task { try await limiter.perform(request(index)) } }
        try await eventually { runner.starts.count == 2 }
        old.forEach { $0.cancel() }
        // Represents a new bar session while the previous HTTP work is still alive.
        let fresh = Task { try await limiter.perform(request(2)) }
        defer { old.forEach { $0.cancel() }; fresh.cancel(); runner.finishAll() }
        try await Task.sleep(for: .milliseconds(50))
        #expect(runner.starts.count == 2 && runner.pending.count == 2)
        runner.finishFirst()
        try await eventually { runner.starts.count == 3 }
        #expect(runner.maximumActive == 2)
        runner.finishAll()
        for client in old { await #expect(throws: CancellationError.self) { try await client.value } }
        _ = try await fresh.value
    }

    @Test func cancelledWaitingRequestNeverSendsAndSurvivingWaitersKeepTheirOrder() async throws {
        let runner = HeldTransport()
        let limiter = JevSharedTransport(transport: runner.perform)
        let running = (0..<2).map { index in Task { try await limiter.perform(request(index)) } }
        try await eventually { runner.starts.count == 2 }
        let cancelled = Task { try await limiter.perform(request(2)) }
        // Give this caller a turn to enqueue behind the occupied slots.
        await Task.yield()
        let next = Task { try await limiter.perform(request(3)) }
        await Task.yield()
        let last = Task { try await limiter.perform(request(4)) }
        defer {
            running.forEach { $0.cancel() }
            cancelled.cancel(); next.cancel(); last.cancel(); runner.finishAll()
        }
        cancelled.cancel()
        await #expect(throws: CancellationError.self) { try await cancelled.value }
        runner.finishFirst()
        try await eventually { runner.starts.count == 3 }
        #expect(runner.starts.last?.path == "/3")
        runner.finishFirst()
        try await eventually { runner.starts.count == 4 }
        #expect(runner.starts.last?.path == "/4")
        #expect(!runner.starts.contains { $0.path == "/2" })
        runner.finishAll()
        for client in running { _ = try await client.value }
        _ = try await next.value
        _ = try await last.value
    }

    private func request(_ index: Int) -> URLRequest {
        URLRequest(url: URL(string: "https://fixture.invalid/\(index)")!)
    }

    /// Deliberately ignores cancellation, just as an already sent request may.
    @MainActor private final class HeldTransport {
        struct Start { let path: String; let time: ContinuousClock.Instant }
        private(set) var starts: [Start] = []
        private(set) var pending: [CheckedContinuation<(Data, Int), Never>] = []
        private(set) var maximumActive = 0

        func perform(_ request: URLRequest) async throws -> (Data, Int) {
            starts.append(Start(path: request.url!.path, time: ContinuousClock.now))
            return await withCheckedContinuation { continuation in
                pending.append(continuation)
                maximumActive = max(maximumActive, pending.count)
            }
        }
        func finishFirst() {
            guard !pending.isEmpty else { return }
            pending.removeFirst().resume(returning: (Data(), 200))
        }
        func finishAll() { while !pending.isEmpty { finishFirst() } }
    }
}
