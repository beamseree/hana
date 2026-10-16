import Foundation

/// Read-only presentation data. No input text crosses this boundary.
struct AutomaticSwitchDebugSnapshot {
    enum Relevance: String { case current, prefix, stale }
    struct Request {
        let id: UUID
        let number: Int
        let characters: Int
        let elapsedMilliseconds: Double
        let relevance: Relevance
    }
    struct Answer {
        let number: Int?
        let characters: Int
        let label: AutomaticSwitchDiagnostics.Label
        let probability: Double?
        let latencyMilliseconds: Double?
        let cached: Bool
        let relevance: Relevance
        let outcome: AutomaticSwitchDiagnostics.Outcome
        let reason: String
        let agreement: Int
        let requiredAgreement: Int

        func text(isJev: Bool) -> String {
            let source = cached ? "cache" : isJev ? (reason == "error: unavailable" ? "not sent" : "network") : "local"
            let number = number.map { "#\($0) " } ?? ""
            let probability = probability.map { " \(Int(($0 * 100).rounded()))%" } ?? ""
            let latency = latencyMilliseconds.map { " · \(Int($0.rounded())) ms" } ?? ""
            let label = outcome == .timeout ? "Timeout" : outcome == .error ? "Error" : label.rawValue.capitalized
            return "\(number)\(label)\(probability) · \(reason) · \(source)\(latency) · \(relevance.rawValue) \(characters) chars"
        }
    }

    let options: AutomaticSwitchOptions
    let state: String
    let remainingMilliseconds: Double?
    let request: Request?
    let queued: Bool
    let answer: Answer?
    let cacheHits: Int

    var needsClockUpdates: Bool { remainingMilliseconds != nil || request != nil }

    func lines(sent: Int, activeHTTP: Int, startedIDs: Set<UUID>) -> (summary: String, detail: String) {
        let strategy: String = switch options.firing {
        case .everyKeystroke: "Every keystroke"
        case .debounced: "Debounced"
        case .onPause: "On pause"
        case .wordPaced: "Word-paced"
        }
        let jev = options.classifier == .jev
        let name = jev ? "Jev \(JevClassifier.model.replacingOccurrences(of: "jev-", with: ""))" : "Foundation Models"
        let threshold = jev ? " ≥\(Int((options.jevThreshold.rawValue * 100).rounded()))%" : ""
        let capacity = jev && options.firing == .wordPaced ? "/2" : ""
        let counts = jev ? " · sent \(sent) · live \(activeHTTP)\(capacity) · cache \(cacheHits)" : ""
        let summary = "\(name) · \(strategy)\(threshold)\(counts)"
        var state = state
        if let request {
            let phase = jev && !startedIDs.contains(request.id) ? "queued" : "requesting"
            state = "#\(request.number) \(phase) \(Int(request.elapsedMilliseconds.rounded())) ms · \(request.relevance.rawValue) \(request.characters) chars"
            if queued { state += " · newer queued" }
        } else if let remainingMilliseconds {
            state += " · \(Int(ceil(max(0, remainingMilliseconds)))) ms"
        }
        let detail = answer.map { "\(state) · \($0.text(isJev: jev))" } ?? state
        return (summary, detail)
    }
}
