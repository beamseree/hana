import Foundation

/// One retained HTTP session for the launch, shared by every live Jev adapter.
/// URLSession manages persistent connections; closing the bar never invalidates
/// this session. Ephemeral storage keeps its caches and credentials off disk.
@MainActor
final class JevHTTPSession {
    static let live = JevHTTPSession()
    private let session: URLSession

    init(session: URLSession = URLSession(configuration: .ephemeral)) {
        self.session = session
    }

    func perform(_ request: URLRequest) async throws -> JevClassifier.Response {
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else {
            throw ClassifierFailure(kind: .malformedResponse)
        }
        return .init(data: data, status: response.statusCode,
            retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
    }
}
