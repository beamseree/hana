import Foundation
import Testing
@testable import Hana

/// Prefix provenance and mode rules through Capture Session's interface. Native
/// editing tests separately prove the editor reports each insertion's provenance.
struct CaptureSessionTests {
    @Test func typedDashOnAnEmptyBufferEntersNoteWithoutBecomingText() {
        var session = CaptureSession()
        let effects = session.handle(.insert("-", replacing: NSRange(location: 0, length: 0), provenance: .typed))
        #expect(effects == [.consumeInsertion, .enterMode(.note)])
        #expect(session.state.mode == .note)
        #expect(session.state.text == "")
        #expect(session.state.selection == NSRange(location: 0, length: 0))
    }

    @Test func typedDashBeforeExistingSearchTextKeepsTheTextAndSelection() {
        var session = CaptureSession()
        _ = session.handle(.edited(text: "milk บันทึก", selection: NSRange(location: 0, length: 0)))
        let effects = session.handle(.insert("-", replacing: NSRange(location: 0, length: 0), provenance: .typed))
        #expect(effects == [.consumeInsertion, .enterMode(.note)])
        #expect(session.state == .init(mode: .note, text: "milk บันทึก", selection: NSRange(location: 0, length: 0)))
    }

    @Test func typedDashAfterTheStartIsLiteralText() {
        var session = CaptureSession()
        _ = session.handle(.edited(text: "e", selection: NSRange(location: 1, length: 0)))
        let effects = session.handle(.insert("-", replacing: NSRange(location: 1, length: 0), provenance: .typed))
        #expect(effects.isEmpty)
        #expect(session.state == .init(mode: .search, text: "e-", selection: NSRange(location: 2, length: 0)))
    }

    @Test func typedDashReplacingASelectionAtTheStartIsLiteralText() {
        var session = CaptureSession()
        _ = session.handle(.edited(text: "todo", selection: NSRange(location: 0, length: 2)))
        let effects = session.handle(.insert("-", replacing: NSRange(location: 0, length: 2), provenance: .typed))
        #expect(effects.isEmpty)
        #expect(session.state == .init(mode: .search, text: "-do", selection: NSRange(location: 1, length: 0)))
    }

    @Test(arguments: [CaptureSession.Provenance.paste, .drop, .undo, .redo, .programmatic, .composition, .compositionCommit])
    func untypedDashAtTheStartIsLiteralText(provenance: CaptureSession.Provenance) {
        var session = CaptureSession()
        let effects = session.handle(.insert("-", replacing: NSRange(location: 0, length: 0), provenance: provenance))
        #expect(effects.isEmpty)
        #expect(session.state == .init(mode: .search, text: "-", selection: NSRange(location: 1, length: 0)))
    }

    @Test func typedDashInNoteIsLiteralText() {
        var session = CaptureSession()
        _ = session.handle(.insert("-", replacing: NSRange(location: 0, length: 0), provenance: .typed))
        let effects = session.handle(.insert("-", replacing: NSRange(location: 0, length: 0), provenance: .typed))
        #expect(effects.isEmpty)
        #expect(session.state == .init(mode: .note, text: "-", selection: NSRange(location: 1, length: 0)))
    }

    @Test(arguments: [CaptureSession.Event.invoked, .dismissed])
    func invocationAndDismissalDiscardTheCaptureAndArmPrefixes(event: CaptureSession.Event) {
        var session = CaptureSession()
        _ = session.handle(.insert("-", replacing: NSRange(location: 0, length: 0), provenance: .typed))
        _ = session.handle(.edited(text: "unsaved", selection: NSRange(location: 7, length: 0)))
        #expect(session.handle(event).isEmpty)
        #expect(session.state == .init(mode: .search, text: "", selection: NSRange(location: 0, length: 0), prefixesArmed: true))
        let effects = session.handle(.insert("-", replacing: NSRange(location: 0, length: 0), provenance: .typed))
        #expect(effects == [.consumeInsertion, .enterMode(.note)])
    }
}

