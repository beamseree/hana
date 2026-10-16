import Foundation

/// Deliberate fixture-only evaluation. No live collection or automatic-switch diagnostics enter this API.
enum TrickyInputCheck {
    static let inputs = [
        "term", "remind m", "remind ", "Visual S", "call mom", "call mom tomorrow", "buy milk",
        "I noticed the light on the river. It changes every evening.", "https://example.com",
        "pasted paragraph\nSecond line", "Weekend ideas", "Weekend i", "Book dentist", "Send invoice", "Old travel notes",
        "open budget.xlsx", "budget.xlsx ", "Visual Studio Code", "find my notes", "remember this idea",
        "the meeting went well", "schedule a call", "write a thank you", "milk", "do", "a new thought",
        "pick up parcel tomorrow", "What if we try a different route?", "finish the report", "Read the design proposal"
    ]
    struct Row: Sendable {
        let input: String
        let gate: String
        let label: String
        let score: String
        let latencyMilliseconds: Double?
    }
    struct Report: Sendable {
        let rows: [Row]
        let classifier: AutomaticSwitchOptions.Classifier
        let options: AutomaticSwitchOptions
        var text: String {
            let wordingVersion = classifier == .jev ? ClassifierWording.jevVersion : ClassifierWording.version
            let header = "Hana tricky-input check\nClassifier: \(classifier == .jev ? "Jev (jev-1.13.0)" : "Foundation Models")\nWording: \(wordingVersion.rawValue)\nJev threshold: \(options.jevThreshold.rawValue)\nFoundation Models unsure: \(options.foundationModelsUnsure)\nFixed fixture collection; no live content. Requests ignore the gate; a timeout stops remaining requests.\nInput\tGate\tLabel\tProbability/unsure\tLatency ms\n"
            return header + rows.map {
                "\(Self.escape($0.input))\t\($0.gate)\t\($0.label)\t\($0.score)\t\($0.latencyMilliseconds.map { String(format: "%.1f", $0) } ?? "unmeasured")"
            }.joined(separator: "\n") + "\n"
        }
        private static func escape(_ input: String) -> String {
            input.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\t", with: "\\t")
                .replacingOccurrences(of: "\n", with: "\\n").replacingOccurrences(of: "\r", with: "\\r")
        }
        @concurrent func write(to directory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Hana", isDirectory: true)) async throws -> URL {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            let url = directory.appendingPathComponent("tricky-input-\(classifier.rawValue)-\(UUID().uuidString).txt")
            try Data(text.utf8).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return url
        }
    }
    @MainActor static func run(classifier: any Classifier, options: AutomaticSwitchOptions, requestTimeout: Duration = .milliseconds(1500)) async throws -> Report {
        // Only active fixtures enter Titles: completed "Send invoice" and archived "Old travel notes" are excluded.
        let titles = StrongMatchGate.Titles(status: .ready, notes: [SearchName("Weekend ideas")], tasks: [SearchName("Book dentist")])
        let results = [SearchResult(name: "Visual Studio Code", url: URL(fileURLWithPath: "/fixture/Visual Studio Code.app")),
            SearchResult(name: "budget.xlsx", url: URL(fileURLWithPath: "/fixture/budget.xlsx"), kind: .file)]
        var rows: [Row] = []
        var abandoned = false
        for input in inputs {
            try Task.checkCancellation()
            let gate = StrongMatchGate.evaluate(rawBuffer: input, results: results, appStatus: .ready, fileStatus: .ready, titles: titles)
            if abandoned {
                rows.append(Row(input: input, gate: gateText(gate.decision), label: "not-run", score: "previous-request-timed-out", latencyMilliseconds: nil))
                continue
            }
            let start = ContinuousClock.now
            let label: String, score: String
            do {
                let verdict = try await trickyInputVerdict(classifier: classifier, input: input, deadline: requestTimeout)
                try Task.checkCancellation()
                label = verdict.label.rawValue
                score = verdict.label == .unsure ? "unsure" : verdict.probability.map { String(format: "%.3f", $0) } ?? "n/a"
            } catch is TrickyInputTimeout { label = "error"; score = "timeout"; abandoned = true }
            catch is CancellationError { throw CancellationError() }
            catch { label = "error"; score = (error as? ClassifierFailure)?.kind.rawValue ?? "other" }
            let duration = start.duration(to: .now).components
            let latency = Double(duration.seconds) * 1000 + Double(duration.attoseconds) / 1e15
            rows.append(Row(input: input, gate: gateText(gate.decision), label: label, score: score, latencyMilliseconds: latency))
        }
        return Report(rows: rows, classifier: options.classifier, options: options)
    }
    private static func gateText(_ decision: StrongMatchGate.Decision) -> String {
        switch decision {
        case .allowed: "allowed"
        case .blocked(.calculation): "blocked:calculation"
        case .blocked(.oneWord): "blocked:one-word"
        case .blocked(.collectionUnavailable): "blocked:collection-unavailable"
        case .blocked(.strongMatch(let kind)): "blocked:strong-match:\(kind.rawValue)"
        }
    }
}
