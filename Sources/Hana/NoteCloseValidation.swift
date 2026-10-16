import AppKit
import Synchronization

/// The original close/sheet safety assertions, under the real app run loop.
/// SwiftPM's async-main host can exit while AppKit dispatches these sheets.
/// This opt-in path owns only a newly marked disposable collection.
@MainActor
func validateNoteClose(register: (MacInteraction) -> Void) async {
    let arguments = CommandLine.arguments
    guard let reportIndex = arguments.firstIndex(of: "--note-close-report"), reportIndex + 1 < arguments.count,
          let scenarioIndex = arguments.firstIndex(of: "--note-close-scenario"), scenarioIndex + 1 < arguments.count,
          let scenario = NoteCloseScenario(rawValue: arguments[scenarioIndex + 1]) else { exit(2) }
    let diagnostics = Diagnostics(file: URL(fileURLWithPath: arguments[reportIndex + 1]))
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("hana-note-close-\(UUID().uuidString)")
    let fail = Mutex(false)
    let held = Mutex(false)
    let arrivals = Mutex(0)
    let gate = DispatchSemaphore(value: 0)
    var store: CollectionStore?
    var interaction: MacInteraction?
    do {
        let location = try CollectionLocation.createFixtureRoot(at: root)
        let opened = try await CollectionStore.open(location, faults: .init(beforeCommit: { _ in
            if fail.withLock({ $0 }) { throw CollectionStoreError.storageFailure(code: 8) }
            if held.withLock({ $0 }) {
                arrivals.withLock { $0 += 1 }
                gate.wait()
            }
        }))
        store = opened
        let note = try await opened.perform(.createNote(operation: UUID(), body: "Original"), in: opened.generation)
        let platform = MacInteraction(collection: Task { opened })
        interaction = platform
        register(platform)
        _ = platform.open(.main)
        _ = platform.open(.note(note.id))
        try await closeCheck("editor") { platform.window(for: .note(note.id))?.firstResponder is NSTextView }
        guard let window = platform.window(for: .note(note.id)), let editor = window.firstResponder as? NSTextView else {
            throw NoteCloseCheck.failed("editor")
        }
        if scenario.isPending { held.withLock { $0 = true } }
        else { fail.withLock { $0 = true } }
        let body = scenario.isPending ? "Pending close" : "Keep this unsaved text"
        editor.selectAll(nil)
        editor.insertText(body, replacementRange: NSRange(location: NSNotFound, length: 0))
        if !scenario.isPending {
            do {
                try await platform.noteSession(note.id)?.flush()
                throw NoteCloseCheck.failed("flush-must-fail")
            } catch CollectionStoreError.storageFailure(code: 8) {}
        }
        window.performClose(nil)
        if scenario.isPending {
            try await closeCheck("paused-held-sheet") {
                arrivals.withLock { $0 } == 1 && platform.noteCloseIsHeld(note.id) && window.attachedSheet != nil
            }
            try await closeCheck("saving-status") { platform.noteSaveStatus(note.id) == "Saving…" }
        } else {
            try await closeCheck("held-sheet") { platform.noteCloseIsHeld(note.id) && window.attachedSheet != nil }
        }
        guard platform.noteActions(note.id) == [.retry, .copyText, .discardChanges] else {
            throw NoteCloseCheck.failed("close-actions")
        }
        if scenario.isPending {
            guard NSApp.activationPolicy() == .regular else { throw NoteCloseCheck.failed("pending-policy") }
        } else {
            guard platform.window(for: .note(note.id)) === window else { throw NoteCloseCheck.failed("held-window") }
            try await closeWithRestoredPasteboard {
                await platform.performNoteAction(.copyText, id: note.id)
                guard NSPasteboard.general.string(forType: .string) == body else { throw NoteCloseCheck.failed("copy-bytes") }
                guard platform.window(for: .note(note.id)) === window else { throw NoteCloseCheck.failed("copy-keeps-window") }
            }
        }
        if scenario == .failedRetry { fail.withLock { $0 = false } }
        if !scenario.isPending || scenario == .pendingDiscard {
            await platform.performNoteAction(scenario.discards ? .discardChanges : .retry, id: note.id)
        }
        held.withLock { $0 = false }
        gate.signal()
        try await closeCheck("closed") { platform.window(for: .note(note.id)) == nil }
        let expected = scenario.discards ? "Original" : body
        if scenario.isPending {
            await opened.close()
            let reopened = try await CollectionStore.open(location)
            let saved = try await reopened.read(.note(note.id), in: reopened.generation)
            await reopened.close()
            guard saved?.body == expected else { throw NoteCloseCheck.failed("reopened-bytes") }
        } else {
            guard try await opened.read(.note(note.id), in: opened.generation)?.body == expected else {
                throw NoteCloseCheck.failed("stored-bytes")
            }
            await opened.close()
        }
        diagnostics.record("note-close.\(scenario.rawValue).assertions-passed", state: [:])
        platform.stop()
        try FileManager.default.removeItem(at: root)
        diagnostics.record("note-close.validation-passed", state: [:])
        RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { NSApp.terminate(nil) } }
    } catch {
        held.withLock { $0 = false }
        gate.signal()
        diagnostics.record("note-close.validation-failed", state: ["step": (error as? NoteCloseCheck)?.step ?? "storage"])
        interaction?.window(for: .main)?.close()
        interaction?.stop()
        await store?.close()
        try? FileManager.default.removeItem(at: root)
        exit(1)
    }
}

private enum NoteCloseScenario: String {
    case failedRetry = "failed-retry", failedDiscard = "failed-discard"
    case pendingSave = "pending-save", pendingDiscard = "pending-discard"

    var isPending: Bool { self == .pendingSave || self == .pendingDiscard }
    var discards: Bool { self == .failedDiscard || self == .pendingDiscard }
}

private enum NoteCloseCheck: Error {
    case failed(String)
    var step: String { switch self { case .failed(let step): step } }
}

@MainActor
private func closeCheck(_ step: String, _ condition: () -> Bool) async throws {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
    guard condition() else { throw NoteCloseCheck.failed(step) }
}

@MainActor
private func closeWithRestoredPasteboard(_ body: () async throws -> Void) async rethrows {
    let pasteboard = NSPasteboard.general
    let saved = (pasteboard.pasteboardItems ?? []).map { source in
        let item = NSPasteboardItem()
        for type in source.types { if let data = source.data(forType: type) { item.setData(data, forType: type) } }
        return item
    }
    defer { pasteboard.clearContents(); pasteboard.writeObjects(saved) }
    try await body()
}
