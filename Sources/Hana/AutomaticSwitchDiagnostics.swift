import Foundation

/// Opt-in JSONL whose public recording boundary cannot accept user content.
/// Wording is versioned by a closed token, never arbitrary prompt text.
@MainActor
final class AutomaticSwitchDiagnostics {
    enum Label: String, Codable, Sendable { case search, note, task, unsure, none }
    enum Mode: String, Codable, Sendable { case search, note, task }
    enum WordingVersion: String, Codable, Sendable { case v1 = "automatic-switch-v1" }
    enum Outcome: String, Codable, Sendable {
        case switched, belowThreshold = "below-threshold", unsure, awaitingAgreement = "awaiting-agreement"
        case blocked, stale, multiline, suspended, error, timeout, backoff
    }
    enum ErrorKind: String, Codable, Sendable {
        case unavailable, authentication, rateLimited, malformedResponse, network, refusal, guardrail, other
    }
    enum BackoffReason: String, Codable, Sendable { case keyRejected = "key-rejected", rateLimited = "rate-limited", network }
    enum GateReason: String, Codable, Sendable { case oneWord, strongMatch, collectionUnavailable }
    enum MatchedKind: String, Codable, Sendable { case application, note, task, file, folder }
    enum ReversalMethod: String, Codable, Sendable { case escape, backspace }
    enum End: String, Codable, Sendable { case saved, reversed, dismissed }
    enum LateOutcome: String, Codable, Sendable { case returnedToSearch, stayed }

    struct Verdict: Sendable {
        var classifier: AutomaticSwitchOptions.Classifier
        var wordingVersion: WordingVersion = .v1
        var label: Label
        var probability: Double? = nil
        var unsure: Bool = false
        var latencyMilliseconds: Double?
        var outcome: Outcome
        var errorKind: ErrorKind? = nil
        var gateReason: GateReason? = nil
        var matchedKind: MatchedKind? = nil
        var wordCount: Int? = nil
        var backoffReason: BackoffReason? = nil
    }
    enum Event: Sendable {
        case verdict(Verdict)
        case switched(mode: Mode)
        case reversed(method: ReversalMethod, millisecondsSinceSwitch: Double)
        case lateStrongMatch(kind: MatchedKind, outcome: LateOutcome)
        case missed(mode: Mode, lastVerdict: Label)
        case ended(End)
        /// One per bar session with automatic switch on: a count, never text.
        case session(requestsSent: Int)
    }

    let url: URL
    init(file: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Hana/automatic-switch.jsonl")) { url = file }

    func record(_ event: Event, options: AutomaticSwitchOptions) {
        guard options.isEnabled else { return }
        append(Row(event: event, options: options))
    }

    struct Latency {
        let medianMilliseconds: Double
        let maximumMilliseconds: Double
    }
    struct Counts {
        var switches = 0
        var wrongSwitches = 0
        var reversals = 0
        var ambiguous = 0
        var missed = 0
        var errors = 0
        var timeouts = 0
        var latencies: [AutomaticSwitchOptions.Classifier: Latency] = [:]
    }

    /// Reset is a durable boundary in the same log; trial history is preserved.
    func resetCounts(options: AutomaticSwitchOptions) {
        guard options.isEnabled else { return }
        append(Row(resetOptions: options))
    }

    /// The log is authoritative across relaunch, including reset markers.
    func counts() -> Counts {
        guard let data = try? Data(contentsOf: url) else { return Counts() }
        var result = Counts()
        var samples: [AutomaticSwitchOptions.Classifier: [Double]] = [:]
        for line in data.split(separator: 10) {
            guard let row = try? JSONDecoder().decode(Row.self, from: Data(line)) else { continue }
            switch row.event {
            case "autoswitch.reset": result = Counts(); samples = [:]
            case "autoswitch.switched": result.switches += 1
            case "autoswitch.reversed": result.reversals += 1; result.wrongSwitches += 1
            case "autoswitch.late-strong-match" where row.lateOutcome == .returnedToSearch:
                result.wrongSwitches += 1
            case "autoswitch.missed": result.missed += 1
            case "autoswitch.ended" where row.end == .dismissed: result.ambiguous += 1
            case "autoswitch.verdict":
                if row.outcome == .error { result.errors += 1 }
                if row.outcome == .timeout { result.timeouts += 1 }
                if let classifier = row.classifier, let latency = row.latencyMilliseconds,
                   latency.isFinite, latency >= 0 { samples[classifier, default: []].append(latency) }
            default: break
            }
        }
        for (classifier, values) in samples {
            let sorted = values.sorted(), middle = values.count / 2
            let median = values.count.isMultiple(of: 2) ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
            result.latencies[classifier] = Latency(medianMilliseconds: median, maximumMilliseconds: sorted[sorted.count - 1])
        }
        return result
    }

    private func append(_ row: Row) {
        do {
            let directory = url.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: nil,
                                                     attributes: [.posixPermissions: 0o600]) else { return }
            }
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            let file = try FileHandle(forWritingTo: url)
            defer { try? file.close() }
            try file.seekToEnd()
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try file.write(contentsOf: encoder.encode(row) + Data([10]))
        } catch {
            // Paths and localized error descriptions may contain personal data.
            fputs("Hana: automatic-switch log unavailable.\n", stderr)
        }
    }

    private struct Row: Codable {
        var event: String
        var time = Date()
        var options: AutomaticSwitchOptions
        var classifier: AutomaticSwitchOptions.Classifier?
        var wordingVersion: WordingVersion?
        var label: Label?
        var probability: Double?
        var unsure: Bool?
        var latencyMilliseconds: Double?
        var outcome: Outcome?
        var errorKind: ErrorKind?
        var gateReason: GateReason?
        var matchedKind: MatchedKind?
        var wordCount: Int?
        var backoffReason: BackoffReason?
        var mode: Mode?
        var reversalMethod: ReversalMethod?
        var millisecondsSinceSwitch: Double?
        var lastVerdict: Label?
        var end: End?
        var lateOutcome: LateOutcome?
        var requestsSent: Int?

        init(resetOptions: AutomaticSwitchOptions) {
            event = "autoswitch.reset"; options = resetOptions
        }

        init(event: Event, options: AutomaticSwitchOptions) {
            self.options = options
            switch event {
            case .verdict(let verdict):
                self.event = "autoswitch.verdict"
                classifier = verdict.classifier; wordingVersion = verdict.wordingVersion
                label = verdict.label; probability = verdict.probability; unsure = verdict.unsure
                latencyMilliseconds = verdict.latencyMilliseconds; outcome = verdict.outcome
                errorKind = verdict.errorKind; gateReason = verdict.gateReason
                matchedKind = verdict.matchedKind; wordCount = verdict.wordCount
                backoffReason = verdict.backoffReason
            case .switched(let mode): self.event = "autoswitch.switched"; self.mode = mode
            case .reversed(let method, let milliseconds):
                self.event = "autoswitch.reversed"; reversalMethod = method; millisecondsSinceSwitch = milliseconds
            case .lateStrongMatch(let kind, let outcome):
                self.event = "autoswitch.late-strong-match"; matchedKind = kind; lateOutcome = outcome
            case .missed(let mode, let lastVerdict):
                self.event = "autoswitch.missed"; self.mode = mode; self.lastVerdict = lastVerdict
            case .ended(let end): self.event = "autoswitch.ended"; self.end = end
            case .session(let requestsSent): self.event = "autoswitch.session"; self.requestsSent = requestsSent
            }
        }
    }
}
