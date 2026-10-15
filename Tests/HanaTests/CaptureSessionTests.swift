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

    @Test func typedDashAfterReturningAndClearingTheTextIsLiteralText() {
        var session = noteSession(text: "milk", selection: start)
        _ = session.handle(.deleteBackward)
        _ = session.handle(.edited(text: "", selection: start))
        let effects = session.handle(.insert("-", replacing: start, provenance: .typed))
        #expect(effects.isEmpty)
        #expect(session.state == .init(mode: .search, text: "-", selection: NSRange(location: 1, length: 0), prefixesArmed: false))
    }

    @Test(arguments: [CaptureSession.Event.invoked, .dismissed])
    func theNextInvocationArmsPrefixesAgain(event: CaptureSession.Event) {
        var session = noteSession(text: "milk", selection: start)
        _ = session.handle(.deleteBackward)
        _ = session.handle(event)
        #expect(session.state.prefixesArmed)
        #expect(session.handle(.insert("-", replacing: start, provenance: .typed)) == [.consumeInsertion, .enterMode(.note)])
    }
}
