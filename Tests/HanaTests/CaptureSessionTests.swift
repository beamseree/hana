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

/// Returning from a capture to Search with Backspace.
struct CaptureSessionReturnTests {
    private let start = NSRange(location: 0, length: 0)

    private func noteSession(text: String, selection: NSRange) -> CaptureSession {
        var session = CaptureSession()
        _ = session.handle(.insert("-", replacing: start, provenance: .typed))
        _ = session.handle(.edited(text: text, selection: selection))
        return session
    }

    @Test func backspaceAtTheStartOfNoteReturnsToSearchKeepingTheBufferAndSelection() {
        var session = noteSession(text: "one\ntwo", selection: start)
        let effects = session.handle(.deleteBackward)
        #expect(effects == [.enterMode(.search)])
        #expect(session.state == .init(mode: .search, text: "one\ntwo", selection: start, prefixesArmed: false))
    }

    @Test(arguments: [NSRange(location: 3, length: 0), NSRange(location: 0, length: 3), NSRange(location: 1, length: 2)])
    func backspaceWithTextBeforeTheCursorOrASelectionIsOrdinaryDeletion(selection: NSRange) {
        var session = noteSession(text: "one", selection: selection)
        #expect(session.handle(.deleteBackward).isEmpty)
        #expect(session.state == .init(mode: .note, text: "one", selection: selection))
        // The editor deletes and reports the result.
        _ = session.handle(.edited(text: "on", selection: NSRange(location: 2, length: 0)))
        #expect(session.state == .init(mode: .note, text: "on", selection: NSRange(location: 2, length: 0)))
    }

    @Test func backspaceAtTheStartOfSearchDoesNotDisarmPrefixes() {
        var session = CaptureSession()
        _ = session.handle(.edited(text: "milk", selection: start))
        #expect(session.handle(.deleteBackward).isEmpty)
        #expect(session.state == .init(mode: .search, text: "milk", selection: start, prefixesArmed: true))
    }

    @Test func typedDashAfterReturningToSearchIsLiteralText() {
        var session = noteSession(text: "milk", selection: start)
        _ = session.handle(.deleteBackward)
        let effects = session.handle(.insert("-", replacing: start, provenance: .typed))
        #expect(effects.isEmpty)
        #expect(session.state == .init(mode: .search, text: "-milk", selection: NSRange(location: 1, length: 0), prefixesArmed: false))
    }

    @Test func returningFromAnEmptyNoteArmsPrefixesSoATypedDashEntersNoteAgain() {
        var session = noteSession(text: "", selection: start)
        #expect(session.handle(.deleteBackward) == [.enterMode(.search)])
        #expect(session.state == .init(mode: .search, text: "", selection: start, prefixesArmed: true))
        #expect(session.handle(.insert("-", replacing: start, provenance: .typed)) == [.consumeInsertion, .enterMode(.note)])
        #expect(session.state == .init(mode: .note, text: "", selection: start))
    }

    @Test func clearingTheKeptTextAfterReturningArmsPrefixesAgain() {
        var session = noteSession(text: "milk", selection: start)
        _ = session.handle(.deleteBackward)
        _ = session.handle(.edited(text: "", selection: start))
        #expect(session.state == .init(mode: .search, text: "", selection: start, prefixesArmed: true))
        #expect(session.handle(.insert("-", replacing: start, provenance: .typed)) == [.consumeInsertion, .enterMode(.note)])
        #expect(session.state == .init(mode: .note, text: "", selection: start))
    }

    @Test func deletingTheKeptTextAfterReturningArmsPrefixesAgain() {
        // Ordinary deletion and cut ask about an empty insertion before the editor syncs.
        var session = noteSession(text: "milk", selection: start)
        _ = session.handle(.deleteBackward)
        _ = session.handle(.insert("", replacing: NSRange(location: 0, length: 4), provenance: .programmatic))
        #expect(session.state == .init(mode: .search, text: "", selection: start, prefixesArmed: true))
        #expect(session.handle(.insert("[", replacing: start, provenance: .typed)) == [.consumeInsertion, .enterMode(.task)])
    }

