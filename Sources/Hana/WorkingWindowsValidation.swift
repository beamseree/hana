import AppKit

/// An indefinite, isolated working collection, or one phase of the two-process
/// orderly-quit smoke. It never opens live storage or closes the Store itself
/// on success: the real application delegate owns normal termination.
@MainActor
func validateWorkingWindows(_ options: WorkingWindowsOptions,
                            register: (Task<CollectionStore, any Error>, MacInteraction, Diagnostics) -> Void) async {
    let diagnostics = Diagnostics(file: options.report)
    var opened: CollectionStore?
    var interaction: MacInteraction?
    do {
        let (store, seed) = try await WorkingWindowsFixture.open(root: options.root)
        opened = store
        let collection = Task<CollectionStore, any Error> { store }
        let platform = MacInteraction(diagnostics: diagnostics, collection: collection)
        interaction = platform
        register(collection, platform, diagnostics)
        platform.start()
        diagnostics.record("working-windows.identity", state: [
            "runID": UUID().uuidString, "pid": ProcessInfo.processInfo.processIdentifier,
            "bundle": Bundle.main.bundleIdentifier ?? "unbundled", "axTrusted": AXIsProcessTrusted(),
            "screens": NSScreen.screens.map { ["width": $0.frame.width, "height": $0.frame.height, "scale": $0.backingScaleFactor] }
        ])
        for (name, query) in [("inbox", CollectionQuery<[TaskItem]>.inbox), ("today", .today), ("completed", .completedTasks), ("archivedTasks", .archivedTasks)] {
            Task {
                do {
                    for try await rows in store.observe(query, in: store.generation) {
                        diagnostics.record("working-windows.order", state: ["list": name, "ids": rows.map { $0.id.uuidString },
                            "aliases": rows.map { row in seed.tasks.first(where: { $0.value == row.id })?.key ?? "captured" }])
                    }
                } catch { /* Normal Store close ends the observation. */ }
            }
        }
        platform.open(.main)
        let noteID = seed.notes[options.mode == .interactive ? "scratch" : "quit"]!
        platform.open(.note(noteID))
        let deadline = ContinuousClock.now + .seconds(5)
        while !(platform.window(for: .note(noteID))?.firstResponder is NSTextView), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        guard let editor = platform.window(for: .note(noteID))?.firstResponder as? NSTextView else { throw WorkingWindowsOptions.Failure.editor }
        diagnostics.record("working-windows.ready", state: ["interactive": options.mode == .interactive, "regular": NSApp.activationPolicy() == .regular,
                                                            "noteIDs": seed.notes.mapValues(\.uuidString)])
        if options.mode == .interactive { return }
        if options.mode == .smokeVerify {
            guard let saved = try await store.read(.note(noteID), in: store.generation),
                  saved.body.utf8.elementsEqual(WorkingWindowsFixture.smokeBody.utf8),
                  try await store.read(.inbox, in: store.generation).map(\.id) == [seed.tasks["inbox2"]!, seed.tasks["inbox1"]!, seed.tasks["inbox3"]!],
                  try await store.read(.today, in: store.generation).map(\.id) == [seed.tasks["today3"]!, seed.tasks["today2"]!, seed.tasks["today1"]!] else { throw WorkingWindowsOptions.Failure.persistence }
            diagnostics.record("working-windows.relaunch-verified", state: ["exactBytes": true, "stableIDs": true, "independentOrders": true])
        } else {
            guard editor.string.utf8.elementsEqual(WorkingWindowsFixture.quitBody.utf8) else { throw WorkingWindowsOptions.Failure.persistence }
            platform.open(.main, section: .inbox)
            let orderDeadline = ContinuousClock.now + .seconds(5)
            while platform.taskWorkspacePresentation?.inbox.count != 3, ContinuousClock.now < orderDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard let order = platform.taskWorkspacePresentation?.inbox.map(\.id),
                  await platform.performTaskReorder(.init(id: seed.tasks["inbox3"]!, placement: .inbox,
                                                          predecessor: seed.tasks["inbox1"]!, expectedOrder: order)) else { throw WorkingWindowsOptions.Failure.persistence }
            platform.open(.note(noteID))
            let focusDeadline = ContinuousClock.now + .seconds(5)
            while NSApp.keyWindow !== platform.window(for: .note(noteID)), ContinuousClock.now < focusDeadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            guard NSApp.keyWindow?.firstResponder === editor else { throw WorkingWindowsOptions.Failure.editor }
            editor.selectAll(nil)
            editor.insertText(WorkingWindowsFixture.smokeBody, replacementRange: NSRange(location: NSNotFound, length: 0))
            // No await, flush or Store close between the native insertion and
            // termination request: AppDelegate must drain this editor itself.
            guard let session = platform.noteSession(noteID), session.text.utf8.elementsEqual(WorkingWindowsFixture.smokeBody.utf8),
                  session.committed.body.utf8.elementsEqual(WorkingWindowsFixture.quitBody.utf8), session.hasUnsavedChanges else { throw WorkingWindowsOptions.Failure.editor }
            diagnostics.record("working-windows.edited-before-quit", state: ["pendingEdit": true])
        }
        diagnostics.record("working-windows.normal-quit-request", state: ["writePhase": options.mode == .smokeWrite])
        RunLoop.main.perform(inModes: [.common]) { MainActor.assumeIsolated { NSApp.terminate(nil) } }
    } catch {
        diagnostics.record("working-windows.failed", state: ["step": String(describing: (error as? WorkingWindowsOptions.Failure) ?? .fixture)])
        interaction?.stop()
        await opened?.close()
        exit(1)
    }
}
