import AppKit
import Testing
@testable import Hana

/// Real editor and disposable Store with controlled Jev answers; no live API.
/// These assertions cover AppKit command delivery, not physical keyboard focus.
@Suite(.serialized, .nativeWindowSlot, .timeLimit(.minutes(1)))
@MainActor
struct JevWordPacedNativeTests {
    private let insertion = NSRange(location: NSNotFound, length: 0)

    @Test func typingAPhraseSendsOnlyBoundaryAndPauseRequestsAndASwitchKeepsTextAndSelection() async throws {
        _ = NSApplication.shared
        let fixture = try JevWordPacedNativeFixture(); defer { fixture.remove() }
        let storage = try TemporaryFixture()
        let store = try await CollectionStore.open(storage.location)
        let fake = ScriptedClassifier()
        let interaction = fixture.interaction(store: store, classifier: fake)
        var invocation: MacInteraction.Invocation? = interaction.presentBar()
        defer { if let invocation { interaction.dismiss(invocation, reason: .outsideClick) } }
        let editor = try await editor()

        // "call " completes one word only; the pause after "mom" sends.
        type("call mom", into: editor)
        try await eventually { fake.inputs == ["call mom"] }
        fake.reply(.search, probability: 0.95)
        // The space completes "mom", answered or still in flight; the pause after "tomorrow" sends.
        type(" tomorrow", into: editor)
        try await eventually { fake.inputs == ["call mom", "call mom tomorrow"] }
        // The space duplicates the request in flight; the next one completes "at" and sends at once.
        type(" at ", into: editor)
        try await eventually { fake.inputs.count == 3 && fake.pendingCount == 2 }
        #expect(fake.inputs.last == "call mom tomorrow at")

        let currentText = editor.string
        let selection = NSRange(location: 2, length: 4)
        editor.setSelectedRange(selection)
        // The answer for the earlier words switches; staying cancels the newer request.
        fake.reply(.task, probability: 0.95)
        try await eventually { interaction.mode == .task }
        #expect(editor.string == currentText && editor.selectedRange() == selection)
        #expect(interaction.rows.isEmpty && !interaction.resultsVisible)
        try await eventually { fake.pendingCount == 0 }

        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        type("noon today", into: editor)
        try await Task.sleep(for: .milliseconds(300))
        #expect(interaction.mode == .task && fake.inputs.count == 3)

        interaction.dismiss(try #require(invocation), reason: .outsideClick); invocation = nil
        let rows = try logRows(fixture)
        let sessions = rows.filter { $0["event"] as? String == "autoswitch.session" }
        #expect(sessions.count == 1 && sessions.first?["requestsSent"] as? Int == 3)
        let text = try String(contentsOf: fixture.log.url, encoding: .utf8)
        #expect(!text.contains("call mom") && !text.contains("tomorrow") && !text.contains("noon"))
        await store.close()
    }

    @Test func prefixAnswerKeepsTheCurrentBufferAndSelectionAndEnterSavesExactlyOnce() async throws {
        _ = NSApplication.shared
        let fixture = try JevWordPacedNativeFixture(); defer { fixture.remove() }
        let storage = try TemporaryFixture()
        let store = try await CollectionStore.open(storage.location)
        let fake = ScriptedClassifier()
        let interaction = fixture.interaction(store: store, classifier: fake)
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await editor()

        type("call mom", into: editor)
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
        let fixture = try JevWordPacedNativeFixture(); defer { fixture.remove() }
        let storage = try TemporaryFixture()
        let store = try await CollectionStore.open(storage.location)
        let fake = ScriptedClassifier()
        let interaction = fixture.interaction(store: store, classifier: fake)
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await editor()

        type("call mom", into: editor)
        try await eventually { fake.pendingCount == 1 }
        fake.reply(.task, probability: 0.95)
        try await eventually { interaction.mode == .task }
        let requestsAtCapture = fake.inputs.count
        type(" tomorrow ", into: editor)
        try await Task.sleep(for: .milliseconds(300))
        #expect(interaction.mode == .task && fake.inputs.count == requestsAtCapture)
        #expect(editor.string == "call mom tomorrow ")

        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
        editor.keyDown(with: try backspaceKey())
        try await eventually { interaction.mode == .search }
        #expect(editor.string.isEmpty && editor.selectedRange() == NSRange(location: 0, length: 0))
        #expect(interaction.currentInvocation == invocation)
        type("new thought", into: editor)
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
        let fixture = try JevWordPacedNativeFixture(); defer { fixture.remove() }
        var options = fixture.options.read(); options.reversalBehavior = .stopUntilCleared
        fixture.options.write(options)
        let storage = try TemporaryFixture()
        let store = try await CollectionStore.open(storage.location)
        let fake = ScriptedClassifier()
        let interaction = fixture.interaction(store: store, classifier: fake)
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await editor()

        type("call mom", into: editor)
        try await eventually { fake.pendingCount == 1 }
        fake.reply(.task, probability: 0.95)
        try await eventually { interaction.mode == .task }
        let requestsAtCapture = fake.inputs.count
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.keyDown(with: try backspaceKey())
        #expect(interaction.mode == .search && editor.string == "call mom")
        #expect(editor.selectedRange() == NSRange(location: 0, length: 0))
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        type(" tomorrow ", into: editor)
        try await Task.sleep(for: .milliseconds(300))
        #expect(interaction.mode == .search && fake.inputs.count == requestsAtCapture)

        editor.setSelectedRange(NSRange(location: 0, length: (editor.string as NSString).length))
        editor.keyDown(with: try backspaceKey())
        #expect(interaction.mode == .search && editor.string.isEmpty)
        type("buy milk ", into: editor)
        try await eventually { fake.inputs.count == requestsAtCapture + 1 && fake.pendingCount == 1 }
        fake.reply(.task, probability: 0.95)
        try await eventually { interaction.mode == .task }
        #expect(editor.string == "buy milk ")
        await store.close()
    }

    @Test func requestsLeftOverFromAClosedBarStillCountTowardTheCapOfTwo() async throws {
        _ = NSApplication.shared
        let fixture = try JevWordPacedNativeFixture(); defer { fixture.remove() }
        let storage = try TemporaryFixture()
        let store = try await CollectionStore.open(storage.location)
        let fake = HeldJev()
        let memory = JevLaunchMemory()
        let interaction = fixture.interaction(store: store, classifier: fake, memory: memory)
        var invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        var editor = try await editor()

        type("call mom ", into: editor)
        try await eventually { fake.inputs.count == 1 }
        type("tomorrow ", into: editor)
        try await eventually { fake.inputs.count == 2 }
        interaction.dismiss(invocation, reason: .outsideClick)
        // Both requests ignore cancellation, as sent HTTP work may.
        #expect(memory.inFlightCount == 2)

        invocation = interaction.presentBar()
        editor = try await self.editor()
        type("buy milk ", into: editor)
        try await Task.sleep(for: .milliseconds(300))
        #expect(fake.inputs.count == 2)
        fake.finishFirst()
        try await eventually { fake.inputs.count == 3 }
        #expect(fake.inputs.last == "buy milk" && memory.inFlightCount == 2)
        fake.finishAll()
        try await eventually { memory.inFlightCount == 0 }
        await store.close()
    }

    @Test func firesMenuShowsWordPacedOnlyForJevAndMigratesAStoredPipelineChoice() throws {
        _ = NSApplication.shared
        let fixture = try JevWordPacedNativeFixture(); defer { fixture.remove() }
        var legacy = AutomaticSwitchOptions(); legacy.classifier = .jev; legacy.firing = .wordPaced
        let encoded = try #require(String(data: JSONEncoder().encode(legacy), encoding: .utf8))
        let stored = encoded.replacingOccurrences(of: "\"wordPaced\"", with: "\"pipelinedJev\"")
        #expect(stored.contains("pipelinedJev"))
        fixture.defaults.set(Data(stored.utf8), forKey: "automaticSwitch.prototype.options.v1")

        let interaction = MacInteraction(automaticSwitchOptions: fixture.options, automaticSwitchDiagnostics: fixture.log)
        let previousMenu = NSApp.mainMenu, previousWindows = NSApp.windowsMenu
        interaction.start()
        defer { interaction.stop(); NSApp.mainMenu = previousMenu; NSApp.windowsMenu = previousWindows }
        let menu = try #require(interaction.automaticSwitchMenu)
        menu.delegate?.menuWillOpen?(menu)
        let firing = try #require(menu.item(withTitle: "Fires")?.submenu)
        #expect(firing.items.map(\.title) == ["Every keystroke", "Debounced (150 ms)", "On pause (500 ms)", "Word-paced"])
        #expect(fixture.options.read().firing == .wordPaced && fixture.options.read().classifier == .jev)
        #expect(firing.item(withTitle: "Word-paced")?.state == .on)
        #expect(firing.item(withTitle: "Word-paced")?.isEnabled == true)

        let choices = try #require(menu.item(withTitle: "Classifier")?.submenu)
        choices.performActionForItem(at: choices.indexOfItem(withTitle: "Foundation Models"))
        #expect(fixture.options.read().firing == .debounced)
        #expect(firing.item(withTitle: "Word-paced")?.isEnabled == false)
        #expect(firing.item(withTitle: "Debounced (150 ms)")?.state == .on)
    }

    private func type(_ text: String, into editor: NSTextView) {
        for character in text { editor.insertText(String(character), replacementRange: insertion) }
    }

    private func editor() async throws -> NSTextView {
        try await eventually { NSApp.keyWindow?.title == "Hana Search" && NSApp.keyWindow?.firstResponder is NSTextView }
        return try #require(NSApp.keyWindow?.firstResponder as? NSTextView)
    }

    private func logRows(_ fixture: JevWordPacedNativeFixture) throws -> [[String: Any]] {
        guard let text = try? String(contentsOf: fixture.log.url, encoding: .utf8) else { return [] }
        return try text.split(separator: "\n").map {
            try #require(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
    }

    /// A fake Jev whose requests ignore cancellation until a test finishes them.
    @MainActor private final class HeldJev: Classifier {
        private(set) var inputs: [String] = []
        private var pending: [CheckedContinuation<Void, Never>] = []
        func classify(_ text: String) async throws -> ClassifierVerdict {
            inputs.append(text)
            await withCheckedContinuation { pending.append($0) }
            try Task.checkCancellation()
            return ClassifierVerdict(label: .search, probabilities: [.search: 0.95])
        }
        func finishFirst() { if !pending.isEmpty { pending.removeFirst().resume() } }
        func finishAll() { while !pending.isEmpty { finishFirst() } }
    }

}
