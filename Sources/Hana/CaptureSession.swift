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
        /// A new invocation, or a dismissal discarding any unsaved capture.
        case invoked, dismissed
    }

    enum Effect: Equatable {
        /// The editor drops the insertion: it became the mode label, not text.
        case consumeInsertion
        case enterMode(Mode)
    }

    struct State: Equatable {
        var mode = Mode.search
        var text = ""
        /// UTF-16 range, as the native editor reports it.
        var selection = NSRange(location: 0, length: 0)
        /// Whether a typed prefix at the start of Search selects a mode.
        var prefixesArmed = true
    }

    private(set) var state = State()

    mutating func handle(_ event: Event) -> [Effect] {
        switch event {
        case .insert(let text, let range, let provenance):
            // Only a deliberately typed `-` replacing an empty selection at the
            // start selects Note; the selection stays put relative to the text.
            if state.mode == .search, state.prefixesArmed, provenance == .typed,
               text == "-", range == NSRange(location: 0, length: 0) {
                state.mode = .note
                return [.consumeInsertion, .enterMode(.note)]
            }
            state.text = (state.text as NSString).replacingCharacters(in: range, with: text)
            state.selection = NSRange(location: range.location + (text as NSString).length, length: 0)
            return []
        case .edited(let text, let selection):
            state.text = text
            state.selection = selection
            return []
        case .invoked, .dismissed:
            state = State()
            return []
        }
    }
}
