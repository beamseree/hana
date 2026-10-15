import Foundation

@MainActor
struct JevClassifier: Classifier {
    typealias Transport = @MainActor (URLRequest) async throws -> (Data, Int)
    static let model = "jev-1.13.0"
    private let key: String
    private let transport: Transport
    init(key: String, transport: @escaping Transport = liveTransport) {
        self.key = key
        self.transport = transport
    }
    static func liveTransport(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ClassifierFailure(kind: .malformedResponse) }
        return (data, response.statusCode)
    }
    func classify(_ text: String) async throws -> ClassifierVerdict {
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: "https://api.typesafe.ai/v1/systemone")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 1.5
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "state": text, "model": Self.model,
            "questions": ["classify_input": ["type": "choice", "instructions": ClassifierWording.instructions,
                                                "criteria": ClassifierWording.criteria]]
        ])
        let data: Data, status: Int
        do { (data, status) = try await transport(request) }
        catch {
            try Task.checkCancellation()
            if error is CancellationError || (error as? URLError)?.code == .cancelled { throw CancellationError() }
            throw ClassifierFailure(kind: .network)
        }
        try Task.checkCancellation()
        guard (200..<300).contains(status) else {
            throw ClassifierFailure(kind: status == 401 ? .authentication : status == 429 ? .rateLimited : .network)
        }
        struct Response: Decodable {
            struct Answer: Decodable { let type: String; let choice: String; let probabilities: [String: Double] }
            let model: String
            let answers: [String: Answer]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: data), response.model == Self.model,
              let answer = response.answers["classify_input"], answer.type == "choice",
              Set(answer.probabilities.keys) == Set(ClassifierWording.criteria.keys),
              answer.probabilities.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
              abs(answer.probabilities.values.reduce(0, +) - 1) < 0.001,
              let winning = answer.probabilities[answer.choice], winning == answer.probabilities.values.max() else {
            throw ClassifierFailure(kind: .malformedResponse)
        }
        let labels: [String: ClassifierVerdict.Label] = ["Search": .search, "Note": .note, "Task": .task, "Other": .unsure]
        guard let label = labels[answer.choice] else { throw ClassifierFailure(kind: .malformedResponse) }
        let probabilities = Dictionary(uniqueKeysWithValues: answer.probabilities.map { (labels[$0.key]!, $0.value) })
        try Task.checkCancellation()
        return ClassifierVerdict(label: label, probabilities: probabilities, wordingVersion: ClassifierWording.version)
    }
}
