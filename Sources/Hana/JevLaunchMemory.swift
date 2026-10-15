import Foundation

/// Launch-wide Word-paced Jev state, injected into each bar session's policy.
/// It is never persisted. Only the answer cache retains text; other state is
/// recent typing gaps and the IDs of requests still in flight, including those
/// left running by a closed bar. A request's slot lasts until its work actually ends.
final class JevLaunchMemory {
    struct CacheIdentity: Hashable {
        let wordingVersion: String
        let model: String
        static var current: Self { Self(wordingVersion: ClassifierWording.version.rawValue, model: JevClassifier.model) }
    }
    private struct CacheKey: Hashable { let text: String; let identity: CacheIdentity }
    static let capacity = 2
    private static let gapLimit = 20
    private static let answerLimit = 64
    private var gaps: [Duration] = []
    private var inFlight: Set<UUID> = []
    private var answers: [CacheKey: ClassifierVerdict] = [:]
    private var recentAnswers: [CacheKey] = []

    func cachedVerdict(for text: String, identity: CacheIdentity) -> ClassifierVerdict? {
        let key = CacheKey(text: text, identity: identity)
        guard let verdict = answers[key] else { return nil }
        recentAnswers.removeAll { $0 == key }; recentAnswers.append(key)
        return verdict
    }
    func remember(_ verdict: ClassifierVerdict, for text: String, identity: CacheIdentity) {
        let key = CacheKey(text: text, identity: identity)
        answers[key] = verdict
        recentAnswers.removeAll { $0 == key }; recentAnswers.append(key)
        if recentAnswers.count > Self.answerLimit { answers[recentAnswers.removeFirst()] = nil }
    }

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
