import AppKit
import Testing
@testable import Hana

// Real AppKit presentation through the agreed module boundary. These checks do
// not claim that macOS routed a physical keystroke or restored a foreign editor.
@Suite(.serialized)
@MainActor
struct MacInteractionTests {
    @Test func reinvocationKeepsTheCurrentSession() {
        _ = NSApplication.shared
        let interaction = MacInteraction()
        let first = interaction.presentBar()
        defer { interaction.dismiss(first, reason: .outsideClick) }
        #expect(interaction.presentBar() == first)
        #expect(interaction.currentInvocation == first)
    }
    @Test func oldDismissalCannotCloseAReopenedBar() {
        _ = NSApplication.shared
        let interaction = MacInteraction()
        let old = interaction.presentBar()
        interaction.dismiss(old, reason: .outsideClick)
        #expect(interaction.currentInvocation == nil)
        let fresh = interaction.presentBar()
        defer { interaction.dismiss(fresh, reason: .outsideClick) }
        #expect(fresh != old)
        interaction.dismiss(old, reason: .escape)
        #expect(interaction.currentInvocation == fresh)
    }
}
