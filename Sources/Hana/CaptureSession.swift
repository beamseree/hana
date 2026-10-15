import Foundation

/// The bar's capture rules as pure transitions: `handle(event)` updates the
/// state and returns the effects window code performs. No disk or window work.
struct CaptureSession {
    enum Mode: String { case search, note, task }

    /// A capture suggestion offered below Search's matches. It changes mode
    /// only when chosen, and never saves.
    enum Suggestion: CaseIterable, Equatable {
        case note, task
        var mode: Mode {
            switch self {
            case .note: .note
            case .task: .task
            }
        }
    }

    /// Where an insertion came from, as identified by the native editor. Only
    /// `typed` can select a mode; anything uncertain is reported as `programmatic`.
    enum Provenance: Equatable {
        /// A direct text-input insertion, outside composition.
        case typed
        /// Marked text changing while an input method composes.
        case composition
        /// Marked text committed by an input method.
        case compositionCommit
        case paste, drop, undo, redo, programmatic
    }

    enum Event: Equatable {
        case insert(String, replacing: NSRange, provenance: Provenance)
        /// The native editor's text and selection after any change it applied.
        case edited(text: String, selection: NSRange)
        /// Backspace, before the editor deletes anything. Without an effect it
        /// is ordinary deletion, which the editor performs and reports as `edited`.
        case deleteBackward
        /// Tab and Shift+Enter outside composition, before the editor inserts
        /// anything. Without an effect the editor inserts the tab or line break.
        case tab, newline
        /// Enter on a capture suggestion selected in Search.
        case chooseSuggestion(Suggestion)
        /// Prototype transitions share the explicit capture and return paths.
        case automaticMode(Mode)
        /// A click on Task's destination selector.
        case chooseDestination(TaskPlacement)
        /// A new invocation, or a dismissal. An in-flight save defers discard.
        case invoked, dismissed
        /// Enter outside composition.
        case submit
        /// The outcome of the save the session requested.
        case saved, saveFailed(Notice)
    }

    enum Effect: Equatable {
        /// The editor drops the insertion: it became the mode label or a
        /// destination change, or Task refused it.
        case consumeInsertion
        case enterMode(Mode)
        /// Create the note once, idempotently under `operation`.
        case saveNote(operation: UUID, body: String)
        /// Create the task once at the top of `placement`, idempotently under `operation`.
        case saveTask(operation: UUID, title: String, placement: TaskPlacement)
        /// Show the confirmation, then close and return focus.
        case confirmSaved
        /// A dismissal requested during the write: close without restoring focus.
        case closeSaved
    }

    /// Editing accepts changes; once submitted, the text is frozen until the
    /// save fails (back to editing) or succeeds (confirmation, then dismissal).
    enum Phase: Equatable { case editing, saving, saved }

    /// Why the capture wasn't saved, or why Task refused text. The text and mode are always kept.
    enum Notice: Equatable {
        case blank, collectionUnavailable, failed
        /// Task titles are one line: a switch to Task or an insertion with a line break was refused whole.
        case multilineTask
    }

    struct State: Equatable {
        var mode = Mode.search
        /// An emptied buffer arms mode prefixes again, however it was emptied.
        var text = "" {
            didSet { if text.isEmpty { prefixesArmed = true } }
        }
        /// UTF-16 range, as the native editor reports it.
        var selection = NSRange(location: 0, length: 0)
        /// Whether a typed mode prefix at the start of Search selects a mode. Off
        /// only after a return to Search kept text, until the buffer is empty.
        var prefixesArmed = true
        /// Where Task saves. Inbox for each invocation until changed.
        var destination = TaskPlacement.inbox
        var phase = Phase.editing
        var notice: Notice?
        var dismissalRequested = false
    }

    /// The typed prefixes that select a capture mode from Search.
    private static let prefixes: [String: Mode] = ["-": .note, "[": .task]

    private(set) var state = State()
    /// Identifies one submitted payload to the Store. Unchanged retries keep
    /// it; editing after a failed attempt starts a new operation.
    private(set) var operation = UUID()
    private var submitted = false

    private mutating func payloadChanged() {
        state.notice = nil
        guard submitted else { return }
        operation = UUID()
        submitted = false
    }

