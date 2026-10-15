import AppKit
import Testing
@testable import Hana

@Suite(.serialized, .nativeWindowSlot)
@MainActor
struct AutomaticSwitchInteractionTests {
    @Test func submenuPersistsToggleAndResetsCountsWithoutOpeningWorkingWindowsOrChangingPolicy() throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        defer { fixture.remove() }
        let interaction = MacInteraction(automaticSwitchOptions: fixture.options, automaticSwitchDiagnostics: fixture.log)
        let previousMenu = NSApp.mainMenu, previousWindowsMenu = NSApp.windowsMenu
        interaction.start()
        defer {
            interaction.stop()
            NSApp.mainMenu = previousMenu; NSApp.windowsMenu = previousWindowsMenu
        }
        let policy = NSApp.activationPolicy()
        let windows = NSApp.windows.filter { $0.isVisible }
        let menu = try #require(interaction.menuBarMenu)
        let submenuIndex = menu.indexOfItem(withTitle: "Automatic switch (prototype)")
        #expect(submenuIndex > menu.indexOfItem(withTitle: "Open Hana"))
        #expect(submenuIndex < menu.indexOfItem(withTitle: "Quit Hana"))
        let submenu = try #require(menu.items[submenuIndex].submenu)
        submenu.delegate?.menuWillOpen?(submenu)
        let toggle = try #require(submenu.item(withTitle: "On"))
        #expect(toggle.state == .off)
        #expect(submenu.item(withTitle: "Switches 0 · Wrong 0 · Ambiguous 0")?.isEnabled == false)
        submenu.performActionForItem(at: submenu.indexOfItem(withTitle: "On"))
        #expect(fixture.options.read().isEnabled && toggle.state == .on)
        fixture.log.record(.switched(mode: .note), options: fixture.options.read())
        submenu.delegate?.menuWillOpen?(submenu)
        #expect(submenu.item(withTitle: "Switches 1 · Wrong 0 · Ambiguous 0") != nil)
        submenu.performActionForItem(at: submenu.indexOfItem(withTitle: "Reset Counts"))
        #expect(fixture.log.counts().switches == 0)
        #expect(NSApp.activationPolicy() == policy)
        #expect(NSApp.windows.filter { $0.isVisible } == windows)
        #expect(interaction.window(for: .main) == nil && interaction.currentInvocation == nil)
    }

    @Test(arguments: [true, false], [CaptureSession.Suggestion.note, .task])
    func prefixAndSuggestionKeepTheirBehaviorAndRecordMissedOnlyWhenEnabled(enabled: Bool, suggestion: CaptureSession.Suggestion) async throws {
        _ = NSApplication.shared
        let fixture = try Fixture()
        defer { fixture.remove() }
        var options = fixture.options.read(); options.isEnabled = enabled; fixture.options.write(options)
        let apps = CatalogFeed()
        let interaction = MacInteraction(search: Search(source: { apps.stream() }, typingGap: .zero),
            automaticSwitchOptions: fixture.options, automaticSwitchDiagnostics: fixture.log)
        var invocation = interaction.presentBar()
        defer { if let current = interaction.currentInvocation { interaction.dismiss(current, reason: .outsideClick) } }
        let editor = try await editor()
        editor.insertText("private search บ้าน", replacementRange: NSRange(location: NSNotFound, length: 0))
        editor.setSelectedRange(NSRange(location: 0, length: 0))
        editor.insertText(suggestion == .note ? "-" : "[", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(interaction.mode == suggestion.mode && editor.string == "private search บ้าน")
        #expect(fixture.log.counts().missed == (enabled ? 1 : 0))
        interaction.dismiss(invocation, reason: .outsideClick)
        invocation = interaction.presentBar()
        editor.insertText("another private search", replacementRange: NSRange(location: NSNotFound, length: 0))
        await apps.send([])
        try await eventually { !interaction.isLoading }
        if suggestion == .task { interaction.moveSelection(by: 1) }
        interaction.requestSelectedOpen()
        #expect(interaction.mode == suggestion.mode && editor.string == "another private search")
        #expect(fixture.log.counts().missed == (enabled ? 2 : 0))
        if enabled {
            let data = try String(contentsOf: fixture.log.url, encoding: .utf8)
            #expect(!data.contains("private search"))
        } else { #expect(!FileManager.default.fileExists(atPath: fixture.log.url.path)) }
    }

    private func editor() async throws -> NSTextView {
        try await eventually { NSApp.keyWindow?.firstResponder is NSTextView }
        return try #require(NSApp.keyWindow?.firstResponder as? NSTextView)
    }

    @MainActor private struct Fixture {
        let name = "Hana.AutomaticSwitchNativeTests.\(UUID())"
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
