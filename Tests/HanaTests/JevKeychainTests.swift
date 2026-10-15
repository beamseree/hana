import Foundation
import Testing
@testable import Hana

@MainActor
struct JevKeychainTests {
    @Test func keySavesReadsReplacesAndRemovesInAnIsolatedService() throws {
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
        diagnostics.resetCounts(options: options)
        #expect(!String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("test-secret"))
        try store.remove()
        #expect(try store.read() == nil)
        try store.remove()
    }
}
