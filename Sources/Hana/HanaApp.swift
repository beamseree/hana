import AppKit

@main
struct HanaApp {
    @MainActor static func main() {
        if CommandLine.arguments.dropFirst().first == CollectionFixtureHarness.flag {
            // Fixture-only harness: no AppKit, no live storage.
            Task.detached { exit(await CollectionFixtureHarness.run(Array(CommandLine.arguments.dropFirst(2)))) }
            dispatchMain()
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
private final class AppDelegate: NSObject, NSApplicationDelegate {
    private var interaction: MacInteraction?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let diagnostics = Diagnostics(enabled: CommandLine.arguments.contains("--diagnostics"))
        let validation = CommandLine.arguments.contains("--validate-search-correctness") ? SearchCorrectnessValidation() : nil
        let search = validation?.makeSearch() ?? Search(roots: ApplicationCatalog.conventionalRoots, indexedFiles: true,
                            fileDelay: CommandLine.arguments.contains("--validation-file-delay") ? .seconds(5) : .zero,
                            typingGap: validationTypingGap ?? Search.defaultTypingGap)
        let interaction = MacInteraction(diagnostics: diagnostics, search: search)
        self.interaction = interaction
        interaction.start()
        if CommandLine.arguments.contains("--validate-performance") {
            Task { await validatePerformance(interaction, diagnostics: diagnostics) }
            return
        }
        if CommandLine.arguments.contains("--validate-coverage") {
            Task { await validateCoverage(interaction, diagnostics: diagnostics) }
        }
        if let validation { Task { await validation.run(interaction, diagnostics: diagnostics) } }
        if CommandLine.arguments.contains("--validate-mixed-search") {
            Task { await validateMixedSearch(interaction, diagnostics: diagnostics) }
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        interaction?.open(.main)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { interaction?.stop() }
}

/// `--typing-gap-ms N` overrides the typing gap for performance validation.
@MainActor
var validationTypingGap: Duration? {
    let arguments = CommandLine.arguments
    guard let flag = arguments.firstIndex(of: "--typing-gap-ms"), flag + 1 < arguments.count,
          let milliseconds = Int(arguments[flag + 1]), milliseconds >= 0 else { return nil }
    return .milliseconds(milliseconds)
}
