import Foundation

/// The bar's capture rules as pure transitions: `handle(event)` updates the
/// state and returns the effects window code performs. No disk or window work.
struct CaptureSession {
    enum Mode: String { case search, note }

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
        /// A new invocation, or a dismissal discarding any unsaved capture.
        case invoked, dismissed
        /// Enter outside composition.
        case submit
        /// The outcome of the save the session requested.
        case saved, saveFailed(Notice)
    }

    enum Effect: Equatable {
        /// The editor drops the insertion: it became the mode label, not text.
        case consumeInsertion
        case enterMode(Mode)
        /// Create the note once, idempotently under `operation`.
        case save(operation: UUID, body: String)
        /// Show the confirmation, then close and return focus.
        case confirmSaved
    }

    /// Editing accepts changes; once submitted, the text is frozen until the
    /// save fails (back to editing) or succeeds (confirmation, then dismissal).
    enum Phase: Equatable { case editing, saving, saved }

    /// Why the capture wasn't saved. The text and mode are always kept.
    enum Notice: Equatable { case blank, collectionUnavailable, failed }

    struct State: Equatable {
        var mode = Mode.search
        var text = ""
        /// UTF-16 range, as the native editor reports it.
        var selection = NSRange(location: 0, length: 0)
        /// Whether a typed prefix at the start of Search selects a mode.
        var prefixesArmed = true
        var phase = Phase.editing
        var notice: Notice?
    }

    private(set) var state = State()
    /// Identifies this invocation's capture to the Store, so every save of it
    /// creates at most one note. Each invocation gets a new one.
    private(set) var operation = UUID()

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
            // Only a deliberately typed `-` replacing an empty selection at the
            // start selects Note; the selection stays put relative to the text.
            if state.mode == .search, state.prefixesArmed, provenance == .typed,
               text == "-", range == NSRange(location: 0, length: 0) {
                state.mode = .note
                return [.consumeInsertion, .enterMode(.note)]
            }
            state.text = (state.text as NSString).replacingCharacters(in: range, with: text)
            if !text.isEmpty || range.length > 0 { state.notice = nil }
            state.selection = NSRange(location: range.location + (text as NSString).length, length: 0)
            return []
        case .deleteBackward:
            // Backspace with nothing before the cursor leaves a capture for
            // Search, keeping every character. Prefixes stay off from then on.
            // Once submitted, the capture stays put until the save settles.
            guard state.mode != .search, state.phase == .editing,
                  state.selection == NSRange(location: 0, length: 0) else { return [] }
            state.mode = .search
            state.prefixesArmed = false
            state.notice = nil
            return [.enterMode(.search)]
        case .edited(let text, let selection):
            guard state.phase == .editing else { return [] }
            if text != state.text { state.notice = nil }
            state.text = text
            state.selection = selection
            return []
        case .invoked, .dismissed:
            state = State()
            operation = UUID()
            return []
        case .submit:
            guard state.mode == .note, state.phase == .editing else { return [] }
            // Refused before any save; other content is saved byte for byte.
            guard Note.isNonblank(state.text) else {
                state.notice = .blank
                return []
            }
            state.phase = .saving
            state.notice = nil
            return [.save(operation: operation, body: state.text)]
        case .saved:
            guard state.phase == .saving else { return [] }
            state.phase = .saved
            return [.confirmSaved]
        case .saveFailed(let notice):
            guard state.phase == .saving else { return [] }
            // The same operation stays: Enter again can never duplicate a save that committed.
            state.phase = .editing
            state.notice = notice
            return []
        }
    }
}
