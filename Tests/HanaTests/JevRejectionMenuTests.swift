import AppKit
import Testing
@testable import Hana

/// Menu-only evidence, with a policy-scripted 401 and an isolated Keychain item.
@MainActor
struct JevRejectionMenuTests {
    @Test func menuShowsRejectedKeyAndSavingANewKeyClearsTheStatus() throws {
        let identity = "com.beamseree.hana.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: identity))
        let keychain = JevKeychainStore(service: identity)
        defer { try? keychain.remove(); defaults.removePersistentDomain(forName: identity) }
        try keychain.save("menu-test-secret")
        let memory = JevLaunchMemory()
        let services = ClassifierServices(keychain: keychain, jevLaunchMemory: memory, availability: { .available })
        let store = AutomaticSwitchOptionsStore(defaults: defaults)
        var options = AutomaticSwitchOptions()
        options.isEnabled = true; options.classifier = .jev; options.firing = .wordPaced
        store.write(options)
        let menu = NSMenu()
        let classifierChoice = NSMenuItem(title: "Classifier", action: nil, keyEquivalent: "")
        classifierChoice.submenu = NSMenu()
        classifierChoice.submenu?.addItem(withTitle: "Jev", action: nil, keyEquivalent: "")
        menu.addItem(classifierChoice)
        let controller = ClassifierMenuController(menu: menu, services: services, options: store)
        var policy = AutomaticSwitch(options: options, memory: memory, now: { .zero })
        _ = policy.handle(.invoked)
        _ = policy.handle(.gateChanged(.init(decision: .allowed, settled: true, allSourcesSettled: true)))
        let effects = policy.handle(.bufferChanged(text: "call mom ", composing: false))
        let id = try #require(effects.compactMap { if case .classify(let id, _) = $0 { id } else { nil } }.first)
        _ = policy.handle(.failed(id: id, .authentication, latencyMilliseconds: 10))
        controller.refresh()
        let status = try #require(menu.item(withTitle: "Jev key rejected"))
        #expect(status.isEnabled == false)
        try services.saveJevKey("replacement-menu-secret")
        controller.refresh()
        #expect(menu.item(withTitle: "Jev key rejected") == nil)
        #expect(menu.item(withTitle: "Jev API key saved")?.isEnabled == false)
        #expect(!menu.items.map(\.title).joined().contains("menu-secret"))
        #expect(!String(describing: defaults.dictionaryRepresentation()).contains("menu-secret"))
    }
}
