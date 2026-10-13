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
        let interaction = MacInteraction(diagnostics: diagnostics)
        self.interaction = interaction
        interaction.start()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        interaction?.open(.main)
        return false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) { interaction?.stop() }
}
