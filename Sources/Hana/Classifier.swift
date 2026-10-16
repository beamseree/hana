import Foundation

/// External inference boundary. A request must cooperate with task cancellation.
/// Production adapters are installed explicitly by HanaApp, never by a test's default constructor.
@MainActor
protocol Classifier {
    func prewarm()
    func classify(_ text: String) async throws -> ClassifierVerdict
}

struct ClassifierVerdict: Sendable {
    enum Label: String, Codable, CaseIterable, Sendable { case search, note, task, unsure }
    var label: Label
    var probabilities: [Label: Double]? = nil
    var wordingVersion: AutomaticSwitchDiagnostics.WordingVersion = .v1
    var probability: Double? { probabilities?[label] }
}

/// A content-free failure classification; adapters never pass response bodies to diagnostics.
struct ClassifierFailure: Error {
    let kind: AutomaticSwitchDiagnostics.ErrorKind
    var retryAfter: Duration? = nil
}

extension Classifier { func prewarm() {} }
