import AppKit
import Testing
@testable import Hana

@Suite(.serialized, .nativeWindowSlot, .timeLimit(.minutes(1)))
@MainActor
struct JevWordPacedWithdrawalNativeTests {
    private let insertion = NSRange(location: NSNotFound, length: 0)

    @Test func withdrawalKeepsTheCurrentTextAndUTF16SelectionAndRetypingUsesCache() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture(); defer { fixture.remove() }
        let storage = try TemporaryFixture()
        let store = try await CollectionStore.open(storage.location)
        let fake = ScriptedClassifier()
        let interaction = fixture.interaction(store: store, classifier: fake)
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await editor()
        type("call mom ", into: editor)
        try await eventually { fake.inputs == ["call mom"] }
        editor.insertText("tomorrow บ้าน🙂", replacementRange: insertion)
        fake.reply(.task, probability: 0.95)
        try await eventually { interaction.mode == .task }
        editor.setSelectedRange(NSRange(location: 7, length: (editor.string as NSString).length - 7))
        editor.keyDown(with: try backspaceKey())
        #expect(interaction.mode == .task && editor.string == "call mo")
        #expect(editor.selectedRange() == NSRange(location: 7, length: 0))
        try await eventually { interaction.mode == .search }
        #expect(editor.string == "call mo" && editor.selectedRange() == NSRange(location: 7, length: 0))
        #expect(fixture.log.counts().withdrawn == 1 && fixture.log.counts().wrongSwitches == 0)
        editor.insertText("m ", replacementRange: insertion)
        #expect(interaction.mode == .task && editor.string == "call mom ")
        #expect(fake.inputs.count == 1)
        await store.close()
    }

    @Test func editingInTheMiddleNeverWithdrawsEvenWhenTheResultIsAStrictPrefix() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture(); defer { fixture.remove() }
        let storage = try TemporaryFixture()
        let store = try await CollectionStore.open(storage.location)
        let fake = ScriptedClassifier()
        let interaction = fixture.interaction(store: store, classifier: fake)
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await editor()
        editor.insertText("call mom mom ", replacementRange: insertion)
        try await eventually { fake.inputs == ["call mom mom"] }
        fake.reply(.task, probability: 0.95)
        try await eventually { interaction.mode == .task }
        // Remove the first repeated word, without touching the end.
        editor.setSelectedRange(NSRange(location: 5, length: 4))
        editor.keyDown(with: try backspaceKey())
        #expect(editor.string == "call mom " && editor.selectedRange() == NSRange(location: 5, length: 0))
        try await Task.sleep(for: .milliseconds(220))
        #expect(interaction.mode == .task && fixture.log.counts().withdrawn == 0)
        #expect(editor.selectedRange() == NSRange(location: 5, length: 0))
        await store.close()
    }

    @Test func backspaceAtTheStartPreservesTextAndVetoesOnlyTheRejectedMode() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture(); defer { fixture.remove() }
        let storage = try TemporaryFixture()
        let store = try await CollectionStore.open(storage.location)
        let fake = ScriptedClassifier()
        let interaction = fixture.interaction(store: store, classifier: fake)
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await editor()
        type("call mom ", into: editor)
        try await eventually { fake.inputs == ["call mom"] }
        fake.reply(.task, probability: 0.95)
        try await eventually { interaction.mode == .task }
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.keyDown(with: try backspaceKey())
        #expect(interaction.mode == .search && editor.string == "call mom ")
        #expect(editor.selectedRange() == NSRange(location: 0, length: 0))
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.insertText("tomorrow ", replacementRange: insertion)
        try await eventually { fake.inputs.count == 2 }
        fake.reply(.task, probability: 0.95)
        try await Task.sleep(for: .milliseconds(30))
        #expect(interaction.mode == .search)
        editor.insertText("at ", replacementRange: insertion)
        try await eventually { fake.inputs.count == 3 }
        fake.reply(.note, probability: 0.95)
        try await eventually { interaction.mode == .note }
        #expect(editor.string == "call mom tomorrow at ")
        #expect(fixture.log.counts().reversals == 1 && fixture.log.counts().wrongSwitches == 1)
        await store.close()
    }

    @Test(arguments: [AutomaticSwitchOptions.EscapeBehavior.returnsToSearch, .dismisses])
    func escapeFollowsItsConfiguredOption(option: AutomaticSwitchOptions.EscapeBehavior) async throws {
        _ = NSApplication.shared
        let fixture = try Fixture(); defer { fixture.remove() }
        var options = fixture.options.read(); options.escapeBehavior = option; fixture.options.write(options)
        let storage = try TemporaryFixture()
        let store = try await CollectionStore.open(storage.location)
        let fake = ScriptedClassifier()
        let interaction = fixture.interaction(store: store, classifier: fake)
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await editor()
        type("call mom ", into: editor)
        try await eventually { fake.inputs == ["call mom"] }
        fake.reply(.task, probability: 0.95)
        try await eventually { interaction.mode == .task }
        editor.setSelectedRange(NSRange(location: 2, length: 3))
        editor.keyDown(with: try escapeKey())
        if option == .returnsToSearch {
            #expect(interaction.mode == .search && interaction.currentInvocation == invocation)
            #expect(editor.string == "call mom " && editor.selectedRange() == NSRange(location: 2, length: 3))
            #expect(fixture.log.counts().reversals == 1)
        } else {
            #expect(interaction.currentInvocation == nil && fixture.log.counts().reversals == 0)
        }
        await store.close()
    }

    @Test func enterJustAfterDeletingSavesTheShownTaskExactlyOnce() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture(); defer { fixture.remove() }
        let storage = try TemporaryFixture()
        let store = try await CollectionStore.open(storage.location)
        let fake = ScriptedClassifier()
        let interaction = fixture.interaction(store: store, classifier: fake)
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await editor()
        type("call mom ", into: editor)
        try await eventually { fake.inputs == ["call mom"] }
        fake.reply(.task, probability: 0.95)
        try await eventually { interaction.mode == .task }
        editor.setSelectedRange(NSRange(location: 7, length: (editor.string as NSString).length - 7))
        editor.keyDown(with: try backspaceKey())
        #expect(interaction.mode == .task && editor.string == "call mo")
        editor.keyDown(with: try returnKey())
        editor.keyDown(with: try returnKey())
        try await eventually { interaction.currentInvocation == nil }
        let records = try await store.read(.allRecords, in: store.generation)
        #expect(records.notes.isEmpty && records.tasks.map(\.title) == ["call mo"])
        #expect(fixture.log.counts().withdrawn == 0 && fixture.log.counts().wrongSwitches == 0)
        await store.close()
    }

    @Test func submenuShowsMigratedReversalChoiceAndSeparateWithdrawnCount() throws {
        _ = NSApplication.shared
        let fixture = try Fixture(); defer { fixture.remove() }
        var options = fixture.options.read(); options.reversalSuspends = true
        var old = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(options)) as? [String: Any])
        old["reversalBehavior"] = nil
        fixture.defaults.set(try JSONSerialization.data(withJSONObject: old), forKey: "automaticSwitch.prototype.options.v1")
        let interaction = MacInteraction(automaticSwitchOptions: fixture.options, automaticSwitchDiagnostics: fixture.log)
        let previousMenu = NSApp.mainMenu, previousWindows = NSApp.windowsMenu
        interaction.start()
        defer { interaction.stop(); NSApp.mainMenu = previousMenu; NSApp.windowsMenu = previousWindows }
        let menu = try #require(interaction.automaticSwitchMenu)
        menu.delegate?.menuWillOpen?(menu)
        let reversal = try #require(menu.item(withTitle: "After reversing a switch"))
        #expect(!reversal.isHidden && menu.item(withTitle: "Reversing stops switching")?.isHidden == true)
        let choices = try #require(reversal.submenu)
        #expect(choices.items.map(\.title) == ["Block that mode for this text", "Stop until the bar is cleared"])
        #expect(choices.item(withTitle: "Stop until the bar is cleared")?.state == .on)
        choices.performActionForItem(at: 0)
        #expect(fixture.options.read().reversalBehavior == .blockModeForText)
        fixture.log.record(.switched(mode: .task), options: options)
        fixture.log.record(.withdrawn(mode: .task), options: options)
        fixture.log.record(.ended(.withdrawn), options: options)
        fixture.log.record(.switched(mode: .note), options: options)
        fixture.log.record(.reversed(method: .backspace, millisecondsSinceSwitch: 100), options: options)
        menu.delegate?.menuWillOpen?(menu)
        #expect(menu.items.contains { $0.title.contains("Wrong 1") })
        #expect(menu.items.contains { $0.title.contains("Reversals 1") && $0.title.contains("Withdrawn 1") })
        let firing = try #require(menu.item(withTitle: "Fires")?.submenu)
        firing.performActionForItem(at: firing.indexOfItem(withTitle: "Debounced (150 ms)"))
        #expect(reversal.isHidden && menu.item(withTitle: "Reversing stops switching")?.isHidden == false)
        #expect(fixture.options.read().reversalSuspends)
    }

    private func type(_ text: String, into editor: NSTextView) {
        for character in text { editor.insertText(String(character), replacementRange: insertion) }
    }
    private func editor() async throws -> NSTextView {
        try await eventually { NSApp.keyWindow?.title == "Hana Search" && NSApp.keyWindow?.firstResponder is NSTextView }
        return try #require(NSApp.keyWindow?.firstResponder as? NSTextView)
    }

    @MainActor private struct Fixture {
        let name = "Hana.JevWordPacedWithdrawalNativeTests.\(UUID())"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults: UserDefaults
        let options: AutomaticSwitchOptionsStore
        let log: AutomaticSwitchDiagnostics
        init() throws {
            defaults = try #require(UserDefaults(suiteName: name))
            options = AutomaticSwitchOptionsStore(defaults: defaults)
            var value = AutomaticSwitchOptions()
            value.isEnabled = true; value.classifier = .jev; value.firing = .wordPaced
            value.afterSwitch = .stay; value.wait = .none; value.enterBehavior = .saves
            options.write(value)
            log = AutomaticSwitchDiagnostics(file: directory.appendingPathComponent("automatic-switch.jsonl"))
        }
        func interaction(store: CollectionStore, classifier: any Classifier) -> MacInteraction {
            MacInteraction(search: Search(source: { AsyncStream {
                $0.yield(.init(results: [], status: .ready)); $0.finish()
            } }, typingGap: .zero), collection: Task { store }, confirmationDuration: .zero,
                automaticSwitchOptions: options, automaticSwitchDiagnostics: log,
                classifierFactory: { _ in classifier }, jevLaunchMemory: JevLaunchMemory())
        }
        func remove() {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
