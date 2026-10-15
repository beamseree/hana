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

        guard let viewMenu = NSApp.mainMenu?.item(withTitle: "View")?.submenu,
              let noteMenu = NSApp.mainMenu?.item(withTitle: "Note")?.submenu else { throw MainWindowCheck.failed("review-menus") }
        for section in MainSection.allCases {
            viewMenu.performActionForItem(at: viewMenu.indexOfItem(withTitle: "Show " + section.rawValue))
            try await check("menu-section") { platform.mainWindowPresentation?.selectedSection == section }
        }
        viewMenu.performActionForItem(at: viewMenu.indexOfItem(withTitle: "Show Notes"))
        platform.selectMainNote(note.id)
        try workspaceShortcut(code: 31, modifiers: [.command])
        try await check("menu-note-open") { NSApp.keyWindow === platform.window(for: .note(note.id)) }
        guard let pin = noteMenu.item(withTitle: "Pin Note"), !platform.validateMenuItem(pin) else { throw MainWindowCheck.failed("background-note-command") }
        noteMenu.performActionForItem(at: noteMenu.index(of: pin))
        try workspaceShortcut(code: 35, modifiers: [.command, .option])
        try await check("menu-preview") { platform.notePreview(note.id)?.isVisible == true }
        platform.open(.main)
        try await check("preview-background-main-key") { NSApp.keyWindow === window }
        viewMenu.performActionForItem(at: viewMenu.indexOfItem(withTitle: "Markdown Preview"))
        guard platform.notePreview(note.id)?.isVisible == true,
              try await openedStore.read(.note(note.id), in: openedStore.generation)?.isPinned == false else { throw MainWindowCheck.failed("scoped-preview") }
        platform.open(.note(note.id))
        try await check("preview-note-key") { NSApp.keyWindow === platform.window(for: .note(note.id)) }
        try workspaceShortcut(code: 35, modifiers: [.command, .option])
        try await check("menu-source") { platform.notePreview(note.id)?.isVisible == false }
        platform.open(.main)
        try await check("pin-main-key") { NSApp.keyWindow === window }
        guard platform.validateMenuItem(pin) else { throw MainWindowCheck.failed("main-note-menu-enabled") }
        try workspaceShortcut(code: 35, modifiers: [.command, .control])
        try await check("menu-pin") { platform.mainWindowPresentation?.rows.first(where: { $0.id == note.id })?.isPinned == true }
        guard platform.validateMenuItem(pin), pin.title == "Unpin Note" else { throw MainWindowCheck.failed("menu-unpin-title") }
        try workspaceShortcut(code: 35, modifiers: [.command, .control])
        try await check("menu-unpin") { platform.mainWindowPresentation?.rows.first(where: { $0.id == note.id })?.isPinned == false }
        diagnostics.record("main-window.review-menus", state: ["allSections": true, "noteOpenShortcut": true, "previewShortcut": true, "backgroundSelectionKept": true, "scopedPreview": true])

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

        let task = try await openedStore.perform(.createTask(operation: UUID(), title: "Completed fixture", placement: .today), in: openedStore.generation)
        _ = try await openedStore.perform(.completeTask(task.id, expectedRevision: 1), in: openedStore.generation)
        platform.open(.main, section: .completed)
        try await check("completed-list") { platform.taskWorkspacePresentation?.completed.first?.id == task.id }
        platform.selectTask(task.id)
        try workspaceShortcut(code: 31, modifiers: [.command, .shift])
        try await check("keyboard-reopen") { platform.taskWorkspacePresentation?.inbox.first?.id == task.id && platform.taskWorkspacePresentation?.isPerforming == false }
        platform.open(.main, section: .inbox)
        platform.selectTask(task.id)
        try workspaceShortcut(code: 0, modifiers: [.command, .shift])
        try await check("keyboard-task-archive") { platform.taskWorkspacePresentation?.inbox.contains { $0.id == task.id } == false && platform.taskWorkspacePresentation?.isPerforming == false }
        platform.open(.main, section: .notes)
        platform.selectMainNote(note.id)
        try workspaceShortcut(code: 0, modifiers: [.command, .control])
        try await check("menu-note-archive") { platform.noteSession(note.id)?.committed.archivedAt != nil }
        platform.open(.main, section: .archive)
        try await check("mixed-archive") { platform.archiveWorkspacePresentation?.rows.count == 2 }
        platform.selectArchived(.task(task.id))
        try workspaceShortcut(code: 15, modifiers: [.command, .shift])
        try await check("archive-task-restored") { platform.archiveWorkspacePresentation?.rows.count == 1 && platform.taskWorkspacePresentation?.inbox.first?.id == task.id }
        platform.selectArchived(.note(note.id))
        try workspaceShortcut(code: 36, modifiers: [])
        try await check("archived-note-key") { NSApp.keyWindow === platform.window(for: .note(note.id)) }
        guard let noteEditor = platform.window(for: .note(note.id))?.firstResponder as? NSTextView,
              !noteEditor.isEditable else { throw MainWindowCheck.failed("archived-note-read-only") }
        platform.open(.main, section: .archive)
        platform.selectArchived(.note(note.id))
        try workspaceShortcut(code: 15, modifiers: [.command, .shift])
        try await check("archive-note-restored") { noteEditor.isEditable && platform.archiveWorkspacePresentation?.rows.isEmpty == true }
        platform.window(for: .note(note.id))?.close()
        platform.open(.main, section: .inbox)
        platform.selectTask(task.id)
        guard await platform.performTaskAction(.rename) else { throw MainWindowCheck.failed("rename-for-close") }
        platform.editTaskTitle("  ")
        window.performClose(nil)
        try await check("invalid-close-retained") { !platform.mainCloseIsHeld && platform.taskWorkspacePresentation?.notice != nil }
        guard platform.window(for: .main) === window, window.isVisible,
              platform.mainWindowPresentation?.selectedSection == .inbox else { throw MainWindowCheck.failed("invalid-close-visible") }
        platform.editTaskTitle("Renamed before navigation")
        platform.open(.main, section: .notes)
        try await check("rename-before-navigation") { platform.mainWindowPresentation?.selectedSection == .notes && platform.taskWorkspacePresentation?.editing == nil }
        diagnostics.record("main-window.organization", state: ["keyboardReopen": true, "mixedArchive": true, "keyboardRestore": true, "archivedNoteOpen": true, "readOnly": true, "invalidCloseRetained": true, "renameBeforeNavigation": true])

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
        platform.open(.main, section: .inbox)
        platform.selectTask(task.id)
        guard await platform.performTaskAction(.rename) else { throw MainWindowCheck.failed("rename-final-close") }
        platform.editTaskTitle("Saved before main close")
        window.performClose(nil)
        try await check("last-close-policy") { platform.mainWindowPresentation == nil && NSApp.activationPolicy() == .accessory }
        guard try await openedStore.read(.task(task.id), in: openedStore.generation)?.title == "Saved before main close" else { throw MainWindowCheck.failed("main-close-title") }
        platform.stop()
        await openedStore.close()
        try FileManager.default.removeItem(at: root)
        diagnostics.record("main-window.validation-passed", state: [:])
        RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { NSApp.terminate(nil) } }
    } catch {
        let step = (error as? MainWindowCheck)?.step ?? "fixture-storage"
        var state: [String: Any] = ["step": step, "archiveRows": interaction?.archiveWorkspacePresentation?.rows.count ?? -1,
                                    "taskBusy": interaction?.taskWorkspacePresentation?.isPerforming ?? false,
                                    "inboxRows": interaction?.taskWorkspacePresentation?.inbox.count ?? -1]
        if let store {
            state["storedArchivedNotes"] = try? await store.read(.archivedNotes, in: store.generation).count
            state["storedArchivedTasks"] = try? await store.read(.archivedTasks, in: store.generation).count
        }
        diagnostics.record("main-window.validation-failed", state: state)
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

@MainActor
private func workspaceShortcut(code: UInt16, modifiers: NSEvent.ModifierFlags) throws {
    guard let source = CGEventSource(stateID: .privateState),
          let keyboard = CGEvent(keyboardEventSource: source, virtualKey: code, keyDown: true) else { throw MainWindowCheck.failed("organization-event") }
    var flags: CGEventFlags = []
    if modifiers.contains(.command) { flags.insert(.maskCommand) }
    if modifiers.contains(.shift) { flags.insert(.maskShift) }
    if modifiers.contains(.control) { flags.insert(.maskControl) }
    if modifiers.contains(.option) { flags.insert(.maskAlternate) }
    keyboard.flags = flags
    guard let event = NSEvent(cgEvent: keyboard) else { throw MainWindowCheck.failed("organization-event") }
    guard NSApp.mainMenu?.performKeyEquivalent(with: event) == true else { throw MainWindowCheck.failed("organization-shortcut-\(code)") }
}
