import AppKit
import ApplicationServices

/// Opt-in measurements at the agreed Search / Mac Interaction boundaries.
/// Programmatic presentation/editing is not physical shortcut-to-typing latency.
@MainActor
func validatePerformance(_ interaction: MacInteraction, diagnostics: Diagnostics) async {
    guard diagnostics.isEnabled else { NSApp.terminate(nil); return }
    let run = UUID().uuidString
    func record(_ event: String, _ state: [String: Any]) {
        diagnostics.record("performance.\(event)", state: state.merging(["run": run]) { _, new in new })
    }
    func now() -> Double { ProcessInfo.processInfo.systemUptime }
    record("environment", ["accessibilityTrusted": AXIsProcessTrusted(),
        "displays": NSScreen.screens.map { ["frame": NSStringFromRect($0.frame),
                                             "visibleFrame": NSStringFromRect($0.visibleFrame),
                                             "scale": $0.backingScaleFactor] },
        "typingGapMilliseconds": (validationTypingGap ?? Search.defaultTypingGap) / .milliseconds(1),
        "warmSamples": 30, "typingSamples": 10, "retainedResultsClearedBetweenSamples": true])

    // This samples scheduling lateness, including OS contention. It cannot
    // attribute a pause to Hana or prove physical keystroke/display latency.
    var lateness: [Double] = []
    let heartbeat = Task {
        while !Task.isCancelled {
            let start = now()
            do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
            lateness.append(max(0, (now() - start) * 1000 - 5))
        }
    }
    defer { heartbeat.cancel() }

    for sample in 0...30 {
        guard !Task.isCancelled else { break }
        let start = now()
        let invocation = interaction.presentBar()
        let presentation = (now() - start) * 1000
        // Allow the existing bounded AX placement task to finish, if applicable.
        while !(NSApp.keyWindow?.firstResponder is NSTextView), now() - start < 1 {
            try? await Task.sleep(for: .milliseconds(2))
        }
        guard interaction.currentInvocation == invocation,
              let editor = NSApp.keyWindow?.firstResponder as? NSTextView else {
            record("interrupted", ["sample": sample, "phase": "presentation"])
            break
        }
        let insertionStart = now()
        editor.insertText("Hana", replacementRange: NSRange(location: NSNotFound, length: 0))
        let insertion = (now() - insertionStart) * 1000
        var firstApp: Double?, firstFile: Double?
        while now() - insertionStart < 3 {
            guard interaction.currentInvocation == invocation, interaction.query == "Hana" else { break }
            let elapsed = (now() - insertionStart) * 1000
            if firstApp == nil, interaction.results.contains(where: { $0.kind == .application }) { firstApp = elapsed }
            if firstFile == nil, interaction.results.contains(where: { $0.kind != .application }) { firstFile = elapsed }
            // Keep searching for at least one second, including later batches.
            if firstApp != nil, firstFile != nil, elapsed >= 1000 { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        let intact = interaction.currentInvocation == invocation && interaction.query == "Hana"
        var state: [String: Any] = ["sample": sample, "coldProcessSample": sample == 0,
            "presentationCallMilliseconds": presentation, "nativeInsertionCallMilliseconds": insertion,
            "contextIntact": intact, "appFound": firstApp != nil, "fileFound": firstFile != nil]
        state["firstAppObservedMilliseconds"] = firstApp
        state["firstFileObservedMilliseconds"] = firstFile
        record("integrated", state)
        clearRetainedResults(interaction, invocation)
        if !intact { break }
        try? await Task.sleep(for: .milliseconds(100))
    }

    // Rapid typing: one character every 30 ms, faster than the typing gap,
    // so indexed-file queries wait for the pause after the last character.
    let typingStart = lateness.count
    for sample in 0..<10 {
        guard !Task.isCancelled else { break }
        let invocation = interaction.presentBar()
        let start = now()
        while !(NSApp.keyWindow?.firstResponder is NSTextView), now() - start < 1 {
            try? await Task.sleep(for: .milliseconds(2))
        }
        guard interaction.currentInvocation == invocation,
              let editor = NSApp.keyWindow?.firstResponder as? NSTextView else {
            record("interrupted", ["sample": sample, "phase": "typing"])
            break
        }
        var lastKeystroke = now()
        for (offset, character) in "Hana".enumerated() {
            if offset > 0 { try? await Task.sleep(for: .milliseconds(30)) }
            lastKeystroke = now()
            editor.insertText(String(character), replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        var firstFile: Double?
        while now() - lastKeystroke < 3 {
            guard interaction.currentInvocation == invocation, interaction.query == "Hana" else { break }
            let elapsed = (now() - lastKeystroke) * 1000
            if firstFile == nil, interaction.results.contains(where: { $0.kind != .application }) { firstFile = elapsed }
            if firstFile != nil, elapsed >= 1000 { break }
            try? await Task.sleep(for: .milliseconds(2))
        }
        let intact = interaction.currentInvocation == invocation && interaction.query == "Hana"
        var state: [String: Any] = ["sample": sample, "contextIntact": intact, "fileFound": firstFile != nil]
        state["firstFileAfterLastKeystrokeMilliseconds"] = firstFile
        record("typing", state)
        clearRetainedResults(interaction, invocation)
        if !intact { break }
        try? await Task.sleep(for: .milliseconds(100))
    }
    let typingLateness = Array(lateness[typingStart...])

    // Isolate local Search service cost by disabling the typing gap and file lookup.
    // Includes delivery/ranking, but excludes UI rendering and the production typing gap.
    let local = Search(roots: ApplicationCatalog.conventionalRoots, typingGap: .zero)
    for sample in 0...30 {
        let start = now()
        var elapsed: Double?
        let stream = local.search(Search.Request(text: "Hana"))
        let receiver = Task {
            for await batch in stream {
                if batch.appStatus != .loading, batch.results.contains(where: { $0.kind == .application }) {
                    elapsed = (now() - start) * 1000
                    break
                }
            }
        }
        while elapsed == nil, now() - start < 3 {
            try? await Task.sleep(for: .milliseconds(2))
        }
        receiver.cancel()
        var state: [String: Any] = ["sample": sample, "freshCatalog": sample == 0, "found": elapsed != nil]
        state["milliseconds"] = elapsed
        record("local", state)
    }
    heartbeat.cancel()
    await heartbeat.value
    record("scheduling", ["samples": lateness.count, "excessMilliseconds": lateness,
                          "typingExcessMilliseconds": typingLateness])
    record("complete", [:])
    NSApp.terminate(nil)
}

/// Search keeps the previous request's matching results across dismissals, so
/// the next sample's "Hana" would show them before any source responds. Clear
/// the query first so every sample measures fresh source results; the pause
/// after it exceeds the typing gap, so the next query is not held.
@MainActor
private func clearRetainedResults(_ interaction: MacInteraction, _ invocation: MacInteraction.Invocation) {
    if interaction.currentInvocation == invocation { interaction.updateQuery("") }
    interaction.dismiss(invocation, reason: .outsideClick)
}
