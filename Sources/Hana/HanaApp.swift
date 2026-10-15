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
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var interaction: MacInteraction?
    /// The live collection. Only normal launch opens it, and only through the
    /// production location; validation runs and the fixture harness never do.
    private var collection: Task<CollectionStore, any Error>?
    private var termination: Task<Void, Never>?

    init(interaction: MacInteraction? = nil) {
        self.interaction = interaction
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--validate-note-window") {
            Task { await validateNoteWindow { self.interaction = $0 } }
            return
        }
        if CommandLine.arguments.contains("--validate-main-window") {
            Task { await validateMainWindow { self.interaction = $0 } }
            return
        }
        let diagnostics = Diagnostics(enabled: CommandLine.arguments.contains("--diagnostics"))
        let validation = CommandLine.arguments.contains("--validate-search-correctness") ? SearchCorrectnessValidation() : nil
        let search = validation?.makeSearch() ?? Search(roots: ApplicationCatalog.conventionalRoots, indexedFiles: true,
                            fileDelay: CommandLine.arguments.contains("--validation-file-delay") ? .seconds(5) : .zero,
                            typingGap: validationTypingGap ?? Search.defaultTypingGap)
        let validating = CommandLine.arguments.contains { $0.hasPrefix("--validate-") }
        // Opened off the main actor so the bar never waits for it. A failure
        // leaves Search working; capture explains it and keeps the text.
        let collection = validating ? nil : Task.detached(priority: .userInitiated) {
            try await CollectionStore.open(.live())
        }
        self.collection = collection
        let interaction = MacInteraction(diagnostics: diagnostics, search: search, collection: collection)
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

    /// Termination is acknowledged only after all note sessions flush and the
    /// collection closes. A failed flush cancels quit and presents its choices.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard interaction != nil || collection != nil else { return .terminateNow }
        guard termination == nil else { return .terminateLater }
        termination = Task {
            let allowed: Bool
            if let interaction {
                allowed = await interaction.prepareForQuit()
            } else {
                if let collection, let store = try? await collection.value { await store.close() }
                allowed = true
            }
            termination = nil
            sender.reply(toApplicationShouldTerminate: allowed)
        }
        return .terminateLater
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
