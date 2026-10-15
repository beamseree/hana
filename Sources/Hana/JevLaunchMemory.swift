import Foundation
import CryptoKit

/// Launch-wide Word-paced Jev state, injected into each bar session's policy.
/// It is never persisted. Only the answer cache retains text; other state is
/// recent typing gaps and the IDs and content fingerprints of requests still in flight, including those
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
    private var inFlight: [UUID: SHA256.Digest] = [:]
    private(set) var keyRejected = false
    private(set) var keyRevision: UInt64 = 0
    private var pausedUntil: Duration?
    private var pauseReason: AutomaticSwitchDiagnostics.BackoffReason?
    private var rateLimitDelay = Duration.seconds(1)
    private var consecutiveNetworkErrors = 0

    func backoffReason(at time: Duration) -> AutomaticSwitchDiagnostics.BackoffReason? {
        if keyRejected { return .keyRejected }
        guard let pausedUntil, time < pausedUntil else { return nil }
        return pauseReason
    }
    func recordFailure(kind: AutomaticSwitchDiagnostics.ErrorKind, retryAfter: Duration? = nil, at time: Duration) {
        if kind == .network {
            consecutiveNetworkErrors += 1
            if consecutiveNetworkErrors >= 2 {
                pause(until: time + .seconds(2), reason: .network)
            }
        } else { consecutiveNetworkErrors = 0 }
        if kind == .authentication { keyRejected = true }
        if kind == .rateLimited {
            let delay = retryAfter ?? rateLimitDelay
            pause(until: time + delay, reason: .rateLimited)
            if retryAfter == nil { rateLimitDelay = min(.seconds(30), rateLimitDelay * 2) }
        }
    }
    func keySaved() { keyRejected = false; keyRevision &+= 1 }
    func recordSuccess() { rateLimitDelay = .seconds(1); consecutiveNetworkErrors = 0 }
    private func pause(until time: Duration, reason: AutomaticSwitchDiagnostics.BackoffReason) {
        if let pausedUntil, time <= pausedUntil { return }
        pausedUntil = time; pauseReason = reason
    }
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
    /// Normalized text is hashed transiently; only the fingerprint survives until completion.
    func requestStarted(_ id: UUID, text: String) { inFlight[id] = SHA256.hash(data: Data(text.utf8)) }
    func hasRequest(for text: String) -> Bool {
        inFlight.values.contains(SHA256.hash(data: Data(text.utf8)))
    }
    /// Idempotent: the policy and Mac Interaction may both report the same end.
    func requestFinished(_ id: UUID) { inFlight.removeValue(forKey: id) }
}
