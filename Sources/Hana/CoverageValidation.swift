import AppKit
import ApplicationServices

/// Explicit, synthetic-only validation in the installed app's own identity.
/// Uses production Search/Mac Interaction; does not import an index or grant access.
@MainActor
func validateCoverage(_ interaction: MacInteraction, diagnostics: Diagnostics) async {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let documents = home.appendingPathComponent("Documents/Hana9 Coverage")
    func record(_ id: String, _ state: [String: Any]) {
        diagnostics.record("coverage.\(id)", state: state)
    }
    record("context", ["bundle": Bundle.main.bundleIdentifier ?? "none",
                       "installedAtExpectedURL": Bundle.main.bundleURL == home.appendingPathComponent("Applications/Hana.app"),
                       "accessibilityTrusted": AXIsProcessTrusted(),
                       "os": ProcessInfo.processInfo.operatingSystemVersionString])

    // Read-only access probe to a fixed protected directory. No contents are read
    // or logged, and no TCC prompt/grant API is called. A numeric errno is evidence
    // only of this operation, not proof of Search coverage or a TCC root cause.
    let protected = home.appendingPathComponent("Library/Mail")
    let descriptor = Darwin.open(protected.path, O_RDONLY | O_DIRECTORY)
    let accessError = descriptor < 0 ? errno : 0
    if descriptor >= 0 { Darwin.close(descriptor) }
    record("protected-directory", ["openDirectorySucceeded": descriptor >= 0, "errno": accessError])

    struct Case {
        let id: String
        let query: String
        let url: URL
        var shouldOpen = true
        var excluded = false
    }
    var cases: [Case] = []
    for folder in ["Desktop", "Documents", "Downloads"] {
        let root = home.appendingPathComponent("\(folder)/Hana9 Coverage")
        cases.append(Case(id: folder.lowercased(), query: "Hana9 \(folder).txt", url: root.appendingPathComponent("Hana9 \(folder).txt")))
        cases.append(Case(id: "duplicate-\(folder.lowercased())", query: "Hana9 Duplicate", url: root.appendingPathComponent("Hana9 Duplicate.txt")))
        cases.append(Case(id: "folder-\(folder.lowercased())", query: "Hana9 \(folder) Folder", url: root.appendingPathComponent("Hana9 \(folder) Folder")))
    }
    cases += [
        Case(id: "uncommon", query: "Hana9 Ordinary", url: documents.appendingPathComponent("Hana9 Ordinary.uncommon")),
        Case(id: "extensionless", query: "Hana9 Extensionless", url: documents.appendingPathComponent("Hana9 Extensionless")),
        Case(id: "content-only", query: "Hana9ContentToken", url: documents.appendingPathComponent("Control.txt"), shouldOpen: false, excluded: true),
        Case(id: "path-only", query: "Hana9PathToken", url: documents.appendingPathComponent("Hana9PathToken/Neutral.txt"), shouldOpen: false, excluded: true),
        Case(id: "hidden", query: "Hana9 Hidden", url: documents.appendingPathComponent(".Hana9 Hidden.txt"), shouldOpen: false, excluded: true),
        Case(id: "temporary", query: "Hana9 Temporary", url: FileManager.default.temporaryDirectory.appendingPathComponent("Hana9 Coverage/Hana9 Temporary.txt"), shouldOpen: false)
    ]
    for installation in ["One", "Two"] {
        cases.append(Case(id: "app-\(installation.lowercased())", query: "Hana Search Fixture", url: home.appendingPathComponent("Applications/Hana Search Validation/\(installation)/Hana Search Fixture.app")))
    }
    cases.append(Case(id: "rename", query: "Hana9 Rename Before", url: documents.appendingPathComponent("Hana9 Rename Before.txt")))
    cases.append(Case(id: "renamed", query: "Hana9 Rename After", url: documents.appendingPathComponent("Hana9 Rename After.txt")))
    cases.append(Case(id: "delete", query: "Hana9 Delete", url: documents.appendingPathComponent("Hana9 Delete.txt")))

    for item in cases {
        var probe: [String: Any] = ["phase": "resource", "eligible": Search.eligible(item.url),
                                     "visible": SpotlightSource.visibleDestination(item.url),
                                     "metadataNameAvailable": NSMetadataItem(url: item.url)?.value(forAttribute: NSMetadataItemFSNameKey) != nil]
        do {
            _ = try FileManager.default.attributesOfItem(atPath: item.url.path)
            probe["attributesReadable"] = true
        } catch {
            probe["attributesReadable"] = false
            probe["errorDomain"] = (error as NSError).domain
            probe["errorCode"] = (error as NSError).code
        }
        record(item.id, probe)
        let invocation = interaction.presentBar()
        interaction.updateQuery(item.query)
        let deadline = ContinuousClock.now + .seconds(item.excluded ? 4 : 12)
        while ContinuousClock.now < deadline {
            if !item.excluded, interaction.results.contains(where: { $0.url.standardizedFileURL == item.url.standardizedFileURL }) { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        guard interaction.currentInvocation == invocation, interaction.query == item.query else {
            record(item.id, ["interrupted": true])
            if interaction.currentInvocation == invocation { interaction.dismiss(invocation, reason: .escape) }
            record("complete", ["finished": false])
            return
        }
        let index = interaction.results.firstIndex { $0.url.standardizedFileURL == item.url.standardizedFileURL }
        record(item.id, ["phase": "discovery", "found": index != nil,
                         "expectedExcluded": item.excluded, "resultCount": interaction.results.count])
        if let index, item.shouldOpen {
            if let selected = interaction.selectedResult,
               let current = interaction.results.firstIndex(where: { $0.id == selected.id }) {
                interaction.moveSelection(by: index - current)
            } else {
                interaction.moveSelection(by: 1)
                interaction.moveSelection(by: index)
            }
            guard interaction.selectedResult?.url.standardizedFileURL == item.url.standardizedFileURL else {
                record(item.id, ["selectionFailed": true]); continue
            }
            // Mutate only the exact owned fixture after selecting it. Enter then
            // exercises real stale-destination validation, before an index update.
            if item.id == "rename" || item.id == "delete" {
                do {
                    let marker = try String(contentsOf: item.url, encoding: .utf8)
                    guard marker == (item.id == "rename" ? "HANA9-RENAMED\n" : "HANA9-DELETED\n") else {
                        record(item.id, ["fixtureModified": true]); continue
                    }
                    if item.id == "rename" {
                        try FileManager.default.moveItem(at: item.url, to: documents.appendingPathComponent("Hana9 Rename After.txt"))
                    } else { try FileManager.default.removeItem(at: item.url) }
                } catch {
                    record(item.id, ["mutationFailed": true]); continue
                }
            }
            let selectedExact = interaction.selectedResult?.url.standardizedFileURL == item.url.standardizedFileURL
            let operation = interaction.requestSelectedOpen()
            await operation?.value
            record(item.id, ["phase": "opening", "selectedExact": selectedExact, "attempted": operation != nil,
                             "acknowledged": interaction.currentInvocation == nil && interaction.openFailure == nil,
                             "failed": interaction.openFailure != nil,
                             "contextRetained": interaction.currentInvocation == invocation && interaction.query == item.query])
            try? await Task.sleep(for: .seconds(1))
        }
        if interaction.currentInvocation == invocation { interaction.dismiss(invocation, reason: .escape) }
    }
    record("complete", ["finished": true])
}
