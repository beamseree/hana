import AppKit
import Testing
@testable import Hana

/// Real editor and disposable Store with controlled Jev answers; no live API.
/// These assertions cover AppKit command delivery, not physical keyboard focus.
@Suite(.serialized, .nativeWindowSlot, .timeLimit(.minutes(1)))
@MainActor
struct JevPipelineNativeTests {
    private let insertion = NSRange(location: NSNotFound, length: 0)

    @Test func prefixAnswerKeepsTheCurrentBufferAndSelectionAndEnterSavesExactlyOnce() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture(); defer { fixture.remove() }
        let storage = try TemporaryFixture()
        let store = try await CollectionStore.open(storage.location)
        let fake = ScriptedClassifier()
        let interaction = fixture.interaction(store: store, classifier: fake)
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await editor()

        editor.insertText("call mom", replacementRange: insertion)
        try await eventually { fake.pendingCount == 1 }
        editor.insertText(" tomorrow บ้าน", replacementRange: insertion)
        let currentText = editor.string
        let selection = NSRange(location: 2, length: 4)
        editor.setSelectedRange(selection)
        #expect(fake.inputs.first == "call mom")
        fake.reply(.task, probability: 0.95)
        try await eventually { interaction.mode == .task }
        #expect(editor.string == currentText && editor.selectedRange() == selection)
        #expect(interaction.rows.isEmpty && !interaction.resultsVisible)

        // The existing 300 ms safety guard must also apply to a prefix verdict.
        editor.keyDown(with: try returnKey())
        #expect(interaction.currentInvocation == invocation && interaction.modeLabelText != "Saving…")
        let before = try await store.read(.allRecords, in: store.generation)
        #expect(before.notes.isEmpty && before.tasks.isEmpty)
        try await Task.sleep(for: .milliseconds(310))
        editor.keyDown(with: try returnKey())
        editor.keyDown(with: try returnKey())
        try await eventually { interaction.currentInvocation == nil }
        let after = try await store.read(.allRecords, in: store.generation)
        #expect(after.notes.isEmpty && after.tasks.map(\.title) == [currentText])
        await store.close()
    }

    @Test func captureStopsRequestsUntilNativeDeleteClearsItAndRearmsSearch() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture(); defer { fixture.remove() }
        let storage = try TemporaryFixture()
        let store = try await CollectionStore.open(storage.location)
        let fake = ScriptedClassifier()
        let interaction = fixture.interaction(store: store, classifier: fake)
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await editor()

        editor.insertText("call mom", replacementRange: insertion)
        try await eventually { fake.pendingCount == 1 }
        fake.reply(.task, probability: 0.95)
        try await eventually { interaction.mode == .task }
        let requestsAtCapture = fake.inputs.count
        editor.insertText(" tomorrow", replacementRange: insertion)
        try await Task.sleep(for: .milliseconds(230))
        #expect(interaction.mode == .task && fake.inputs.count == requestsAtCapture)
        #expect(editor.string == "call mom tomorrow")

        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
        editor.keyDown(with: try backspaceKey())
        try await eventually { interaction.mode == .search }
        #expect(editor.string.isEmpty && editor.selectedRange() == NSRange(location: 0, length: 0))
        #expect(interaction.currentInvocation == invocation)
        editor.insertText("new thought", replacementRange: insertion)
        try await eventually { fake.inputs.count == requestsAtCapture + 1 && fake.pendingCount == 1 }
        #expect(fake.inputs.last == "new thought")
        fake.reply(.note, probability: 0.95)
        try await eventually { interaction.mode == .note }
        #expect(editor.string == "new thought")
        let records = try await store.read(.allRecords, in: store.generation)
        #expect(records.notes.isEmpty && records.tasks.isEmpty)
        await store.close()
    }

    @Test func backspaceAtTheStartKeepsTextAndSuspendsUntilTheBufferIsCleared() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture(); defer { fixture.remove() }
        let storage = try TemporaryFixture()
        let store = try await CollectionStore.open(storage.location)
        let fake = ScriptedClassifier()
        let interaction = fixture.interaction(store: store, classifier: fake)
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await editor()

        editor.insertText("call mom", replacementRange: insertion)
        try await eventually { fake.pendingCount == 1 }
        fake.reply(.task, probability: 0.95)
        try await eventually { interaction.mode == .task }
        let requestsAtCapture = fake.inputs.count
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.keyDown(with: try backspaceKey())
        #expect(interaction.mode == .search && editor.string == "call mom")
        #expect(editor.selectedRange() == NSRange(location: 0, length: 0))
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertText(" tomorrow", replacementRange: insertion)
        try await Task.sleep(for: .milliseconds(230))
        #expect(interaction.mode == .search && fake.inputs.count == requestsAtCapture)

        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
        editor.keyDown(with: try backspaceKey())
        #expect(interaction.mode == .search && editor.string.isEmpty)
        editor.insertText("buy milk", replacementRange: insertion)
        try await eventually { fake.inputs.count == requestsAtCapture + 1 && fake.pendingCount == 1 }
        fake.reply(.task, probability: 0.95)
        try await eventually { interaction.mode == .task }
        #expect(editor.string == "buy milk")
        await store.close()
    }

    private func editor() async throws -> NSTextView {
        try await eventually { NSApp.keyWindow?.title == "Hana Search" && NSApp.keyWindow?.firstResponder is NSTextView }
        return try #require(NSApp.keyWindow?.firstResponder as? NSTextView)
    }

    @MainActor private struct Fixture {
        let name = "Hana.JevPipelineNativeTests.\(UUID())"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults: UserDefaults
        let options: AutomaticSwitchOptionsStore
        let log: AutomaticSwitchDiagnostics

        init() throws {
            defaults = try #require(UserDefaults(suiteName: name))
            options = AutomaticSwitchOptionsStore(defaults: defaults)
            var value = AutomaticSwitchOptions()
            value.isEnabled = true
            value.classifier = .jev
            value.firing = .pipelinedJev
            value.afterSwitch = .stay
            value.wait = .none
            options.write(value)
            log = AutomaticSwitchDiagnostics(file: directory.appendingPathComponent("automatic-switch.jsonl"))
        }

        func interaction(store: CollectionStore, classifier: ScriptedClassifier) -> MacInteraction {
            MacInteraction(search: Search(source: { AsyncStream { $0.finish() } }, typingGap: .zero),
                collection: Task { store }, confirmationDuration: .zero,
                automaticSwitchOptions: options, automaticSwitchDiagnostics: log,
                classifierFactory: { _ in classifier })
        }

        func remove() {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
