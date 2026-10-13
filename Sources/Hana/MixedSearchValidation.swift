import AppKit

/// Opt-in synthetic-fixture run through the production Mac Interaction boundary.
/// The normal launch path does not call this. It never changes privacy/indexing.
@MainActor
func validateMixedSearch(_ interaction: MacInteraction, diagnostics: Diagnostics) async {
    let fixture = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Hana Mixed Search Validation/TextEdit Hana [*] บันทึก.txt")
    guard FileManager.default.fileExists(atPath: fixture.path) else {
        diagnostics.record("validation.fixture-missing", state: [:])
        return
    }
    let invocation = interaction.presentBar()
    interaction.updateQuery("TextEdit")
    let deadline = ContinuousClock.now + .seconds(15)
    while ContinuousClock.now < deadline, interaction.currentInvocation == invocation {
        if let index = interaction.results.firstIndex(where: { $0.url == fixture }),
           interaction.results.contains(where: { $0.kind == .application }) {
            diagnostics.record("validation.mixed-discovery", state: ["fixtureFound": true, "applicationFound": true])
            // Choose the known synthetic destination through the same navigation
            // path as the editor. Never guess a row after a batch update.
            if let selected = interaction.selectedResult,
               let selectedIndex = interaction.results.firstIndex(where: { $0.id == selected.id }) {
                interaction.moveSelection(by: index - selectedIndex)
            } else {
                interaction.moveSelection(by: 1)
                interaction.moveSelection(by: index)
            }
            guard interaction.selectedResult?.url == fixture else { return }
            await interaction.requestSelectedOpen()?.value
            diagnostics.record("validation.open-returned", state: [
                "acknowledged": interaction.currentInvocation == nil && interaction.openFailure == nil
            ])
            return
        }
        try? await Task.sleep(for: .milliseconds(25))
    }
    diagnostics.record("validation.discovery-timeout", state: ["resultCount": interaction.results.count])
}
