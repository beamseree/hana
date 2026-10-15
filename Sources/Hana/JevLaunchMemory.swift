import Foundation

/// Launch-wide Word-paced Jev state, injected into each bar session's policy.
/// It is never persisted and holds no text: only recent typing gaps and the
/// IDs of requests still in flight, including those left running by a closed
/// bar. A request's slot lasts until its work actually ends.
final class JevLaunchMemory {
    static let capacity = 2
    private static let gapLimit = 20
    private var gaps: [Duration] = []
    private var inFlight: Set<UUID> = []

    var inFlightCount: Int { inFlight.count }
    var hasCapacity: Bool { inFlight.count < Self.capacity }

    /// No edit for this long is a pause: `max(120 ms, 1.4 × median gap)` over
    /// the last 20 inserted characters, or 180 ms until five gaps exist.
    var pauseThreshold: Duration {
        guard gaps.count >= 5 else { return .milliseconds(180) }
        let sorted = gaps.sorted(), middle = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
        // Integer arithmetic keeps the threshold exact for the fake-clock tests.
        return max(.milliseconds(120), median * 7 / 5)
    }

    func recordTypingGap(_ gap: Duration) {
        gaps.append(gap)
        if gaps.count > Self.gapLimit { gaps.removeFirst(gaps.count - Self.gapLimit) }
    }
    func requestStarted(_ id: UUID) { inFlight.insert(id) }
    /// Idempotent: the policy and Mac Interaction may both report the same end.
    func requestFinished(_ id: UUID) { inFlight.remove(id) }
}