/// Submission: Enter in Note freezes the text and issues one save under the
/// session's operation; the outcome confirms or returns to editing.
struct CaptureSubmissionTests {
    private func note(_ text: String) -> CaptureSession {
        var session = CaptureSession()
        _ = session.handle(.insert("-", replacing: NSRange(location: 0, length: 0), provenance: .typed))
        _ = session.handle(.edited(text: text, selection: NSRange(location: (text as NSString).length, length: 0)))
        return session
    }

    @Test func submittingANoteSavesItsExactTextOnceUnderTheSessionOperation() {
        let text = "  # Groceries\n\n- milk บันทึก  \n"
        var session = note(text)
        let operation = session.operation
        #expect(session.handle(.submit) == [.save(operation: operation, body: text)])
        #expect(session.state.phase == .saving)
        #expect(session.handle(.submit).isEmpty)
        #expect(session.state.phase == .saving)
    }

    @Test(arguments: ["", " ", "\n\t \u{2028}\r\n"])
    func aWhitespaceOnlyNoteIsRefusedWithAnExplanationAndNoSave(text: String) {
        var session = note(text)
        #expect(session.handle(.submit).isEmpty)
        #expect(session.state.phase == .editing && session.state.notice == .blank)
        #expect(session.state.mode == .note && session.state.text == text)
        // Writing something clears the explanation.
        _ = session.handle(.edited(text: text + "x", selection: NSRange(location: 0, length: 0)))
        #expect(session.state.notice == nil)
    }

    @Test func submittedTextIsFrozenWhileSaving() {
        var session = note("draft")
        let operation = session.operation
        _ = session.handle(.submit)
        #expect(session.handle(.insert("x", replacing: NSRange(location: 5, length: 0), provenance: .typed)) == [.consumeInsertion])
        _ = session.handle(.edited(text: "changed", selection: NSRange(location: 7, length: 0)))
        #expect(session.state.text == "draft")
        #expect(session.handle(.saved) == [.confirmSaved])
        #expect(session.state.phase == .saved)
        // Keystrokes during the confirmation never reach the saved capture.
        #expect(session.handle(.insert("y", replacing: NSRange(location: 0, length: 0), provenance: .typed)) == [.consumeInsertion])
        #expect(session.handle(.submit).isEmpty)
        #expect(session.state.text == "draft" && session.operation == operation)
    }

    @Test(arguments: [CaptureSession.Notice.failed, .collectionUnavailable])
    func aFailedSaveKeepsTheTextAndModeEditableWithAnExplanation(notice: CaptureSession.Notice) {
        var session = note("keep me")
        let operation = session.operation
        _ = session.handle(.submit)
        #expect(session.handle(.saveFailed(notice)).isEmpty)
        #expect(session.state == .init(mode: .note, text: "keep me", selection: NSRange(location: 7, length: 0),
                                       phase: .editing, notice: notice))
        _ = session.handle(.insert("!", replacing: NSRange(location: 7, length: 0), provenance: .typed))
        #expect(session.state.text == "keep me!" && session.state.notice == nil)
        // Enter again submits under the same operation, so a save that did
        // commit can never be duplicated.
        #expect(session.handle(.submit) == [.save(operation: operation, body: "keep me!")])
    }

    @Test func outcomesOutsideASaveChangeNothing() {
        var session = note("text")
        #expect(session.handle(.saved).isEmpty)
        #expect(session.handle(.saveFailed(.failed)).isEmpty)
        #expect(session.state.phase == .editing && session.state.notice == nil)
    }

    @Test func searchEnterIsNotACapture() {
        var session = CaptureSession()
        _ = session.handle(.edited(text: "milk", selection: NSRange(location: 4, length: 0)))
        #expect(session.handle(.submit).isEmpty)
        #expect(session.state.phase == .editing)
    }

    @Test func eachInvocationHasANewOperation() {
        var session = CaptureSession()
        let first = session.operation
        _ = session.handle(.dismissed)
        let second = session.operation
        _ = session.handle(.invoked)
        #expect(Set([first, second, session.operation]).count == 3)
    }
}
