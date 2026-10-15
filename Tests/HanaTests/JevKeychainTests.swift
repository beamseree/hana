import Foundation
import Testing
@testable import Hana

@MainActor
struct JevKeychainTests {
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
            return (Data(ClassifierAdapterTests.taskResponse.utf8), 200)
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
