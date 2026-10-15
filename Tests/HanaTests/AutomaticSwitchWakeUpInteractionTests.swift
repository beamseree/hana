import AppKit
import Testing
@testable import Hana

/// Mac Interaction sleeps until the policy's reported wake-up time instead of ticking every 25 ms.
@Suite(.serialized, .nativeWindowSlot)
@MainActor
struct AutomaticSwitchWakeUpInteractionTests {
    @Test func debouncedRequestFiresAtItsReportedTimeAndNothingWakesWhileNothingIsPending() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture(); defer { fixture.remove() }
        let storage = try TemporaryFixture(); let store = try await CollectionStore.open(storage.location)
        let fake = ScriptedClassifier(), apps = CatalogFeed()
        let interaction = fixture.interaction(apps: apps, store: store, classifier: fake)
        let invocation = interaction.presentBar(); defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await editor()
        // An open, empty bar has no deadline, so it is never woken.
        try await Task.sleep(for: .milliseconds(200))
        #expect(interaction.automaticSwitchWakeTime == nil && interaction.automaticSwitchWakeUps == 0)

        let typed = ContinuousClock.now
        editor.insertText("private wake lookup", replacementRange: NSRange(location: NSNotFound, length: 0))
        let debounce = try #require(interaction.automaticSwitchWakeTime)
        #expect(debounce - typed >= .milliseconds(150) && debounce - typed < .milliseconds(400))
        #expect(fake.pendingCount == 0 && interaction.automaticSwitchWakeUps == 0)

        try await eventually { fake.pendingCount == 1 }
        #expect(ContinuousClock.now >= debounce)
        #expect(interaction.automaticSwitchWakeUps == 1)
        // Only the request's 1.5 s timeout remains pending.
        let timeout = try #require(interaction.automaticSwitchWakeTime)
        #expect(timeout - debounce >= .milliseconds(1500) && timeout - debounce < .milliseconds(1600))

        await apps.send([])
        fake.reply(.search)
        try await eventually { (try? String(contentsOf: fixture.log.url, encoding: .utf8).contains("autoswitch.verdict")) == true }
        #expect(interaction.automaticSwitchWakeTime == nil)
        try await Task.sleep(for: .milliseconds(200))
        #expect(interaction.automaticSwitchWakeUps == 1 && interaction.automaticSwitchWakeTime == nil)
        #expect(fake.inputs == ["private wake lookup"] && interaction.mode == .search)
        await store.close()
    }

    @Test func newerWakeUpTimeReplacesThePendingSleep() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture(); defer { fixture.remove() }
        let storage = try TemporaryFixture(); let store = try await CollectionStore.open(storage.location)
        let fake = ScriptedClassifier(), apps = CatalogFeed()
        let interaction = fixture.interaction(apps: apps, store: store, classifier: fake)
        let invocation = interaction.presentBar(); defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await editor()
        editor.insertText("private wake", replacementRange: NSRange(location: NSNotFound, length: 0))
        let first = try #require(interaction.automaticSwitchWakeTime)
        try await Task.sleep(for: .milliseconds(60))
        editor.insertText(" lookup", replacementRange: NSRange(location: NSNotFound, length: 0))
        let second = try #require(interaction.automaticSwitchWakeTime)
        #expect(second - first >= .milliseconds(60))
        try await eventually { fake.pendingCount == 1 }
        #expect(ContinuousClock.now >= second)
        // The replaced sleep never delivered a wake-up or an early request.
        #expect(interaction.automaticSwitchWakeUps == 1 && fake.inputs == ["private wake lookup"])
        await store.close()
    }

    @Test func dismissCancelsThePendingWakeUp() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture(); defer { fixture.remove() }
        let storage = try TemporaryFixture(); let store = try await CollectionStore.open(storage.location)
        let fake = ScriptedClassifier(), apps = CatalogFeed()
        let interaction = fixture.interaction(apps: apps, store: store, classifier: fake)
        let invocation = interaction.presentBar()
        let editor = try await editor()
        editor.insertText("private wake lookup", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(interaction.automaticSwitchWakeTime != nil)
        interaction.dismiss(invocation, reason: .outsideClick)
        #expect(interaction.automaticSwitchWakeTime == nil)
        try await Task.sleep(for: .milliseconds(250))
        #expect(interaction.automaticSwitchWakeUps == 0 && fake.inputs.isEmpty)
        await store.close()
    }

    private func editor() async throws -> NSTextView {
        try await eventually { NSApp.keyWindow?.firstResponder is NSTextView }
        return try #require(NSApp.keyWindow?.firstResponder as? NSTextView)
    }

    @MainActor private struct Fixture {
        let name = "Hana.AutomaticSwitchWakeUpTests.\(UUID())"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults: UserDefaults
        let options: AutomaticSwitchOptionsStore
        let log: AutomaticSwitchDiagnostics
        init() throws {
            defaults = try #require(UserDefaults(suiteName: name))
            options = AutomaticSwitchOptionsStore(defaults: defaults)
            log = AutomaticSwitchDiagnostics(file: directory.appendingPathComponent("automatic-switch.jsonl"))
            var value = options.read(); value.isEnabled = true; value.firing = .debounced; options.write(value)
        }
        func interaction(apps: CatalogFeed, store: CollectionStore, classifier: ScriptedClassifier) -> MacInteraction {
            MacInteraction(search: Search(source: { apps.stream() }, typingGap: .zero),
                collection: Task { store }, automaticSwitchOptions: options,
                automaticSwitchDiagnostics: log, classifierFactory: { _ in classifier })
        }
        func remove() {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
