import AppKit
import Testing
@testable import Hana

@Suite(.serialized, .nativeWindowSlot)
@MainActor
struct ClassifierMenuTests {
    @Test func menuReflectsAvailabilityAndOnlyEnablesJevAfterKeySaved() throws {
        _ = NSApplication.shared
        let identity = "com.beamseree.hana.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: identity))
        let keychain = JevKeychainStore(service: identity)
        defer { try? keychain.remove(); defaults.removePersistentDomain(forName: identity) }
        let services = ClassifierServices(keychain: keychain, availability: { .appleIntelligenceOff })
        let options = AutomaticSwitchOptionsStore(defaults: defaults)
        let interaction = MacInteraction(automaticSwitchOptions: options, classifierServices: services)
        let previousMenu = NSApp.mainMenu, previousWindowsMenu = NSApp.windowsMenu
        interaction.start()
        defer { interaction.stop(); NSApp.mainMenu = previousMenu; NSApp.windowsMenu = previousWindowsMenu }
        let policy = NSApp.activationPolicy()
        let visibleWindows = NSApp.windows.filter(\.isVisible)
        let menu = try #require(interaction.automaticSwitchMenu)
        menu.delegate?.menuWillOpen?(menu)
        let choices = try #require(menu.item(withTitle: "Classifier")?.submenu)
        let firing = try #require(menu.item(withTitle: "Fires")?.submenu)
        let wordPacedTitle = "Word-paced"
        #expect(firing.item(withTitle: wordPacedTitle)?.isEnabled == false)
        #expect(choices.item(withTitle: "Jev")?.isEnabled == false)
        #expect(choices.item(withTitle: "Apple Intelligence is off")?.isEnabled == false)
        #expect(menu.item(withTitle: "No Jev API key saved") != nil)
        #expect(menu.item(withTitle: "Run Tricky-Input Check")?.isEnabled == false)
        #expect(menu.item(withTitle: "Set Jev API Key…")?.isEnabled == true)
        try services.saveJevKey("isolated-menu-secret")
        menu.delegate?.menuWillOpen?(menu)
        #expect(choices.item(withTitle: "Jev")?.isEnabled == true)
        #expect(menu.item(withTitle: "Jev API key saved") != nil)
        choices.performActionForItem(at: choices.indexOfItem(withTitle: "Jev"))
        #expect(options.read().classifier == .jev)
        #expect(choices.item(withTitle: "Jev")?.state == .on)
        #expect(choices.item(withTitle: "Foundation Models")?.state == .off)
        #expect(firing.item(withTitle: wordPacedTitle)?.isEnabled == true)
        firing.performActionForItem(at: firing.indexOfItem(withTitle: wordPacedTitle))
        #expect(options.read().firing == .wordPaced)
        #expect(firing.item(withTitle: wordPacedTitle)?.state == .on)
        #expect(menu.item(withTitle: "Run Tricky-Input Check")?.isEnabled == true)
        choices.performActionForItem(at: choices.indexOfItem(withTitle: "Foundation Models"))
        #expect(options.read().firing == .debounced)
        #expect(firing.item(withTitle: wordPacedTitle)?.isEnabled == false)
        choices.performActionForItem(at: choices.indexOfItem(withTitle: "Jev"))
        menu.performActionForItem(at: menu.indexOfItem(withTitle: "Remove Jev API Key"))
        #expect(try keychain.read() == nil)
        #expect(choices.item(withTitle: "Jev")?.isEnabled == false)
        #expect(menu.item(withTitle: "Run Tricky-Input Check")?.isEnabled == false)
        #expect(!menu.items.map(\.title).joined().contains("isolated-menu-secret"))
        #expect(NSApp.activationPolicy() == policy)
        #expect(NSApp.windows.filter(\.isVisible) == visibleWindows)
        #expect(interaction.window(for: .main) == nil)
    }
}
