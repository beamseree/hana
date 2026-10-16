import AppKit
import Testing
@testable import Hana

/// Native command delivery with disposable defaults, storage and a scripted classifier.
@Suite(.serialized, .nativeWindowSlot)
@MainActor
struct CalculationAutomaticSwitchInteractionTests {
    @Test(arguments: AutomaticSwitchOptions.Firing.allCases)
    func enterCopiesImmediatelyWhileSourcesLoadWithoutClassifyingOrSaving(firing: AutomaticSwitchOptions.Firing) async throws {
        _ = NSApplication.shared
        let fixture = try JevWordPacedNativeFixture { $0.firing = firing }; defer { fixture.remove() }
        fixture.options.debugMode = true
        let storage = try TemporaryFixture(), fake = ScriptedClassifier(), apps = CatalogFeed(), files = CatalogFeed()
        defer { try? FileManager.default.removeItem(at: storage.directory) }
        let store = try await CollectionStore.open(storage.location)
        var copied: [String] = []
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, files: { _ in files.stream() }, typingGap: .zero),
            copyAnswer: { copied.append($0) }, collection: Task { store }, automaticSwitchOptions: fixture.options,
            automaticSwitchDiagnostics: fixture.log, classifierFactory: { _ in fake })
        let invocation = interaction.presentBar(); defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await editor()
        editor.insertText("1200 / 3", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(interaction.selectedRow == .answer && interaction.isLoading)
        #expect(interaction.debugFooterText?.contains("blocked: Calculation") == true)
        // Covers the longest firing delay as well as Word-paced's pause wake-up.
        try await Task.sleep(for: .milliseconds(550))
        #expect(fake.inputs.isEmpty && interaction.mode == .search)
        editor.keyDown(with: try returnKey())
        #expect(copied == ["400"] && interaction.currentInvocation == nil)
        #expect(fake.inputs.isEmpty)
        let records = try await store.read(.allRecords, in: store.generation)
        #expect(records.notes.isEmpty && records.tasks.isEmpty)
        await store.close()
    }

    @Test(arguments: ["12 *", "(3 + 4", "sqrt", "1 / 0", "sqrt(-1)", "9^9^9", "3 + * 4", "1..2"])
    func nonValueCalculationsRemainBlockedInTheDebugFooter(_ text: String) async throws {
        _ = NSApplication.shared
        let fixture = try JevWordPacedNativeFixture(); defer { fixture.remove() }
        fixture.options.debugMode = true
        let fake = ScriptedClassifier(), apps = CatalogFeed()
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, typingGap: .zero),
            automaticSwitchOptions: fixture.options, automaticSwitchDiagnostics: fixture.log,
            classifierFactory: { _ in fake })
        let invocation = interaction.presentBar(); defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await editor()
        editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        await apps.send([])
        try await Task.sleep(for: .milliseconds(250))
        #expect(fake.inputs.isEmpty && interaction.mode == .search)
        #expect(interaction.debugFooterText?.contains("blocked: Calculation") == true)
    }

    @Test func addingAWordRestoresSuggestionsAndTheClassifier() async throws {
        _ = NSApplication.shared
        let fixture = try JevWordPacedNativeFixture { $0.firing = .everyKeystroke }; defer { fixture.remove() }
        fixture.options.debugMode = true
        let storage = try TemporaryFixture(), fake = ScriptedClassifier(), apps = CatalogFeed()
        defer { try? FileManager.default.removeItem(at: storage.directory) }
        let store = try await CollectionStore.open(storage.location)
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, typingGap: .zero),
            collection: Task { store },
            automaticSwitchOptions: fixture.options, automaticSwitchDiagnostics: fixture.log,
            classifierFactory: { _ in fake })
        let invocation = interaction.presentBar(); defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await editor()
        editor.insertText("1200 / 3", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(fake.inputs.isEmpty && interaction.selectedRow == .answer)
        editor.insertText(" rent", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await eventually { fake.pendingCount == 1 }
        #expect(fake.inputs == ["1200 / 3 rent"])
        #expect(interaction.rows.map(\.id) == [.suggestion(.note), .suggestion(.task)])
        #expect(interaction.debugFooterText?.contains("Calculation") == false)
        await store.close()
    }

    @Test func replacingAQueuedSubmissionWithACalculationCopiesWithoutALateSave() async throws {
        _ = NSApplication.shared
        let fixture = try JevWordPacedNativeFixture(); defer { fixture.remove() }
        let storage = try TemporaryFixture(), fake = ScriptedClassifier(), apps = CatalogFeed()
        defer { try? FileManager.default.removeItem(at: storage.directory) }
        let store = try await CollectionStore.open(storage.location)
        var copied: [String] = []
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, typingGap: .zero),
            copyAnswer: { copied.append($0) }, collection: Task { store }, automaticSwitchOptions: fixture.options,
            automaticSwitchDiagnostics: fixture.log, classifierFactory: { _ in fake })
        let invocation = interaction.presentBar(); defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await editor()
        editor.insertText("buy paper ", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await eventually { fake.pendingCount == 1 }
        editor.keyDown(with: try returnKey())
        #expect(interaction.statusMessage == "Deciding how to save…")
        editor.insertText("1200 / 3", replacementRange: NSRange(location: 0, length: editor.string.utf16.count))
        #expect(interaction.selectedRow == .answer)
        editor.keyDown(with: try returnKey())
        #expect(copied == ["400"] && interaction.currentInvocation == nil)
        fake.reply(.task, probability: 0.95)
        try await Task.sleep(for: .milliseconds(80))
        let records = try await store.read(.allRecords, in: store.generation)
        #expect(records.notes.isEmpty && records.tasks.isEmpty)
        #expect(fake.inputs == ["buy paper"])
        await store.close()
    }

    private func editor() async throws -> NSTextView {
        try await eventually { NSApp.keyWindow?.firstResponder is NSTextView }
        return try #require(NSApp.keyWindow?.firstResponder as? NSTextView)
    }
}
