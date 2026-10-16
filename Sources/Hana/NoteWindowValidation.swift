import AppKit
import Synchronization

/// Uses the app's real run loop for minimized-window and last-close policy
/// checks. Every byte belongs to a newly marked disposable fixture.
@MainActor
func validateNoteWindow(register: (MacInteraction) -> Void) async {
    guard let index = CommandLine.arguments.firstIndex(of: "--note-window-report"), index + 1 < CommandLine.arguments.count else { exit(2) }
    let report = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    let diagnostics = Diagnostics(file: report)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hana-note-window-\(UUID().uuidString)")
    let held = Mutex(false)
    let arrived = Mutex(false)
    let gate = DispatchSemaphore(value: 0)
    var store: CollectionStore?
    var interaction: MacInteraction?
    do {
        let location = try CollectionLocation.createFixtureRoot(at: root)
        let opened = try await CollectionStore.open(location, faults: .init(beforeCommit: { _ in
            if held.withLock({ $0 }) {
                arrived.withLock { $0 = true }
                gate.wait()
            }
        }))
        store = opened
        let note = try await opened.perform(.createNote(operation: UUID(), body: "Fixture note"), in: opened.generation)
        let platform = MacInteraction(diagnostics: diagnostics, collection: Task { opened })
        interaction = platform
        register(platform)
        platform.start()
        _ = platform.open(.main)
        _ = platform.open(.note(note.id))
        try await noteCheck("editor") { platform.window(for: .note(note.id))?.firstResponder is NSTextView }
        guard let window = platform.window(for: .note(note.id)), let editor = window.firstResponder as? NSTextView else { throw NoteWindowCheck.failed("editor") }
        guard editor.textLayoutManager != nil else { throw NoteWindowCheck.failed("textkit-two") }
        window.miniaturize(nil)
        try await noteCheck("minimized") { window.isMiniaturized }
        guard NSApp.activationPolicy() == .regular else { throw NoteWindowCheck.failed("minimized-policy") }
        diagnostics.record("note-window.minimized", state: ["regular": true])
        _ = platform.open(.note(note.id))
        try await noteCheck("raised") { !window.isMiniaturized && NSApp.keyWindow === window }
        guard platform.window(for: .note(note.id)) === window else { throw NoteWindowCheck.failed("singleton") }
        let origin = platform.presentBar()
        try await noteCheck("bar-editor") { NSApp.keyWindow is NSPanel }
        platform.dismiss(origin, reason: .escape)
        try await noteCheck("escape-origin") { NSApp.keyWindow === window && window.firstResponder === editor }
        editor.selectAll(nil)
        editor.insertText("Organized fixture ไทย", replacementRange: NSRange(location: NSNotFound, length: 0))
        _ = platform.open(.main, section: .notes)
        try await noteCheck("organization-main") { NSApp.keyWindow === platform.window(for: .main) && platform.mainWindowPresentation?.rows.first?.id == note.id }
        platform.selectMainNote(note.id)
        try noteShortcut("p", code: 35)
        try await noteCheck("keyboard-pin") { platform.noteSession(note.id)?.committed.isPinned == true && platform.noteSession(note.id)?.state == .saved }
        let pinned = try await opened.read(.note(note.id), in: opened.generation)
        guard pinned?.body == "Organized fixture ไทย" else { throw NoteWindowCheck.failed("pin-flush") }
        try noteShortcut("a", code: 0)
        try await noteCheck("keyboard-archive") { !editor.isEditable && platform.canRestoreNote(note.id) }
        let archived = try await opened.read(.note(note.id), in: opened.generation)
        editor.insertText("Refused", replacementRange: NSRange(location: NSNotFound, length: 0))
        guard editor.string == "Organized fixture ไทย" else { throw NoteWindowCheck.failed("archived-typing") }
        _ = platform.open(.note(note.id))
        try await noteCheck("restore-window-key") { NSApp.keyWindow === window }
        try noteShortcut("r", code: 15)
        try await noteCheck("keyboard-restore") { editor.isEditable && platform.mainWindowPresentation?.rows.first?.id == note.id }
        let restored = try await opened.read(.note(note.id), in: opened.generation)
        guard restored?.body == archived?.body, restored?.isPinned == true,
              restored?.archivedAt == nil, restored?.contentEditedAt == archived?.contentEditedAt else { throw NoteWindowCheck.failed("restore-metadata") }
        diagnostics.record("note-window.organization", state: ["keyboardPin": true, "flush": true, "readOnly": true, "keyboardRestore": true, "metadataPreserved": true])
        editor.selectAll(nil)
        editor.insertText("Renamed fixture\n**Markdown**", replacementRange: NSRange(location: NSNotFound, length: 0))
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        try await noteCheck("deactivation-title") { window.title == "Renamed fixture" && platform.mainWindowPresentation?.rows.first?.title == "Renamed fixture" }
        guard platform.menuBarMenu?.items.contains(where: { $0.title == "Renamed fixture" }) == true,
              NSApp.windowsMenu?.items.contains(where: { $0.title == "Renamed fixture" }) == true else { throw NoteWindowCheck.failed("committed-menus") }
        guard NSApp.windowsMenu?.items.filter({ $0.title == "Renamed fixture" }).count == 1 else { throw NoteWindowCheck.failed("window-menu-singleton") }
        diagnostics.record("note-window.deactivation", state: ["titleCommitted": true, "menus": true, "nativeWindowEntries": 1])
        platform.window(for: .main)?.close()
        held.withLock { $0 = true }
        editor.selectAll(nil)
        editor.insertText("Saved before last close ไทย\n**Markdown**", replacementRange: NSRange(location: NSNotFound, length: 0))
        window.performClose(nil)
        try await noteCheck("close-flush-started") { arrived.withLock { $0 } }
        guard platform.window(for: .note(note.id)) === window, NSApp.activationPolicy() == .regular else { throw NoteWindowCheck.failed("close-held-policy") }
        diagnostics.record("note-window.close-held", state: ["regular": true, "windowRetained": true])
        held.withLock { $0 = false }
        gate.signal()
        try await noteCheck("last-close") { platform.window(for: .note(note.id)) == nil && NSApp.activationPolicy() == .accessory }
        let saved = try await opened.read(.note(note.id), in: opened.generation)
        guard saved?.body == "Saved before last close ไทย\n**Markdown**" else { throw NoteWindowCheck.failed("close-bytes") }
        diagnostics.record("note-window.closed", state: ["accessory": true, "committed": true])
        await opened.close()
        try FileManager.default.removeItem(at: root)
        diagnostics.record("note-window.validation-passed", state: [:])
        platform.stop()
        RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { NSApp.terminate(nil) } }
    } catch {
        gate.signal()
        diagnostics.record("note-window.validation-failed", state: ["step": (error as? NoteWindowCheck)?.step ?? "storage"])
        interaction?.stop()
        await store?.close()
        try? FileManager.default.removeItem(at: root)
        exit(1)
    }
}

private enum NoteWindowCheck: Error {
    case failed(String)
    var step: String { switch self { case .failed(let step): step } }
}
@MainActor
private func noteCheck(_ step: String, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    guard condition() else { throw NoteWindowCheck.failed(step) }
}

@MainActor
private func noteShortcut(_ key: String, code: UInt16) throws {
    guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [.command, .control],
                                      timestamp: 0, windowNumber: NSApp.keyWindow?.windowNumber ?? 0,
                                      context: nil, characters: key, charactersIgnoringModifiers: key,
                                      isARepeat: false, keyCode: code),
          NSApp.mainMenu?.performKeyEquivalent(with: event) == true else { throw NoteWindowCheck.failed("shortcut-\(key)") }
}