    @Test(arguments: [CaptureSession.Provenance.paste, .drop, .undo, .redo, .programmatic, .composition, .compositionCommit])
    func aPastedOrOtherwiseUntypedDashIntoEmptySearchAfterAReturnStaysLiteral(provenance: CaptureSession.Provenance) {
        var session = noteSession(text: "", selection: start)
        _ = session.handle(.deleteBackward)
        #expect(session.handle(.insert("-", replacing: start, provenance: provenance)).isEmpty)
        #expect(session.state == .init(mode: .search, text: "-", selection: NSRange(location: 1, length: 0), prefixesArmed: true))
    }

    @Test(arguments: [CaptureSession.Event.invoked, .dismissed])
    func theNextInvocationArmsPrefixesAgain(event: CaptureSession.Event) {
        var session = noteSession(text: "milk", selection: start)
        _ = session.handle(.deleteBackward)
        _ = session.handle(event)
        #expect(session.state.prefixesArmed)
        #expect(session.handle(.insert("-", replacing: start, provenance: .typed)) == [.consumeInsertion, .enterMode(.note)])
    }

    @Test func backspaceAtTheStartWhileSavingKeepsTheCaptureInNote() {
        var session = noteSession(text: "draft", selection: start)
        _ = session.handle(.submit)
        #expect(session.handle(.deleteBackward).isEmpty)
        #expect(session.state.mode == .note && session.state.phase == .saving)
    }

