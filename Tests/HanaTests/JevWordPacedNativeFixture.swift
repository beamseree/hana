import Foundation
import Testing
@testable import Hana

/// Disposable defaults and diagnostics shared by the three Word-paced native suites.
@MainActor
struct JevWordPacedNativeFixture {
    let name = "Hana.JevWordPacedNativeFixture.\(UUID())"
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let defaults: UserDefaults
    let options: AutomaticSwitchOptionsStore
    let log: AutomaticSwitchDiagnostics

    init(options configure: (inout AutomaticSwitchOptions) -> Void = { _ in }) throws {
        defaults = try #require(UserDefaults(suiteName: name))
        options = AutomaticSwitchOptionsStore(defaults: defaults)
        var value = AutomaticSwitchOptions()
        value.isEnabled = true; value.classifier = .jev; value.firing = .wordPaced
        value.wait = .none
        configure(&value)
        options.write(value)
        log = AutomaticSwitchDiagnostics(file: directory.appendingPathComponent("automatic-switch.jsonl"))
    }

    func interaction(store: CollectionStore, classifier: any Classifier,
                     memory: JevLaunchMemory = JevLaunchMemory()) -> MacInteraction {
        // Search needs a terminal batch to release a held Enter; finishing alone leaves it loading.
        MacInteraction(search: Search(source: { AsyncStream {
            $0.yield(.init(results: [], status: .ready)); $0.finish()
        } }, typingGap: .zero), collection: Task { store }, confirmationDuration: .zero,
            automaticSwitchOptions: options, automaticSwitchDiagnostics: log,
            classifierFactory: { _ in classifier }, jevLaunchMemory: memory)
    }

    func remove() {
        defaults.removePersistentDomain(forName: name)
        try? FileManager.default.removeItem(at: directory)
    }
}
