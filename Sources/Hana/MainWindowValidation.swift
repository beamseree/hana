import AppKit

/// Opt-in AppKit run-loop checks. Creates only a marked disposable collection,
/// never opens the live Store, and terminates only its own validation process.
@MainActor
func validateMainWindow(register: (MacInteraction) -> Void) async {
    let arguments = CommandLine.arguments
    guard let flag = arguments.firstIndex(of: "--main-window-report"), flag + 1 < arguments.count else {
        fputs("Hana: --validate-main-window requires --main-window-report PATH.\n", stderr)
        exit(2)
    }
    let report = URL(fileURLWithPath: arguments[flag + 1])
    let diagnostics = Diagnostics(file: report)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hana-main-window-\(UUID().uuidString)")
    var store: CollectionStore?
    var interaction: MacInteraction?
    do {
        let fixture = try CollectionLocation.createFixtureRoot(at: root)
        let openedStore = try await CollectionStore.open(fixture)
        store = openedStore
        let note = try await openedStore.perform(.createNote(operation: UUID(), body: "\nSaved fixture note\nBody"), in: openedStore.generation)
        let platform = MacInteraction(diagnostics: diagnostics, collection: Task { openedStore }, confirmationDuration: .zero)
        interaction = platform
        register(platform)
        platform.start()
        platform.open(.main)
        guard let window = platform.window(for: .main) else { throw MainWindowCheck.failed("main-window") }
        try await check("main-key") { NSApp.keyWindow === window }
        try await check("notes") { platform.mainWindowPresentation?.rows.map(\.id) == [note.id] }
        diagnostics.record("main-window.ready", state: ["key": window.isKeyWindow, "regular": NSApp.activationPolicy() == .regular])

        platform.open(.main, section: .today)
        guard platform.window(for: .main) === window, platform.mainWindowPresentation?.selectedSection == .today else {
            throw MainWindowCheck.failed("singleton-section")
        }
        platform.open(.main, section: .notes)
        let responder = window.firstResponder
        let invocation = platform.presentBar()
        try await check("bar-key") { NSApp.keyWindow is NSPanel && NSApp.keyWindow?.firstResponder is NSTextView }
        platform.dismiss(invocation, reason: .escape)
        try await check("escape-origin") { NSApp.keyWindow === window && window.firstResponder === responder }
        diagnostics.record("main-window.escape-restored", state: ["key": window.isKeyWindow, "responderRestored": window.firstResponder === responder])

        platform.presentBar()
        try await check("capture-editor") { NSApp.keyWindow?.firstResponder is NSTextView }
        guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { throw MainWindowCheck.failed("capture-editor") }
        let none = NSRange(location: NSNotFound, length: 0)
        editor.insertText("-", replacementRange: none)
        editor.insertText("Captured while the main window is open", replacementRange: none)
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        try await check("capture-committed") { platform.currentInvocation == nil && platform.mainWindowPresentation?.rows.count == 2 }
        try await check("save-origin") { NSApp.keyWindow === window && window.firstResponder === responder }
        diagnostics.record("main-window.capture-observed", state: ["rowCount": platform.mainWindowPresentation?.rows.count ?? 0, "key": window.isKeyWindow])

        // Optional pause for inspecting the actual native window, whose
        // sidebar uses system layers that a view bitmap does not capture.
        if arguments.contains("--preview-main-window") { try await Task.sleep(for: .seconds(45)) }
        window.miniaturize(nil)
        try await check("minimized") { window.isMiniaturized }
        guard NSApp.activationPolicy() == .regular else { throw MainWindowCheck.failed("minimized-policy") }
        _ = NSApp.delegate?.applicationShouldHandleReopen?(NSApp, hasVisibleWindows: false)
        try await check("dock-reopen") { !window.isMiniaturized && NSApp.keyWindow === window }
        guard platform.window(for: .main) === window else { throw MainWindowCheck.failed("dock-singleton") }
        diagnostics.record("main-window.dock-reopened", state: ["sameWindow": true, "regular": NSApp.activationPolicy() == .regular])
        window.close()
        guard platform.mainWindowPresentation == nil, NSApp.activationPolicy() == .accessory else {
            throw MainWindowCheck.failed("last-close-policy")
        }
        platform.stop()
        await openedStore.close()
        try FileManager.default.removeItem(at: root)
        diagnostics.record("main-window.validation-passed", state: [:])
        NSApp.terminate(nil)
    } catch {
        let step = (error as? MainWindowCheck)?.step ?? "fixture-storage"
        diagnostics.record("main-window.validation-failed", state: ["step": step])
        interaction?.stop()
        await store?.close()
        try? FileManager.default.removeItem(at: root)
        exit(1)
    }
}

private enum MainWindowCheck: Error {
    case failed(String)
    var step: String { switch self { case .failed(let step): step } }
}

@MainActor
private func check(_ step: String, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    guard condition() else { throw MainWindowCheck.failed(step) }
}
