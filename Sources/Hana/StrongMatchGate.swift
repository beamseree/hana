import Foundation

/// Pure permission to classify; this component never enters a capture mode.
enum StrongMatchGate {
    enum Kind: String, Equatable, Sendable { case application, note, task, file }
    enum Reason: Equatable, Sendable {
        case calculation, oneWord, strongMatch(Kind), collectionUnavailable
    }
    enum Decision: Equatable, Sendable {
        case allowed, blocked(Reason)
    }
    struct Titles: Equatable, Sendable {
        enum Status: Equatable, Sendable { case loading, ready, unavailable }
        var status: Status
        var notes: [SearchName] = []
        var tasks: [SearchName] = []
    }
    struct Evaluation: Equatable, Sendable {
        let decision: Decision
        /// Apps and collection have finished delivering their initial values.
        let settled: Bool
        let allSourcesSettled: Bool
    }

    static func evaluate(rawBuffer: String, results: [SearchResult], appStatus: SourceStatus,
                         fileStatus: SourceStatus, titles: Titles) -> Evaluation {
        let started = rawBuffer.drop(while: \.isWhitespace)
        let hasSeparator = started.contains(where: \.isWhitespace)
        var decision: Decision = hasSeparator ? .allowed : .blocked(.oneWord)
        if Calculation.recognizes(rawBuffer, locale: .current) {
            decision = .blocked(.calculation)
        } else if titles.status == .unavailable {
            decision = .blocked(.collectionUnavailable)
        } else if hasSeparator {
            let query = SearchName.normalized(rawBuffer)
            for result in results {
                let blocks = result.matchingNames.contains { name in
                    guard let tier = name.tier(for: query) else { return false }
                    return tier == .exact || (result.kind == .application && tier == .phrasePrefix)
                }
                if blocks {
                    decision = .blocked(.strongMatch(result.kind == .application ? .application : .file))
                    break
                }
            }
            if decision == .allowed {
                if titles.notes.contains(where: { $0.tier(for: query).map { $0 <= .phrasePrefix } ?? false }) {
                    decision = .blocked(.strongMatch(.note))
                } else if titles.tasks.contains(where: { $0.tier(for: query).map { $0 <= .phrasePrefix } ?? false }) {
                    decision = .blocked(.strongMatch(.task))
                }
            }
        }
        let appSettled = appStatus == .ready || appStatus == .failed
        let fileSettled = fileStatus == .ready || fileStatus == .failed
        let settled = appSettled && titles.status == .ready
        return Evaluation(decision: decision, settled: settled, allSourcesSettled: settled && fileSettled)
    }
}
