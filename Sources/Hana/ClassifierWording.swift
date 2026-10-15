import Foundation

/// The single wording source for both adapters. Bump the closed diagnostics token when editing.
enum ClassifierWording {
    static let version = AutomaticSwitchDiagnostics.WordingVersion.v1
    static let instructions = "Classify what the person wants to do with this text in Hana."
    static let criteria = [
        "Search": "Find an app, file, or an existing note or task on this Mac",
        "Note": "Capture a thought or information as a new note",
        "Task": "Capture an action to do as a new task",
        "Other": "Unclear, incomplete, or none of the other options fits"
    ]
    static func foundationInstructions(unsure: Bool) -> String {
        instructions + "\n" + ["Search", "Note", "Task"].map { "\($0): \(criteria[$0]!)" }.joined(separator: "\n")
            + (unsure ? "\nunsure: \(criteria["Other"]!)" : "")
    }
}
