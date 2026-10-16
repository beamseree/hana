import AppKit
import Testing
@testable import Hana

/// Requires the native testing slot; compiled with the suite but intentionally
/// left unrun until the user hands over that slot.
@Suite(.serialized, .nativeWindowSlot)
@MainActor
struct AutomaticSwitchDebugInteractionTests {
    @Test func menuToggleAppliesImmediatelyWithoutChangingThePolicyOrEditor() async throws {
        _ = NSApplication.shared
        let fixture = try Fixture(); defer { fixture.remove() }
        let apps = CatalogFeed()
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, typingGap: .zero),
            automaticSwitchOptions: fixture.options, automaticSwitchDiagnostics: fixture.log)
        let previousMenu = NSApp.mainMenu, previousWindowsMenu = NSApp.windowsMenu
        interaction.start()
        defer {
            interaction.stop()
            NSApp.mainMenu = previousMenu; NSApp.windowsMenu = previousWindowsMenu
        }
        _ = interaction.presentBar()
        let editor = try await editor()
        let menu = try #require(interaction.automaticSwitchMenu)
        let index = menu.indexOfItem(withTitle: "Debug mode")
        #expect(index >= 0 && interaction.debugFooterText == nil)
        let options = interaction.automaticSwitchSessionOptions
        let height = interaction.contentHeight
        let selection = editor.selectedRange()
        menu.performActionForItem(at: index)
        try await eventually { interaction.contentHeight > height + AutomaticSwitchDebugFooter.height - 1 }
        #expect(fixture.options.debugMode && menu.items[index].state == .on)
        #expect(interaction.debugFooterText?.contains("automatic switch off") == true)
        #expect(interaction.automaticSwitchSessionOptions == options)
        #expect(editor.selectedRange() == selection && editor.window?.firstResponder === editor)
        menu.performActionForItem(at: index)
        try await eventually { abs(interaction.contentHeight - height) < 1 }
        #expect(interaction.debugFooterText == nil && !fixture.options.debugMode)
    }

    @Test(arguments: [ClassifierVerdict.Label.note, .task])
    func footerRemainsVisibleWithTheCauseAcrossAutomaticCaptureAndEditing(label: ClassifierVerdict.Label) async throws {
        _ = NSApplication.shared
        let fixture = try Fixture(); defer { fixture.remove() }
        let storage = try TemporaryFixture(); let store = try await CollectionStore.open(storage.location)
        let fake = ScriptedClassifier(), apps = CatalogFeed()
        var options = fixture.options.read()
        options.isEnabled = true; options.classifier = .jev; options.firing = .wordPaced; options.wait = .none
        fixture.options.write(options); fixture.options.debugMode = true
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, typingGap: .zero),
            collection: Task { store }, automaticSwitchOptions: fixture.options,
            automaticSwitchDiagnostics: fixture.log, classifierFactory: { _ in fake })
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await editor()
        #expect(interaction.debugFooterText != nil)
        editor.insertText("call mom tomorrow ", replacementRange: NSRange(location: NSNotFound, length: 0))
        await apps.send([])
        try await eventually { fake.pendingCount == 1 }
        #expect(interaction.debugFooterText?.contains("#1") == true)
        fake.reply(label, probability: 0.95)
        try await eventually { interaction.mode == (label == .note ? .note : .task) }
        let cause = try #require(interaction.debugFooterText)
        #expect(cause.contains("95%") && cause.contains("switched"))
        editor.insertText("with more detail", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(interaction.debugFooterText == cause && editor.window?.firstResponder === editor)
        #expect(!interaction.resultsVisible)
        interaction.dismiss(invocation, reason: .outsideClick)
        _ = interaction.presentBar()
        #expect(interaction.debugFooterText?.contains("switched") == false)
        #expect(interaction.debugFooterText?.contains("sent 0") == true)
        if let current = interaction.currentInvocation { interaction.dismiss(current, reason: .outsideClick) }
        await store.close()
    }

    private func editor() async throws -> NSTextView {
        try await eventually { NSApp.keyWindow?.firstResponder is NSTextView }
        return try #require(NSApp.keyWindow?.firstResponder as? NSTextView)
    }

    @MainActor private struct Fixture {
        let name = "Hana.DebugNativeTests.\(UUID())"
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let defaults: UserDefaults
        let options: AutomaticSwitchOptionsStore
        let log: AutomaticSwitchDiagnostics
        init() throws {
            defaults = try #require(UserDefaults(suiteName: name))
            options = AutomaticSwitchOptionsStore(defaults: defaults)
            log = AutomaticSwitchDiagnostics(file: directory.appendingPathComponent("automatic-switch.jsonl"))
        }
        func remove() {
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: directory)
        }
    }
}
