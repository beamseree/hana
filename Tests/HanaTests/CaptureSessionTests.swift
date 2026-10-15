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
