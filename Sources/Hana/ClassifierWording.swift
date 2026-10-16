import Foundation

/// Shared wording, with a Jev-only choice-set trial. Version each adapter's
/// wording independently so diagnostics and cached answers identify the trial.
enum ClassifierWording {
    static let version = AutomaticSwitchDiagnostics.WordingVersion.v1
    static let jevVersion = AutomaticSwitchDiagnostics.WordingVersion.jevTaskFocusedV1
    static let instructions = "Classify what the person wants to do with this text in Hana."
    static let criteria = [
        "Search": "Find an app, file, or an existing note or task on this Mac",
        "Note": "Capture a thought or information as a new note",
        "Task": "Capture an action to do as a new task",
        "Other": "Unclear, incomplete, or none of the other options fits"
    ]
    static let jevCriteria: [String: String] = {
        var choices = criteria.filter { $0.key != "Note" }
        choices["Other"] = "Information, observations, ideas, incomplete or ambiguous text, or anything that is not clearly a search or a new task"
        return choices
    }()
    static func foundationInstructions(unsure: Bool) -> String {
        instructions + "\n" + ["Search", "Note", "Task"].map { "\($0): \(criteria[$0]!)" }.joined(separator: "\n")
            + (unsure ? "\nunsure: \(criteria["Other"]!)" : "")
    }
}
