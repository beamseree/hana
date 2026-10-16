import Foundation

@MainActor
struct JevClassifier: Classifier {
    struct Response {
        let data: Data
        let status: Int
        var retryAfter: String? = nil
    }
    typealias Transport = @MainActor (URLRequest) async throws -> Response
    nonisolated static let model = "jev-1.13.0"
    private let keyProvider: () -> String?
    private let transport: Transport
    private let now: () -> Date
    init(key: String, now: @escaping () -> Date = Date.init, transport: @escaping Transport = liveTransport) {
        self.init(keyProvider: { key }, now: now, transport: transport)
    }
    init(keyProvider: @escaping () -> String?, now: @escaping () -> Date = Date.init, transport: @escaping Transport = liveTransport) {
        self.keyProvider = keyProvider
        self.transport = transport
        self.now = now
    }
    static func liveTransport(_ request: URLRequest) async throws -> Response {
        try await JevRequestActivity.live.perform {
            try await JevHTTPSession.live.perform(request)
        }
    }
    func classify(_ text: String) async throws -> ClassifierVerdict {
        try Task.checkCancellation()
        guard let key = keyProvider(), !key.isEmpty else { throw ClassifierFailure(kind: .unavailable) }
        var request = URLRequest(url: URL(string: "https://api.typesafe.ai/v1/systemone")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 1.5
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "state": text, "model": Self.model,
            "questions": ["classify_input": ["type": "choice", "instructions": ClassifierWording.instructions,
                                                "criteria": ClassifierWording.jevCriteria]]
        ], options: [.sortedKeys])
        let response: Response
        do { response = try await transport(request) }
        catch {
            try Task.checkCancellation()
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            if let failure = error as? ClassifierFailure { throw failure }
            throw ClassifierFailure(kind: .network)
        }
        try Task.checkCancellation()
        guard (200..<300).contains(response.status) else {
            throw ClassifierFailure(kind: response.status == 401 ? .authentication : response.status == 429 ? .rateLimited : .network,
                retryAfter: response.status == 429 ? retryAfter(response.retryAfter) : nil)
        }
        struct AnswerResponse: Decodable {
            struct Answer: Decodable { let type: String; let choice: String; let probabilities: [String: Double] }
            let model: String
            let answers: [String: Answer]
        }
        guard let response = try? JSONDecoder().decode(AnswerResponse.self, from: response.data), response.model == Self.model,
              let answer = response.answers["classify_input"], answer.type == "choice",
              Set(answer.probabilities.keys) == Set(ClassifierWording.jevCriteria.keys),
              answer.probabilities.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              abs(answer.probabilities.values.reduce(0, +) - 1) < 0.001,
              let winning = answer.probabilities[answer.choice], winning == answer.probabilities.values.max() else {
            throw ClassifierFailure(kind: .malformedResponse)
        }
        let labels: [String: ClassifierVerdict.Label] = ["Search": .search, "Task": .task, "Other": .unsure]
        guard let label = labels[answer.choice] else { throw ClassifierFailure(kind: .malformedResponse) }
        let probabilities = Dictionary(uniqueKeysWithValues: answer.probabilities.map { (labels[$0.key]!, $0.value) })
        try Task.checkCancellation()
        return ClassifierVerdict(label: label, probabilities: probabilities, wordingVersion: ClassifierWording.jevVersion)
    }

    private func retryAfter(_ header: String?) -> Duration? {
        guard let header else { return nil }
        let trimmed = header.trimmingCharacters(in: .whitespacesAndNewlines)
        if let seconds = TimeInterval(trimmed), seconds.isFinite, seconds >= 0 {
            return .seconds(seconds)
        }
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.timeZone = TimeZone(secondsFromGMT: 0)
        format.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = format.date(from: trimmed) else { return nil }
        return .seconds(max(0, date.timeIntervalSince(now())))
    }
}
