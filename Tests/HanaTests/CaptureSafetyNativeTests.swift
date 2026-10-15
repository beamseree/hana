import AppKit
import Testing
@testable import Hana

/// Real editor, panels and disposable Store; run only with the native testing slot.
@Suite(.serialized, .nativeWindowSlot, .timeLimit(.minutes(1)))
@MainActor
struct CaptureSafetyNativeTests {
    enum Outcome: CaseIterable { case committed, rolledBack, lostAcknowledgement }
    private let none = NSRange(location: NSNotFound, length: 0)

    @Test(arguments: ["-", "["], Outcome.allCases)
    func dismissalDuringAPausedSavePreservesTheOutcomeAndTheChosenFocus(prefix: String, outcome: Outcome) async throws {
        for reason in [MacInteraction.DismissalReason.escape, .outsideClick] {
            let fixture = try TemporaryFixture()
            let gate = CommitGate()
            defer { gate.open() }
            let fail = FailOnce()
            let store = try await CollectionStore.open(fixture.location, faults: .init(beforeCommit: { _ in
                gate.pass()
                if outcome == .rolledBack, fail.take() { throw InjectedFailure() }
            }, afterCommit: {
                if outcome == .lostAcknowledgement, fail.take() { throw InjectedFailure() }
            }))
            let origin = CaptureFocusDestination()
            let clicked = CaptureFocusDestination()
            defer { origin.panel.close(); clicked.panel.close() }
            origin.focus()
            try await eventually { origin.panel.isKeyWindow }
            let interaction = MacInteraction(search: Search(source: { CatalogFeed().stream() }, typingGap: .zero),
                                             collection: Task { store }, confirmationDuration: .zero,
                                             frontmostApplication: { .current })
            let invocation = interaction.presentBar()
            let editor = try await captureEditor()
            editor.insertText(prefix, replacementRange: none)
            editor.insertText("keep this", replacementRange: none)
            if prefix == "[" { editor.keyDown(with: try tabKey()) }
            editor.keyDown(with: try returnKey())
            try await eventually { gate.arrivals == 1 }
            #expect(interaction.modeLabelText == "Saving…" && !editor.isEditable)
            if reason == .escape { editor.keyDown(with: try escapeKey()) }
            else { interaction.dismiss(invocation, reason: reason) }
            #expect(interaction.currentInvocation == invocation && editor.string == "keep this")
            #expect(editor.window?.isVisible == true)
            // An unresolved write cannot be superseded by a newer invocation.
            #expect(interaction.presentBar() == invocation)
            #expect(interaction.modeLabelText == "Saving…" && !editor.isEditable)
            #expect(editor.string == "keep this" && gate.arrivals == 1)
            // A later user choice is represented by a different real key panel.
            // This tests AppKit responder state, not physical foreign-app typing.
            clicked.focus()
            try await eventually { clicked.panel.isKeyWindow }
            for _ in 0..<3 { editor.keyDown(with: try returnKey()) }
            #expect(gate.arrivals == 1)
            gate.open()
            if outcome == .committed {
                try await eventually { interaction.currentInvocation == nil }
            } else {
                try await eventually { interaction.captureMessage != nil }
                #expect(interaction.currentInvocation == invocation)
                #expect(editor.string == "keep this" && editor.isEditable)
                #expect(editor.window?.isVisible == true)
                #expect(interaction.captureMessage == "Save not confirmed. Your text is kept. Press Enter to retry.")
            }
            #expect(clicked.panel.isKeyWindow && clicked.panel.firstResponder === clicked.editor)
            #expect(!origin.panel.isKeyWindow)
            if outcome != .committed {
                // Only explicit reinvocation takes focus, and recovers this capture.
                #expect(interaction.presentBar() == invocation)
                try await eventually { editor.window?.isKeyWindow == true }
                #expect(editor.string == "keep this")
                editor.keyDown(with: try returnKey())
                try await eventually { interaction.currentInvocation == nil }
            }
            let records = try await store.read(.allRecords, in: store.generation)
            #expect(records.notes.count + records.tasks.count == 1)
            #expect(records.notes.first?.body == "keep this" || records.tasks.first?.title == "keep this")
            if prefix == "[" { #expect(records.tasks.first?.placement == .today) }
            await store.close()
        }
    }

    @Test(arguments: ["-", "["])
    func editingAfterARolledBackNativeSaveCreatesTheEditedItem(prefix: String) async throws {
        let fixture = try TemporaryFixture()
        let fail = FailOnce()
        let store = try await CollectionStore.open(fixture.location, faults: .init(beforeCommit: { _ in
            if fail.take() { throw InjectedFailure() }
        }))
        let interaction = MacInteraction(search: Search(source: { CatalogFeed().stream() }, typingGap: .zero),
                                         collection: Task { store }, confirmationDuration: .zero)
        let invocation = interaction.presentBar()
        defer { interaction.dismiss(invocation, reason: .outsideClick) }
        let editor = try await captureEditor()
        editor.insertText(prefix, replacementRange: none)
        editor.insertText("original", replacementRange: none)
        editor.keyDown(with: try returnKey())
        try await eventually { interaction.captureMessage != nil }
        editor.insertText("edited", replacementRange: NSRange(location: 0, length: 8))
        editor.keyDown(with: try returnKey())
        try await eventually { interaction.currentInvocation == nil }
        let records = try await store.read(.allRecords, in: store.generation)
        #expect(records.notes.count + records.tasks.count == 1)
        #expect(records.notes.first?.body == "edited" || records.tasks.first?.title == "edited")
        await store.close()
    }

    @Test(arguments: ["-", "["])
    func anOldConfirmationCannotDismissOrAlterANewerInvocation(prefix: String) async throws {
        let fixture = try TemporaryFixture()
        let store = try await CollectionStore.open(fixture.location)
        let interaction = MacInteraction(search: Search(source: { CatalogFeed().stream() }, typingGap: .zero),
                                         collection: Task { store }, confirmationDuration: .milliseconds(80))
        let old = interaction.presentBar()
        let editor = try await captureEditor()
        editor.insertText(prefix, replacementRange: none)
        editor.insertText("saved", replacementRange: none)
        editor.keyDown(with: try returnKey())
        try await eventually { interaction.modeLabelText?.hasPrefix("Saved") == true }
        interaction.dismiss(old, reason: .outsideClick)
        let next = interaction.presentBar()
        defer { interaction.dismiss(next, reason: .outsideClick) }
        editor.insertText(prefix, replacementRange: none)
        editor.insertText("new capture", replacementRange: none)
        interaction.dismiss(old, reason: .saved)
        try await Task.sleep(for: .milliseconds(120))
        #expect(interaction.currentInvocation == next && next != old)
        #expect(editor.string == "new capture" && interaction.captureMessage == nil)
        #expect(editor.isEditable)
        let records = try await store.read(.allRecords, in: store.generation)
        #expect(records.notes.count + records.tasks.count == 1)
        await store.close()
    }

    private func captureEditor() async throws -> NSTextView {
        try await eventually { NSApp.keyWindow?.title == "Hana Search" && NSApp.keyWindow?.firstResponder is NSTextView }
        return try #require(NSApp.keyWindow?.firstResponder as? NSTextView)
    }
}

@MainActor
private final class CaptureFocusDestination {
    let panel = CaptureKeyPanel(contentRect: NSRect(x: 160, y: 160, width: 300, height: 80),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
    let editor = NSTextView(frame: NSRect(x: 10, y: 10, width: 280, height: 60))

    init() {
        panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.contentView?.addSubview(editor)
    }

    func focus() {
        panel.makeKeyAndOrderFront(nil)
        panel.makeFirstResponder(editor)
    }
}

private final class CaptureKeyPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}