    @Test func returningToSearchLeavesTheNoteNoticeBehind() {
        var session = noteSession(text: " ", selection: start)
        _ = session.handle(.submit)
        #expect(session.state.notice == .blank)
        #expect(session.handle(.deleteBackward) == [.enterMode(.search)])
        #expect(session.state == .init(mode: .search, text: " ", selection: start, prefixesArmed: false))
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
        #expect(session.handle(.submit) == [.saveNote(operation: operation, body: text)])
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
        // A changed payload cannot reuse a receipt for the failed attempt.
        #expect(session.operation != operation)
        #expect(session.handle(.submit) == [.saveNote(operation: session.operation, body: "keep me!")])
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

/// Task mode: the `[` prefix, the single-line rule and the Inbox/Today destination.
struct CaptureTaskTests {
    private let start = NSRange(location: 0, length: 0)

    private func task(_ text: String) -> CaptureSession {
        var session = CaptureSession()
        _ = session.handle(.insert("[", replacing: start, provenance: .typed))
        _ = session.handle(.edited(text: text, selection: NSRange(location: (text as NSString).length, length: 0)))
        return session
    }

    @Test func typedBracketOnAnEmptyBufferEntersTaskWithoutBecomingText() {
        var session = CaptureSession()
        #expect(session.handle(.insert("[", replacing: start, provenance: .typed)) == [.consumeInsertion, .enterMode(.task)])
        #expect(session.state == .init(mode: .task, text: "", selection: start))
    }

    @Test func typedBracketBeforeExistingSearchTextKeepsTheTextAndSelection() {
        var session = CaptureSession()
        _ = session.handle(.edited(text: "call mum บ้าน", selection: start))
        #expect(session.handle(.insert("[", replacing: start, provenance: .typed)) == [.consumeInsertion, .enterMode(.task)])
        #expect(session.state == .init(mode: .task, text: "call mum บ้าน", selection: start))
    }

    @Test func typedBracketAfterTheStartIsLiteralText() {
        var session = CaptureSession()
        _ = session.handle(.edited(text: "x", selection: NSRange(location: 1, length: 0)))
        #expect(session.handle(.insert("[", replacing: NSRange(location: 1, length: 0), provenance: .typed)).isEmpty)
        #expect(session.state == .init(mode: .search, text: "x[", selection: NSRange(location: 2, length: 0)))
    }

    @Test func typedBracketReplacingASelectionAtTheStartIsLiteralText() {
        var session = CaptureSession()
        _ = session.handle(.edited(text: "draft", selection: NSRange(location: 0, length: 2)))
        #expect(session.handle(.insert("[", replacing: NSRange(location: 0, length: 2), provenance: .typed)).isEmpty)
        #expect(session.state == .init(mode: .search, text: "[aft", selection: NSRange(location: 1, length: 0)))
    }

    @Test(arguments: [CaptureSession.Provenance.paste, .drop, .undo, .redo, .programmatic, .composition, .compositionCommit])
    func untypedBracketAtTheStartIsLiteralText(provenance: CaptureSession.Provenance) {
        var session = CaptureSession()
        #expect(session.handle(.insert("[", replacing: start, provenance: provenance)).isEmpty)
        #expect(session.state == .init(mode: .search, text: "[", selection: NSRange(location: 1, length: 0)))
    }

    @Test(arguments: ["-", "["])
    func typedPrefixesInTaskAreLiteralText(prefix: String) {
        var session = task("")
        #expect(session.handle(.insert(prefix, replacing: start, provenance: .typed)).isEmpty)
        #expect(session.state == .init(mode: .task, text: prefix, selection: NSRange(location: 1, length: 0)))
    }

    @Test(arguments: ["one\rtwo", "one\ntwo", "one\r\ntwo", "one\u{2028}two", "one\u{2029}two", "trailing\n"])
    func switchingToTaskWithMultilineTextIsRefusedAndChangesNothing(text: String) {
        var session = CaptureSession()
        let selection = NSRange(location: 0, length: 0)
        _ = session.handle(.edited(text: text, selection: selection))
        // Consumed, so the bracket is neither text nor an undo step.
        #expect(session.handle(.insert("[", replacing: start, provenance: .typed)) == [.consumeInsertion])
        #expect(session.state == .init(mode: .search, text: text, selection: selection, notice: .multilineTask))
        // Editing clears the explanation; prefixes stay armed.
        _ = session.handle(.edited(text: "one", selection: start))
        #expect(session.state.notice == nil)
        #expect(session.handle(.insert("[", replacing: start, provenance: .typed)) == [.consumeInsertion, .enterMode(.task)])
    }

    @Test func aLongSingleLineThatSoftWrapsEntersTask() {
        var session = CaptureSession()
        let text = String(repeating: "a long title that wraps ", count: 40)
        _ = session.handle(.edited(text: text, selection: start))
        #expect(session.handle(.insert("[", replacing: start, provenance: .typed)) == [.consumeInsertion, .enterMode(.task)])
        #expect(session.state.text == text)
    }

    @Test(arguments: [CaptureSession.Provenance.paste, .drop, .programmatic, .typed],
          ["a\rb", "a\nb", "a\r\nb", "a\u{2028}b", "a\u{2029}b", "\n"])
    func aMultilineInsertionInTaskIsRefusedWhole(provenance: CaptureSession.Provenance, pasted: String) {
        var session = task("buy ")
        let selection = NSRange(location: 4, length: 0)
        #expect(session.handle(.insert(pasted, replacing: selection, provenance: provenance)) == [.consumeInsertion])
        #expect(session.state == .init(mode: .task, text: "buy ", selection: selection, notice: .multilineTask))
        // A single line pastes as it is, tabs included, and clears the explanation.
        #expect(session.handle(.insert("milk\tx", replacing: selection, provenance: .paste)).isEmpty)
        #expect(session.state == .init(mode: .task, text: "buy milk\tx", selection: NSRange(location: 10, length: 0)))
    }

    @Test func aMultilineInsertionInNoteIsText() {
        var session = CaptureSession()
        _ = session.handle(.insert("-", replacing: start, provenance: .typed))
        #expect(session.handle(.insert("a\r\nb", replacing: start, provenance: .paste)).isEmpty)
        #expect(session.state.text == "a\r\nb")
    }

    @Test func theDestinationDefaultsToInboxAndTabTogglesItWithoutEnteringText() {
        var session = task("call mum")
        #expect(session.state.destination == .inbox)
        #expect(session.handle(.tab) == [.consumeInsertion])
        #expect(session.state.destination == .today && session.state.text == "call mum")
        #expect(session.handle(.tab) == [.consumeInsertion])
        #expect(session.state.destination == .inbox)
    }

    @Test func choosingADestinationSelectsIt() {
        var session = task("call mum")
        _ = session.handle(.chooseDestination(.today))
        #expect(session.state.destination == .today)
        _ = session.handle(.chooseDestination(.today))
        #expect(session.state.destination == .today)
        _ = session.handle(.chooseDestination(.inbox))
        #expect(session.state.destination == .inbox)
    }

    @Test func tabOutsideTaskIsOrdinaryInputAndKeepsTheDestination() {
        var session = CaptureSession()
        #expect(session.handle(.tab).isEmpty)
        _ = session.handle(.chooseDestination(.today))
        _ = session.handle(.insert("-", replacing: start, provenance: .typed))
        #expect(session.handle(.tab).isEmpty)
        #expect(session.state.destination == .inbox)
    }

    @Test(arguments: [CaptureSession.Event.invoked, .dismissed])
    func aNewInvocationResetsTheDestinationToInbox(event: CaptureSession.Event) {
        var session = task("call mum")
        _ = session.handle(.tab)
        _ = session.handle(event)
        #expect(session.state.destination == .inbox)
        _ = session.handle(.insert("[", replacing: start, provenance: .typed))
        #expect(session.state.destination == .inbox)
    }

    @Test func theDestinationIsFrozenWhileSaving() {
        var session = task("call mum")
        _ = session.handle(.submit)
        #expect(session.handle(.tab) == [.consumeInsertion])
        _ = session.handle(.chooseDestination(.today))
        #expect(session.state.destination == .inbox)
    }

    @Test func shiftEnterInTaskDoesNothing() {
        var session = task("call mum")
        let before = session.state
        #expect(session.handle(.newline) == [.consumeInsertion])
        #expect(session.state == before)
    }

    @Test func shiftEnterInNoteIsAnOrdinaryLineBreak() {
        var session = CaptureSession()
        _ = session.handle(.insert("-", replacing: start, provenance: .typed))
        #expect(session.handle(.newline).isEmpty)
    }

    @Test(arguments: [TaskPlacement.inbox, .today])
    func submittingATaskSavesItsExactTitleToTheDestinationOnce(destination: TaskPlacement) {
        let title = "  call mum บ้าน\t[x] "
        var session = task(title)
        _ = session.handle(.chooseDestination(destination))
        let operation = session.operation
        #expect(session.handle(.submit) == [.saveTask(operation: operation, title: title, placement: destination)])
        #expect(session.state.phase == .saving)
        #expect(session.handle(.submit).isEmpty)
        #expect(session.handle(.saved) == [.confirmSaved])
        #expect(session.state.destination == destination && session.state.text == title)
    }

    @Test(arguments: ["", " ", "\t \u{00A0}"])
    func aWhitespaceOnlyTitleIsRefusedWithAnExplanationAndNoSave(title: String) {
        var session = task(title)
        #expect(session.handle(.submit).isEmpty)
        #expect(session.state.phase == .editing && session.state.notice == .blank)
        #expect(session.state.mode == .task && session.state.text == title)
    }

    @Test func aTitleThatBecameMultilineOutsideAnInsertionIsRefusedBeforeAnySave() {
        // Undo can restore earlier Search text without asking the session.
        var session = task("one")
        _ = session.handle(.edited(text: "one\ntwo", selection: NSRange(location: 7, length: 0)))
        #expect(session.handle(.submit).isEmpty)
        #expect(session.state.phase == .editing && session.state.notice == .multilineTask)
        #expect(session.state.text == "one\ntwo")
    }

    @Test func enteringNoteAfterARefusedSwitchLeavesTheTaskExplanationBehind() {
        var session = CaptureSession()
        _ = session.handle(.edited(text: "one\ntwo", selection: start))
        _ = session.handle(.insert("[", replacing: start, provenance: .typed))
        #expect(session.state.notice == .multilineTask)
        #expect(session.handle(.insert("-", replacing: start, provenance: .typed)) == [.consumeInsertion, .enterMode(.note)])
        #expect(session.state == .init(mode: .note, text: "one\ntwo", selection: start))
    }

    @Test func typedBracketAfterReturningAndClearingTheTextEntersTaskAgain() {
        var session = task("milk")
        _ = session.handle(.edited(text: "milk", selection: start))
        _ = session.handle(.deleteBackward)
        _ = session.handle(.edited(text: "", selection: start))
        #expect(session.handle(.insert("[", replacing: start, provenance: .typed)) == [.consumeInsertion, .enterMode(.task)])
        #expect(session.state == .init(mode: .task, text: "", selection: start))
    }

    @Test func returningFromAnEmptyTaskArmsPrefixesSoATypedBracketEntersTaskAgain() {
        var session = task("")
        #expect(session.handle(.deleteBackward) == [.enterMode(.search)])
        #expect(session.handle(.insert("[", replacing: start, provenance: .typed)) == [.consumeInsertion, .enterMode(.task)])
        #expect(session.state == .init(mode: .task, text: "", selection: start))
    }

    @Test(arguments: [CaptureSession.Event.invoked, .dismissed])
    func theNextInvocationArmsTheBracketAgain(event: CaptureSession.Event) {
        var session = task("milk")
        _ = session.handle(.edited(text: "milk", selection: start))
        _ = session.handle(.deleteBackward)
        _ = session.handle(event)
        #expect(session.handle(.insert("[", replacing: start, provenance: .typed)) == [.consumeInsertion, .enterMode(.task)])
    }

    @Test func typedBracketAfterReturningToSearchIsLiteralText() {
        var session = task("milk")
        _ = session.handle(.edited(text: "milk", selection: start))
        #expect(session.handle(.deleteBackward) == [.enterMode(.search)])
        #expect(session.handle(.insert("[", replacing: start, provenance: .typed)).isEmpty)
        #expect(session.state == .init(mode: .search, text: "[milk", selection: NSRange(location: 1, length: 0), prefixesArmed: false))
    }
}

/// Capture suggestions: chosen from Search's list, never automatic.
struct CaptureSuggestionTests {
    private let start = NSRange(location: 0, length: 0)

    @Test(arguments: [(CaptureSession.Suggestion.note, CaptureSession.Mode.note), (.task, .task)])
    func choosingASuggestionEntersItsModeKeepingTheExactTextAndSelectionWithoutSaving(
        suggestion: CaptureSession.Suggestion, mode: CaptureSession.Mode
    ) {
        var session = CaptureSession()
        let selection = NSRange(location: 2, length: 3)
        _ = session.handle(.edited(text: "  call mum บ้าน ", selection: selection))
        #expect(session.handle(.chooseSuggestion(suggestion)) == [.enterMode(mode)])
        #expect(session.state == .init(mode: mode, text: "  call mum บ้าน ", selection: selection))
    }

    @Test(arguments: ["one\ntwo", "one\r\ntwo", "one\u{2029}two", "trailing\n"])
    func choosingNewTaskWithMultilineTextExplainsAndStaysInSearch(text: String) {
        var session = CaptureSession()
        _ = session.handle(.edited(text: text, selection: start))
        #expect(session.handle(.chooseSuggestion(.task)).isEmpty)
        #expect(session.state == .init(mode: .search, text: text, selection: start, notice: .multilineTask))
        // New note keeps every line and leaves the explanation behind.
        #expect(session.handle(.chooseSuggestion(.note)) == [.enterMode(.note)])
        #expect(session.state == .init(mode: .note, text: text, selection: start))
    }

    @Test(arguments: [true, false])
    func choosingASuggestionLeavesPrefixArmingAsItWas(armed: Bool) {
        var session = CaptureSession()
        _ = session.handle(.edited(text: "milk", selection: start))
        if !armed {
            _ = session.handle(.insert("-", replacing: start, provenance: .typed))
            _ = session.handle(.deleteBackward)
        }
        #expect(session.state.prefixesArmed == armed)
        _ = session.handle(.chooseSuggestion(.note))
        #expect(session.state.prefixesArmed == armed)
    }

    @Test func aSuggestionOutsideSearchChangesNothing() {
        var session = CaptureSession()
        _ = session.handle(.insert("-", replacing: start, provenance: .typed))
        _ = session.handle(.edited(text: "note", selection: start))
        #expect(session.handle(.chooseSuggestion(.task)).isEmpty)
        #expect(session.state == .init(mode: .note, text: "note", selection: start))
    }
}
