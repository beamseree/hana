import AppKit
import Testing
@testable import Hana

/// Real command delivery and disposable storage; never calls the live Jev API.
@Suite(.serialized, .nativeWindowSlot, .timeLimit(.minutes(1)))
@MainActor
struct JevSubmissionNativeTests {
    @Test(arguments: [ClassifierVerdict.Label.note, .task], AutomaticSwitchOptions.Firing.allCases)
    func enterWaitsAndCommitsTheExactTextOnce(label: ClassifierVerdict.Label, firing: AutomaticSwitchOptions.Firing) async throws {
        _ = NSApplication.shared
        let fixture = try JevWordPacedNativeFixture { $0.firing = firing }; defer { fixture.remove() }
        let storage = try TemporaryFixture(), fake = ScriptedClassifier()
        let store = try await CollectionStore.open(storage.location)
        let interaction = fixture.interaction(store: store, classifier: fake)
        let invocation = interaction.presentBar(); defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await editor()
        let text = "call  mom tomorrow บ้าน"
        editor.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
        try await eventually { !interaction.isLoading }
        editor.keyDown(with: try returnKey())
        editor.keyDown(with: try returnKey())
        #expect(interaction.statusMessage == "Deciding how to save…" && interaction.isLoading)
        try await eventually { fake.pendingCount == 1 }
        #expect(fake.inputs.count == 1)
        fake.reply(label, probability: 0.95)
        // The Enter which requested this answer bypasses the post-switch grace.
        try await eventually { interaction.currentInvocation == nil }
        let records = try await store.read(.allRecords, in: store.generation)
        #expect(records.notes.map(\.body) == (label == .note ? [text] : []))
        #expect(records.tasks.map(\.title) == (label == .task ? [text] : []))
        await store.close()
    }

