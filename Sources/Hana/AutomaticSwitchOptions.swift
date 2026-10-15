import Foundation

/// A value snapshot read for each new bar session. Changes during a session
/// deliberately apply to the next invocation, including the opt-in toggle.
struct AutomaticSwitchOptions: Codable, Equatable, Sendable {
    enum Classifier: String, Codable, CaseIterable, Sendable { case foundationModels, jev }
    enum Firing: String, Codable, CaseIterable, Sendable { case everyKeystroke, debounced, onPause, pipelinedJev }
    enum AfterSwitch: String, Codable, CaseIterable, Sendable { case stay, keepClassifying }
    enum EnterBehavior: String, Codable, CaseIterable, Sendable { case saves, ignoreFor300Milliseconds }
    enum EscapeBehavior: String, Codable, CaseIterable, Sendable { case returnsToSearch, dismisses }
    enum Wait: String, Codable, CaseIterable, Sendable { case allSources, appsAndCollection, none }
    enum LateStrongMatch: String, Codable, CaseIterable, Sendable { case returnToSearch, stay }
    enum Threshold: Double, Codable, CaseIterable, Sendable {
        case p50 = 0.50, p60 = 0.60, p70 = 0.70, p80 = 0.80, p90 = 0.90, p95 = 0.95
    }
    enum Agreement: Int, Codable, CaseIterable, Sendable { case one = 1, two = 2 }

    var isEnabled = false
    var classifier = Classifier.foundationModels
    var firing = Firing.debounced
    var jevThreshold = Threshold.p70
    var foundationModelsUnsure = true
    var agreeingVerdicts = Agreement.one
    var afterSwitch = AfterSwitch.stay
    var navigationSuspends = true
    var enterBehavior = EnterBehavior.ignoreFor300Milliseconds
    var escapeBehavior = EscapeBehavior.returnsToSearch
    var reversalSuspends = true
    var wait = Wait.appsAndCollection
    var lateStrongMatch = LateStrongMatch.stay
}

/// Stores one typed snapshot, never text or credentials.
final class AutomaticSwitchOptionsStore {
    private let defaults: UserDefaults
    private let key = "automaticSwitch.prototype.options.v1"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }
    func read() -> AutomaticSwitchOptions {
        guard let data = defaults.data(forKey: key),
              let value = try? JSONDecoder().decode(AutomaticSwitchOptions.self, from: data) else {
            return AutomaticSwitchOptions()
        }
        return value
    }
    func write(_ options: AutomaticSwitchOptions) {
        guard let data = try? JSONEncoder().encode(options) else { return }
        defaults.set(data, forKey: key)
    }
}