    /// The query Search receives for the buffer: whitespace runs, line breaks
    /// included, become single spaces. The buffer itself is never changed.
    static func searchQuery(for text: String) -> String {
        text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .insert(let text, let range, let provenance):
            // Once submitted, nothing reaches the frozen text.
            guard state.phase == .editing else { return [.consumeInsertion] }
            // Only a deliberately typed `-` or `[` replacing an empty selection at
            // the start selects Note or Task; the selection stays put relative to the text.
            if state.mode == .search, state.prefixesArmed, provenance == .typed,
               let mode = Self.prefixes[text], range == NSRange(location: 0, length: 0) {
                return [.consumeInsertion] + enterCapture(mode)
            }
            // A task title is never silently flattened or cut: a line break refuses the whole insertion.
            if state.mode == .task, TaskItem.isMultiline(text) {
                state.notice = .multilineTask
                return [.consumeInsertion]
            }
            let changed = (state.text as NSString).replacingCharacters(in: range, with: text)
            if !changed.utf8.elementsEqual(state.text.utf8) { payloadChanged() }
            state.text = changed
            if !text.isEmpty || range.length > 0 { state.notice = nil }
            state.selection = NSRange(location: range.location + (text as NSString).length, length: 0)
            return []
        case .deleteBackward:
            // Backspace with nothing before the cursor leaves a capture for
            // Search, keeping every character. Prefixes stay off while kept
            // text remains, so a `-` typed before it stays literal.
            // Once submitted, the capture stays put until the save settles.
            guard state.mode != .search, state.phase == .editing,
                  state.selection == NSRange(location: 0, length: 0) else { return [] }
            return returnToSearch()
        case .automaticMode(let mode):
            guard state.phase == .editing, mode != state.mode else { return [] }
            return mode == .search ? returnToSearch() : enterCapture(mode)
        case .chooseSuggestion(let suggestion):
            guard state.mode == .search, state.phase == .editing else { return [] }
            return enterCapture(suggestion.mode)
        case .tab:
            // A typed Tab never enters a title: it toggles the destination.
            guard state.mode == .task else { return [] }
            if state.phase == .editing {
                payloadChanged()
                state.destination = state.destination == .inbox ? .today : .inbox
            }
            return [.consumeInsertion]
        case .newline:
            // Task titles are one line; Note writes the line break.
            return state.mode == .task ? [.consumeInsertion] : []
        case .chooseDestination(let destination):
            guard state.mode == .task, state.phase == .editing else { return [] }
            if destination != state.destination { payloadChanged() }
            state.destination = destination
            return []
        case .edited(let text, let selection):
            guard state.phase == .editing else { return [] }
            if !text.utf8.elementsEqual(state.text.utf8) {
                payloadChanged()
                state.notice = nil
            }
            state.text = text
            state.selection = selection
            return []
        case .dismissed where state.phase == .saving:
            // The outcome is still unknown. Keep the submitted payload and
            // receipt identity until the write settles; this is not cancellation.
            state.dismissalRequested = true
            return []
        case .invoked, .dismissed:
            state = State()
            operation = UUID()
            submitted = false
            return []
        case .submit:
            guard state.mode != .search, state.phase == .editing else { return [] }
            // Refused before any save; other content is saved byte for byte.
            // Undo can bring back multiline text without an insertion, so check again.
            if state.mode == .task, TaskItem.isMultiline(state.text) {
                state.notice = .multilineTask
                return []
            }
            guard Note.isNonblank(state.text) else {
                state.notice = .blank
                return []
            }
            state.phase = .saving
            submitted = true
            state.notice = nil
            return state.mode == .task
                ? [.saveTask(operation: operation, title: state.text, placement: state.destination)]
                : [.saveNote(operation: operation, body: state.text)]
        case .saved:
            guard state.phase == .saving else { return [] }
            state.phase = .saved
            return state.dismissalRequested ? [.closeSaved] : [.confirmSaved]
        case .saveFailed(let notice):
            guard state.phase == .saving else { return [] }
            // The same operation stays: Enter again can never duplicate a save that committed.
            state.phase = .editing
            state.notice = notice
            return []
        }
    }

    private mutating func returnToSearch() -> [Effect] {
        payloadChanged()
        state.mode = .search
        state.prefixesArmed = state.text.isEmpty
        state.notice = nil
        return [.enterMode(.search)]
    }

    /// Search to Note or Task, by a typed prefix or a chosen suggestion, keeping
    /// the text and selection. Multiline text never becomes a task: it would have
    /// to be flattened or cut, so Search stays with an explanation.
    private mutating func enterCapture(_ mode: Mode) -> [Effect] {
        if mode == .task, TaskItem.isMultiline(state.text) {
            state.notice = .multilineTask
            return []
        }
        payloadChanged()
        state.mode = mode
        state.notice = nil
        return [.enterMode(mode)]
    }
}
