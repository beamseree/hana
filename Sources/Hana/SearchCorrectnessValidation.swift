import AppKit

/// Opt-in #7 demonstration through Search and Mac Interaction. Controlled
/// sources change batches; destinations still use the real workspace adapters.
@MainActor
final class SearchCorrectnessValidation {
    private var apps: AsyncStream<SourceSnapshot>.Continuation?
    private var files: AsyncStream<SourceSnapshot>.Continuation?

    func makeSearch() -> Search {
        Search(source: { [self] in
            return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { apps = $0 }
        }, files: { [self] _ in
            return AsyncStream(bufferingPolicy: .bufferingNewest(1)) { files = $0 }
        })
    }

    func run(_ interaction: MacInteraction, diagnostics: Diagnostics) async {
        let fixture = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Hana Issue 7 Validation/Hana7 Note.txt")
        guard FileManager.default.fileExists(atPath: fixture.path) else {
            diagnostics.record("validation7.fixture-missing", state: [:]); return
        }
        let utility = SearchResult(name: "Hana7 Utility", url: URL(fileURLWithPath: "/System/Applications/Calculator.app"))
        let exact = SearchResult(name: "Hana7", url: utility.url)
        let file = SearchResult(name: fixture.lastPathComponent, url: fixture, kind: .file)
        let old = interaction.presentBar()
        interaction.updateQuery("Hana7")
        guard await wait({ self.apps != nil && self.files != nil }) else { return }
        apps?.yield(.init(results: [utility], status: .ready))
        files?.yield(.init(results: [file], status: .partial))
        guard await wait({ interaction.results.count == 2 }) else { return }
        interaction.moveSelection(by: 1)
        await pause()
        apps?.yield(.init(results: [exact], status: .ready))
        guard await wait({ interaction.results.first?.name == "Hana7" }) else { return }
        diagnostics.record("validation7.late-top", state: ["selectionPreserved": interaction.selectedResult?.id == file.id])
        await pause()
        files?.yield(.init(results: [], status: .failed))
        guard await wait({ interaction.results.count == 1 }) else { return }
        diagnostics.record("validation7.removal", state: ["requiresSelection": interaction.selectedResult == nil && interaction.requestSelectedOpen() == nil])
        await pause()
        let obsolete = files
        interaction.dismiss(old, reason: .escape)
        apps = nil; files = nil
        let fresh = interaction.presentBar()
        interaction.updateQuery("Hana7")
        guard await wait({ self.apps != nil && self.files != nil }) else { return }
        apps?.yield(.init(results: [exact], status: .ready))
        files?.yield(.init(results: [file], status: .ready))
        obsolete?.yield(.init(results: [], status: .failed))
        obsolete?.finish()
        guard await wait({ interaction.results.count == 2 }) else { return }
        diagnostics.record("validation7.reopened", state: ["freshSession": interaction.currentInvocation == fresh, "resultsRetained": interaction.results.count == 2])
        interaction.moveSelection(by: 1)
        await pause()
        await interaction.requestSelectedOpen()?.value
        diagnostics.record("validation7.real-file", state: ["acknowledged": interaction.currentInvocation == nil && interaction.openFailure == nil])
        await pause()
        apps?.finish(); files?.finish(); apps = nil; files = nil
        interaction.presentBar()
        interaction.updateQuery("Hana7")
        guard await wait({ self.apps != nil && self.files != nil }) else { return }
        apps?.yield(.init(results: [exact], status: .ready))
        files?.yield(.init(results: [], status: .ready))
        guard await wait({ interaction.selectedResult?.id == exact.id }) else { return }
        await pause()
        await interaction.requestSelectedOpen()?.value
        diagnostics.record("validation7.real-app", state: ["acknowledged": interaction.currentInvocation == nil && interaction.openFailure == nil])
        apps?.finish(); files?.finish()
        diagnostics.record("validation7.complete", state: ["controlledRunFinished": true])
    }

    private func wait(_ condition: () -> Bool) async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    private func pause() async { try? await Task.sleep(for: .seconds(2)) }
}
