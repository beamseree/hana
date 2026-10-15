import Foundation
import Synchronization
import Testing
@testable import Hana

/// The URLSession path runs against an in-process URLProtocol, never Jev.
@Suite(.serialized)
@MainActor
struct JevHTTPSessionTests {
    @Test func aNonHTTPResponseRemainsAContentFreeMalformedFailure() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); StubProtocol.handler.withLock { $0 = nil } }
        StubProtocol.handler.withLock { handler in
            handler = { request in
                (Data("untrusted response".utf8),
                    URLResponse(url: request.url!, mimeType: nil, expectedContentLength: 18, textEncodingName: nil))
            }
        }
        let transport = JevHTTPSession(session: session)
        let adapter = JevClassifier(key: "test-key", transport: transport.perform)
        do { _ = try await adapter.classify("call mom"); Issue.record("Expected malformed response") }
        catch { #expect((error as? ClassifierFailure)?.kind == .malformedResponse) }
    }

    @Test func retainedSessionServesIndependentAdaptersAndPreservesRetryAfter() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); StubProtocol.handler.withLock { $0 = nil } }
        let requests = Mutex<[String]>([])
        StubProtocol.handler.withLock { handler in
            handler = { request in
                let count = requests.withLock { values in
                    values.append(request.url!.absoluteString)
                    return values.count
                }
                let response = HTTPURLResponse(url: request.url!, statusCode: count == 1 ? 200 : 429,
                    httpVersion: "HTTP/1.1", headerFields: ["Retry-After": "5"])!
                return (Data(ClassifierAdapterTests.taskResponse.utf8), response)
            }
        }
        let transport = JevHTTPSession(session: session)
        let first = JevClassifier(key: "test-key", transport: transport.perform)
        #expect(try await first.classify("call mom").label == .task)
        // A new adapter models the next bar session; the HTTP owner survives it.
        let second = JevClassifier(key: "test-key", transport: transport.perform)
        do { _ = try await second.classify("buy milk"); Issue.record("Expected rate limit") }
        catch {
            #expect((error as? ClassifierFailure)?.kind == .rateLimited)
            #expect((error as? ClassifierFailure)?.retryAfter == .seconds(5))
        }
        #expect(requests.withLock { $0 } == [
            "https://api.typesafe.ai/v1/systemone", "https://api.typesafe.ai/v1/systemone"
        ])
    }

    private final class StubProtocol: URLProtocol, @unchecked Sendable {
        typealias Handler = @Sendable (URLRequest) throws -> (Data, URLResponse)
        // URLProtocol calls occur off the test actor. Handler mutation is locked.
        static let handler = Mutex<Handler?>(nil)
        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
        override func startLoading() {
            do {
                guard let handle = Self.handler.withLock({ $0 }) else { throw URLError(.badServerResponse) }
                let (data, response) = try handle(request)
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: data)
                client?.urlProtocolDidFinishLoading(self)
            } catch { client?.urlProtocol(self, didFailWithError: error) }
        }
        override func stopLoading() {}
    }
}
