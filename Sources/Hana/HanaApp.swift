import AppKit

@main
struct HanaApp {
    @MainActor static func main() {
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
        let search = Search(roots: ApplicationCatalog.conventionalRoots, indexedFiles: true,
                            fileDelay: CommandLine.arguments.contains("--validation-file-delay") ? .seconds(5) : .zero)
        let interaction = MacInteraction(diagnostics: diagnostics, search: search)
        self.interaction = interaction
        interaction.start()
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
