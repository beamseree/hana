import Foundation

/// A value snapshot read for each new bar session. Changes during a session
/// deliberately apply to the next invocation, including the opt-in toggle.
struct AutomaticSwitchOptions: Codable, Equatable, Sendable {
    enum Classifier: String, Codable, CaseIterable, Sendable { case foundationModels, jev }
    enum Firing: String, Codable, CaseIterable, Sendable {
        case everyKeystroke, debounced, onPause, wordPaced
        /// Word-paced replaced the Jev pipeline trial option (#122); a stored pipeline choice migrates to it.
        init(from decoder: any Decoder) throws {
            let raw = try decoder.singleValueContainer().decode(String.self)
            guard let value = Firing(rawValue: raw == "pipelinedJev" ? Firing.wordPaced.rawValue : raw) else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                    debugDescription: "Unknown automatic switch firing strategy"))
            }
            self = value
        }
    }
    enum EnterBehavior: String, Codable, CaseIterable, Sendable { case saves, ignoreFor300Milliseconds }
    enum Wait: String, Codable, CaseIterable, Sendable { case allSources, appsAndCollection, none }
    enum LateStrongMatch: String, Codable, CaseIterable, Sendable { case returnToSearch, stay }
    enum Threshold: Double, Codable, CaseIterable, Sendable {
        case p50 = 0.50, p60 = 0.60, p70 = 0.70, p80 = 0.80, p90 = 0.90, p95 = 0.95
    }
    enum Agreement: Int, Codable, CaseIterable, Sendable { case one = 1, two = 2 }
    enum ReversalBehavior: String, Codable, CaseIterable, Sendable { case blockModeForText, stopUntilCleared }

    var isEnabled = false
    var classifier = Classifier.foundationModels
    var firing = Firing.debounced
    var jevThreshold = Threshold.p70
    var foundationModelsUnsure = true
    var agreeingVerdicts = Agreement.one
    var navigationSuspends = true
    var enterBehavior = EnterBehavior.ignoreFor300Milliseconds
    var reversalSuspends = true
    /// Word-paced only. The legacy flag still governs the other strategies.
    var reversalBehavior = ReversalBehavior.blockModeForText
    var wait = Wait.appsAndCollection
    var lateStrongMatch = LateStrongMatch.stay

    init() {}

    private enum CodingKeys: String, CodingKey {
        case isEnabled, classifier, firing, jevThreshold, foundationModelsUnsure, agreeingVerdicts
        case navigationSuspends, enterBehavior, reversalSuspends, reversalBehavior
        case wait, lateStrongMatch
    }

    /// Decode historical settings and JSONL options without losing the rest
    /// of the snapshot when Word-paced's reversal choice is introduced.
    /// Retired keys (`afterSwitch`, `escapeBehavior`) are ignored: an automatic
    /// switch always stays in its mode, and Escape right after it returns to Search.
    init(from decoder: any Decoder) throws {
        self.init()
        let values = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try values.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? isEnabled
        classifier = try values.decodeIfPresent(Classifier.self, forKey: .classifier) ?? classifier
        firing = try values.decodeIfPresent(Firing.self, forKey: .firing) ?? firing
        jevThreshold = try values.decodeIfPresent(Threshold.self, forKey: .jevThreshold) ?? jevThreshold
        foundationModelsUnsure = try values.decodeIfPresent(Bool.self, forKey: .foundationModelsUnsure) ?? foundationModelsUnsure
        agreeingVerdicts = try values.decodeIfPresent(Agreement.self, forKey: .agreeingVerdicts) ?? agreeingVerdicts
        navigationSuspends = try values.decodeIfPresent(Bool.self, forKey: .navigationSuspends) ?? navigationSuspends
        enterBehavior = try values.decodeIfPresent(EnterBehavior.self, forKey: .enterBehavior) ?? enterBehavior
        reversalSuspends = try values.decodeIfPresent(Bool.self, forKey: .reversalSuspends) ?? reversalSuspends
        reversalBehavior = try values.decodeIfPresent(ReversalBehavior.self, forKey: .reversalBehavior)
            ?? (reversalSuspends ? .stopUntilCleared : .blockModeForText)
        wait = try values.decodeIfPresent(Wait.self, forKey: .wait) ?? wait
        lateStrongMatch = try values.decodeIfPresent(LateStrongMatch.self, forKey: .lateStrongMatch) ?? lateStrongMatch
    }
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
