import AppKit
import Synchronization

/// Fixture-only app-loop checks for capture-to-window focus and native controls.
@MainActor
func validateOpenNoteCapture(register: (MacInteraction) -> Void) async {
    guard let index = CommandLine.arguments.firstIndex(of: "--open-note-capture-report"),
          index + 1 < CommandLine.arguments.count else { exit(2) }
    let reportURL = URL(fileURLWithPath: CommandLine.arguments[index + 1])
    let diagnostics = Diagnostics(file: reportURL)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hana-open-note-\(UUID().uuidString)")
    let faults = Mutex((hold: true, arrivals: 0, failBefore: false, failAfter: false))
    let gate = DispatchSemaphore(value: 0)
    var store: CollectionStore?
    var interaction: MacInteraction?
    do {
        let location = try CollectionLocation.createFixtureRoot(at: root)
        let opened = try await CollectionStore.open(location, faults: .init(beforeCommit: { _ in
            let held = faults.withLock { state in state.arrivals += 1; return state.hold }
            if held { gate.wait() }
            let fail = faults.withLock { state in let fail = state.failBefore; state.failBefore = false; return fail }
            if fail { throw OpenNoteCaptureCheck.failed("injected-before") }
        }, afterCommit: {
            let fail = faults.withLock { state in let fail = state.failAfter; state.failAfter = false; return fail }
            if fail { throw OpenNoteCaptureCheck.failed("injected-after") }
        }))
        store = opened
        let platform = MacInteraction(diagnostics: diagnostics, collection: Task { opened })
        interaction = platform
        register(platform)
        platform.start()
        platform.open(.main)
        try await openCaptureCheck("main-key") { platform.window(for: .main)?.isKeyWindow == true }

        let invocation = platform.presentBar()
        let editor = try await openCaptureEditor()
        let none = NSRange(location: NSNotFound, length: 0)
        editor.insertText("-", replacementRange: none)
        platform.openInWindowButton.performClick(nil)
        guard platform.captureMessage != nil, platform.currentInvocation == invocation,
              editor.window?.firstResponder === editor else { throw OpenNoteCaptureCheck.failed("blank-control") }
        editor.insertText("ไทย 🌸\n**text**", replacementRange: none)
        guard let commandReturn = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command,
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: editor.window?.windowNumber ?? 0,
            context: nil, characters: "\r", charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36) else {
            throw OpenNoteCaptureCheck.failed("key-event")
        }
        guard editor.window?.performKeyEquivalent(with: commandReturn) == true else { throw OpenNoteCaptureCheck.failed("key-equivalent") }
        try await openCaptureCheck("paused") { faults.withLock { $0.arrivals } == 1 }
        platform.openInWindowButton.performClick(nil)
        _ = editor.window?.performKeyEquivalent(with: commandReturn)
        editor.insertText("late", replacementRange: none)
        guard editor.string == "ไทย 🌸\n**text**", !editor.isEditable else { throw OpenNoteCaptureCheck.failed("frozen") }
        faults.withLock { $0.hold = false }
        gate.signal()
        try await openCaptureCheck("opened") { platform.currentInvocation == nil && platform.mainWindowPresentation?.rows.count == 1 }
        guard let note = try await opened.read(.notes, in: opened.generation).first else { throw OpenNoteCaptureCheck.failed("saved-note") }
        try await openCaptureCheck("note-key") { platform.window(for: .note(note.id))?.isKeyWindow == true }
        guard let window = platform.window(for: .note(note.id)), let noteEditor = window.firstResponder as? NSTextView,
              noteEditor.string == "ไทย 🌸\n**text**", noteEditor.selectedRange() == NSRange(location: 15, length: 0),
              faults.withLock({ $0.arrivals }) == 1 else { throw OpenNoteCaptureCheck.failed("end-focus") }
        diagnostics.record("open-note-capture.focused", state: ["key": true, "endOffset": 15, "singleCommit": true])

        for lostAcknowledgement in [false, true] {
            faults.withLock { state in state.failBefore = !lostAcknowledgement; state.failAfter = lostAcknowledgement }
            _ = platform.presentBar()
            let captureEditor = try await openCaptureEditor()
            let body = lostAcknowledgement ? "Lost acknowledgement" : "Retry before commit"
            captureEditor.insertText("-", replacementRange: none)
            captureEditor.insertText(body, replacementRange: none)
            platform.openInWindowButton.performClick(nil)
            try await openCaptureCheck("failure-kept") { platform.captureMessage != nil }
            guard captureEditor.string == body, captureEditor.isEditable, platform.mode == .note else {
                throw OpenNoteCaptureCheck.failed("failure-text")
            }
            platform.openInWindowButton.performClick(nil)
            try await openCaptureCheck("retry-opened") { platform.currentInvocation == nil }
            let matches = try await opened.read(.notes, in: opened.generation).filter { $0.body == body }
            guard matches.count == 1, let retried = matches.first else { throw OpenNoteCaptureCheck.failed("retry-single-note") }
            try await openCaptureCheck("retry-key") { platform.window(for: .note(retried.id))?.isKeyWindow == true }
            diagnostics.record("open-note-capture.retry", state: ["lostAcknowledgement": lostAcknowledgement, "singleNote": true, "key": true])
        }

        faults.withLock { $0.hold = true }
        let before = faults.withLock { $0.arrivals }
        let dismissed = platform.presentBar()
        let captureEditor = try await openCaptureEditor()
        captureEditor.insertText("-", replacementRange: none)
        captureEditor.insertText("Quiet completion", replacementRange: none)
        platform.openCaptureInWindow()
        try await openCaptureCheck("dismiss-paused") { faults.withLock { $0.arrivals } == before + 1 }
        platform.dismiss(dismissed, reason: .outsideClick)
        platform.window(for: .main)?.makeKeyAndOrderFront(nil)
        faults.withLock { $0.hold = false }
        gate.signal()
        try await openCaptureCheck("dismiss-finished") { platform.currentInvocation == nil }
        guard let quiet = try await opened.read(.notes, in: opened.generation).first(where: { $0.body == "Quiet completion" }),
              platform.window(for: .note(quiet.id)) == nil,
              platform.window(for: .main)?.isKeyWindow == true else { throw OpenNoteCaptureCheck.failed("dismiss-focus") }
        diagnostics.record("open-note-capture.dismissed", state: ["committed": true, "opened": false, "chosenFocusKept": true])
        let savedIDs = try await opened.read(.notes, in: opened.generation).map(\.id)
        for saved in savedIDs { platform.window(for: .note(saved))?.close() }
        platform.window(for: .main)?.close()
        platform.stop()

        // Repeat the native test’s key/responder/query assertions on the real
        // application event loop, including a genuinely invocation-bound open.
        var completion: CheckedContinuation<CollectionStore, any Error>?
        let delayedCollection = Task<CollectionStore, any Error> {
            try await withCheckedThrowingContinuation { completion = $0 }
        }
        let delayed = MacInteraction(diagnostics: diagnostics, collection: delayedCollection)
        interaction = delayed
        register(delayed)
        delayed.start()
        delayed.open(.main)
        try await openCaptureCheck("delayed-main-key") { NSApp.keyWindow === delayed.window(for: .main) }
        let original = delayed.presentBar()
        let originalEditor = try await openCaptureEditor()
        delayed.open(.note(note.id), from: original, focusAtEnd: true)
        try await openCaptureCheck("superseded-original-panel-hidden") {
            originalEditor.window?.isVisible == false
        }
        try await openCaptureCheck("delayed-collection") { completion != nil }
        let current = delayed.presentBar()
        let newerEditor = try await openCaptureEditor()
        newerEditor.insertText("new query", replacementRange: none)
        completion?.resume(returning: opened)
        try await openCaptureCheck("superseded-open-finished") {
            (try? String(contentsOf: reportURL, encoding: .utf8).contains("note.open-focus-superseded")) == true
        }
        guard delayed.currentInvocation == current, NSApp.keyWindow?.firstResponder === newerEditor,
              newerEditor.string == "new query", delayed.window(for: .note(note.id)) == nil else {
            throw OpenNoteCaptureCheck.failed("newer-bar-focus")
        }
        diagnostics.record("open-note-capture.newer-bar", state: ["keyResponderKept": true, "queryKept": true, "unwantedWindow": false])
        await opened.close()
        delayed.window(for: .main)?.close()
        delayed.stop()
        try FileManager.default.removeItem(at: root)
        diagnostics.record("open-note-capture.validation-passed", state: [:])
        RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { NSApp.terminate(nil) } }
    } catch {
        gate.signal()
        diagnostics.record("open-note-capture.validation-failed", state: ["step": (error as? OpenNoteCaptureCheck)?.step ?? "storage"])
        interaction?.stop()
        await store?.close()
        try? FileManager.default.removeItem(at: root)
        exit(1)
    }
}

private enum OpenNoteCaptureCheck: Error {
    case failed(String)
    var step: String { switch self { case .failed(let step): step } }
}
@MainActor
private func openCaptureCheck(_ step: String, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    guard condition() else { throw OpenNoteCaptureCheck.failed(step) }
}
@MainActor
private func openCaptureEditor() async throws -> NSTextView {
    try await openCaptureCheck("capture-editor") { NSApp.keyWindow?.title == "Hana Search" && NSApp.keyWindow?.firstResponder is NSTextView }
    guard let editor = NSApp.keyWindow?.firstResponder as? NSTextView else { throw OpenNoteCaptureCheck.failed("capture-editor") }
    return editor
}
