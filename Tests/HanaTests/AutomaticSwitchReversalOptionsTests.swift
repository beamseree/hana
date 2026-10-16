import Foundation
import Testing
@testable import Hana

struct AutomaticSwitchReversalOptionsTests {
    @Test(arguments: [true, false])
    func legacyReversalChoicesMigrateWithoutResettingTheSnapshot(suspends: Bool) throws {
        var old = AutomaticSwitchOptions()
        old.isEnabled = true; old.classifier = .jev; old.firing = .wordPaced
        old.jevThreshold = .p95; old.foundationModelsUnsure = false; old.agreeingVerdicts = .two
        old.navigationSuspends = false; old.enterBehavior = .saves
        old.reversalSuspends = suspends; old.wait = .allSources
        old.lateStrongMatch = .returnToSearch
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json["reversalBehavior"] = nil
        json["firing"] = "pipelinedJev"
        // Retired options in an older snapshot are ignored, not a reason to reset it.
        json["afterSwitch"] = "keepClassifying"; json["escapeBehavior"] = "dismisses"
        let name = "Hana.ReversalMigration.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(try JSONSerialization.data(withJSONObject: json), forKey: "automaticSwitch.prototype.options.v1")
        let store = AutomaticSwitchOptionsStore(defaults: defaults)
        var expected = old
        expected.reversalBehavior = suspends ? .stopUntilCleared : .blockModeForText
        #expect(store.read() == expected)
        store.write(store.read())
        #expect(AutomaticSwitchOptionsStore(defaults: defaults).read() == expected)
    }

    @Test func freshWordPacedUsesModeBlocking() {
        #expect(AutomaticSwitchOptions().reversalBehavior == .blockModeForText)
    }
}
