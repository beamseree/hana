import AppKit

@main
struct HanaApp {
    @MainActor static func main() {
        if CommandLine.arguments.dropFirst().first == CollectionFixtureHarness.flag {
            // Fixture-only harness: no AppKit, no live storage.
            Task.detached { exit(await CollectionFixtureHarness.run(Array(CommandLine.arguments.dropFirst(2)))) }
            dispatchMain()
        }
        let fixtureOptions: WorkingWindowsOptions?
        do { fixtureOptions = try WorkingWindowsOptions.parse(Array(CommandLine.arguments.dropFirst())) }
        catch {
            fputs("Hana: invalid working-windows fixture arguments. Require one mode, absolute fixture root and report path.\n", stderr)
            exit(2)
        }
        if Bundle.main.bundleIdentifier == "com.beamseree.hana.validation.issue99", fixtureOptions == nil {
            fputs("Hana: isolated working-windows bundle requires explicit fixture arguments.\n", stderr)
            exit(2)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate(workingWindows: fixtureOptions)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var interaction: MacInteraction?
    /// Normal launch uses the production location; the explicit working-window
    /// fixture registers its marked Store here for the same orderly quit path.
    private var collection: Task<CollectionStore, any Error>?
    private var termination: Task<Void, Never>?
    private let workingWindows: WorkingWindowsOptions?
    private var fixtureDiagnostics: Diagnostics?

    init(interaction: MacInteraction? = nil, workingWindows: WorkingWindowsOptions? = nil) {
        self.interaction = interaction
        self.workingWindows = workingWindows
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let workingWindows {
            Task {
                await validateWorkingWindows(workingWindows) { collection, interaction, diagnostics in
                    self.collection = collection
                    self.interaction = interaction
                    self.fixtureDiagnostics = diagnostics
                }
            }
            return
        }
        if CommandLine.arguments.contains("--validate-open-note-capture") {
            Task { await validateOpenNoteCapture { self.interaction = $0 } }
            return
        }
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
            fixtureDiagnostics?.record("working-windows.quit-prepared", state: ["allowed": allowed])
            termination = nil
            sender.reply(toApplicationShouldTerminate: allowed)
        }
        return .terminateLater
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationWillTerminate(_ notification: Notification) {
        fixtureDiagnostics?.record("working-windows.will-terminate", state: [:])
        interaction?.stop()
    }
}

/// `--typing-gap-ms N` overrides the typing gap for performance validation.
@MainActor
var validationTypingGap: Duration? {
    let arguments = CommandLine.arguments
    guard let flag = arguments.firstIndex(of: "--typing-gap-ms"), flag + 1 < arguments.count,
          let milliseconds = Int(arguments[flag + 1]), milliseconds >= 0 else { return nil }
    return .milliseconds(milliseconds)
}