    @Test func prefixReplyCannotSaveBeforeTheFullTextReply() async throws {
        _ = NSApplication.shared
        let fixture = try JevWordPacedNativeFixture(); defer { fixture.remove() }
        let storage = try TemporaryFixture(), fake = ScriptedClassifier()
        let store = try await CollectionStore.open(storage.location)
        let interaction = fixture.interaction(store: store, classifier: fake)
        let invocation = interaction.presentBar(); defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await editor()
        editor.insertText("call mom ", replacementRange: NSRange(location: NSNotFound, length: 0))
        try await eventually { fake.pendingCount == 1 }
        editor.insertText("tomorrow", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.keyDown(with: try returnKey())
        try await eventually { fake.pendingCount == 2 }
        #expect(fake.inputs == ["call mom", "call mom tomorrow"])
        fake.reply(.note, probability: 0.95)
        try await eventually { fake.pendingCount == 1 }
        #expect(interaction.mode == .search && interaction.statusMessage == "Deciding how to save…")
        let before = try await store.read(.allRecords, in: store.generation)
        #expect(before.notes.isEmpty && before.tasks.isEmpty)
        fake.reply(.task, probability: 0.95)
        try await eventually { interaction.currentInvocation == nil }
        let after = try await store.read(.allRecords, in: store.generation)
        #expect(after.notes.isEmpty && after.tasks.map(\.title) == ["call mom tomorrow"])
        await store.close()
    }

    @Test(arguments: ["edit", "navigate", "dismiss"])
    func changingIntentPreventsALateSave(action: String) async throws {
        _ = NSApplication.shared
        let fixture = try JevWordPacedNativeFixture { $0.navigationSuspends = false }; defer { fixture.remove() }
        let storage = try TemporaryFixture(), fake = ScriptedClassifier()
        let store = try await CollectionStore.open(storage.location)
        let interaction = fixture.interaction(store: store, classifier: fake)
        let invocation = interaction.presentBar(); defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await editor()
        editor.insertText("call mom tomorrow", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.keyDown(with: try returnKey())
        try await eventually { fake.pendingCount == 1 }
        switch action {
        case "edit": editor.insertText(" please", replacementRange: NSRange(location: NSNotFound, length: 0))
        case "navigate": interaction.moveSelection(by: 1)
        default: interaction.dismiss(invocation, reason: .escape)
        }
        fake.reply(.task, probability: 0.95)
        try await Task.sleep(for: .milliseconds(80))
        let records = try await store.read(.allRecords, in: store.generation)
        #expect(records.notes.isEmpty && records.tasks.isEmpty)
        #expect(interaction.statusMessage != "Deciding how to save…")
        await store.close()
    }

    @Test(arguments: ["search", "unsure", "failure", "timeout"])
    func unresolvedDecisionKeepsTextAndDoesNotOpenAWeakResult(outcome: String) async throws {
        _ = NSApplication.shared
        let fixture = try JevWordPacedNativeFixture(); defer { fixture.remove() }
        let storage = try TemporaryFixture(), fake = ScriptedClassifier(), apps = CatalogFeed()
        let store = try await CollectionStore.open(storage.location)
        var opens = 0
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, typingGap: .zero),
            launchApplication: { _ in opens += 1; return .init(activate: { true }) },
            collection: Task { store }, automaticSwitchOptions: fixture.options,
            automaticSwitchDiagnostics: fixture.log, classifierFactory: { _ in fake })
        let invocation = interaction.presentBar(); defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await editor()
        editor.insertText("call mom", replacementRange: NSRange(location: NSNotFound, length: 0))
        let weak = SearchResult(name: "My call mom tool", url: URL(fileURLWithPath: "/fixture/Weak.app"))
        await apps.send([weak])
        try await eventually { interaction.selectedResult == weak }
        editor.keyDown(with: try returnKey())
        try await eventually { fake.pendingCount == 1 }
        switch outcome {
        case "search": fake.reply(.search, probability: 0.95)
        case "unsure": fake.reply(.unsure, probability: 0.95)
        case "failure": fake.fail(.network)
        default: break
        }
        try await eventually { interaction.statusMessage?.contains("kept") == true || interaction.statusMessage?.hasPrefix("Not saved") == true }
        #expect(interaction.currentInvocation == invocation && interaction.query == "call mom" && opens == 0)
        let records = try await store.read(.allRecords, in: store.generation)
        #expect(records.notes.isEmpty && records.tasks.isEmpty)
        await store.close()
    }

    @Test(arguments: [true, false])
    func strongOrExplicitlySelectedResultOpensWithoutWaitingForJev(strong: Bool) async throws {
        _ = NSApplication.shared
        let fixture = try JevWordPacedNativeFixture(); defer { fixture.remove() }
        let storage = try TemporaryFixture(), fake = ScriptedClassifier(), apps = CatalogFeed()
        let store = try await CollectionStore.open(storage.location)
        var opens = 0
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, typingGap: .zero),
            launchApplication: { _ in opens += 1; return .init(activate: { true }) },
            collection: Task { store }, automaticSwitchOptions: fixture.options,
            automaticSwitchDiagnostics: fixture.log, classifierFactory: { _ in fake })
        let invocation = interaction.presentBar(); defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await editor()
        editor.insertText("call mom", replacementRange: NSRange(location: NSNotFound, length: 0))
        let result = SearchResult(name: strong ? "call mom" : "My call mom tool", url: URL(fileURLWithPath: "/fixture/Tool.app"))
        await apps.send([result]); try await eventually { interaction.selectedResult == result }
        if !strong { interaction.moveSelection(by: 0) }
        editor.keyDown(with: try returnKey())
        try await eventually { interaction.currentInvocation == nil }
        #expect(opens == 1)
        let records = try await store.read(.allRecords, in: store.generation)
        #expect(records.notes.isEmpty && records.tasks.isEmpty)
        await store.close()
    }

    private func editor() async throws -> NSTextView {
        try await eventually { NSApp.keyWindow?.firstResponder is NSTextView }
        return try #require(NSApp.keyWindow?.firstResponder as? NSTextView)
    }
}
