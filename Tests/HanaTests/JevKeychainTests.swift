import Foundation
import Testing
import Security
@testable import Hana

@MainActor
struct JevKeychainTests {
    @Test func launchReadsKeyOnceAndRefreshesOnlyAfterSaveOrRemove() throws {
        let service = "com.beamseree.hana.tests.\(UUID().uuidString)"
        var secretReads = 0
        let store = JevKeychainStore(service: service, copyMatching: { query, item in
            if (query as NSDictionary)[kSecReturnData] as? Bool == true { secretReads += 1 }
            return SecItemCopyMatching(query, item)
        })
        defer { try? store.remove() }
        try store.save("launch-test-secret")
        let services = ClassifierServices(keychain: store, availability: { .available })
        var options = AutomaticSwitchOptions(); options.classifier = .jev; options.firing = .wordPaced
        #expect(secretReads == 1)
        for _ in 0..<3 {
            #expect(services.hasJevKey)
            #expect(services.makeClassifier(options: options) != nil)
        }
        #expect(secretReads == 1)
        try services.saveJevKey("replacement-launch-secret")
        #expect(secretReads == 2)
        #expect(services.makeClassifier(options: options) != nil)
        #expect(secretReads == 2)
        try services.removeJevKey()
        #expect(secretReads == 3)
        #expect(!services.hasJevKey)
        #expect(services.makeClassifier(options: options) == nil)
        #expect(secretReads == 3)
    }
    @Test func presenceChecksRequestAttributesWithoutSecretData() throws {
        let service = "com.beamseree.hana.tests.\(UUID().uuidString)"
        var queries: [[String: Any]] = []
        let store = JevKeychainStore(service: service, copyMatching: { query, item in
            queries.append(query as! [String: Any])
            return SecItemCopyMatching(query, item)
        })
        defer { try? store.remove() }
        #expect(try store.containsKey() == false)
        try store.save("attributes-test-secret")
        #expect(try store.containsKey() == true)
        #expect(queries.count == 2)
        for query in queries {
            #expect(query[kSecReturnAttributes as String] as? Bool == true)
            #expect(query[kSecReturnData as String] == nil)
            #expect(query[kSecValueData as String] == nil)
        }
    }
    @Test func keySavesReadsReplacesAndRemovesInAnIsolatedService() async throws {
        let service = "com.beamseree.hana.tests.\(UUID().uuidString)"
        let store = JevKeychainStore(service: service)
        defer { try? store.remove() }
        #expect(try store.read() == nil)
        try store.save("first-test-secret")
        #expect(try store.read() == "first-test-secret")
        try store.save("replacement-test-secret")
        #expect(try store.read() == "replacement-test-secret")
        let defaults = UserDefaults(suiteName: service)!
        defer { defaults.removePersistentDomain(forName: service) }
        AutomaticSwitchOptionsStore(defaults: defaults).write(.init())
        #expect(!String(describing: defaults.dictionaryRepresentation()).contains("test-secret"))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(service, isDirectory: true)
        let url = directory.appendingPathComponent("events.jsonl")
        defer { try? FileManager.default.removeItem(at: directory) }
        let diagnostics = AutomaticSwitchDiagnostics(file: url)
        var options = AutomaticSwitchOptions(); options.isEnabled = true
        let savedKey = try store.read()
        let key = try #require(savedKey)
        let adapter = JevClassifier(key: key, transport: { request in
            #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer replacement-test-secret")
            return .init(data: Data(ClassifierAdapterTests.taskResponse.utf8), status: 200)
        })
        let verdict = try await adapter.classify("fixed private input")
        diagnostics.record(.verdict(.init(classifier: .jev, label: .task,
            probability: verdict.probability, latencyMilliseconds: 1, outcome: .switched)), options: options)
        #expect(!String(describing: defaults.dictionaryRepresentation()).contains("test-secret"))
        #expect(!String(describing: UserDefaults.standard.dictionaryRepresentation()).contains("replacement-test-secret"))
        #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("test-secret"))
        try store.remove()
        #expect(try store.read() == nil)
        try store.remove()
    }
}
