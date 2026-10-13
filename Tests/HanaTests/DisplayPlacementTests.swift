import Foundation
import Testing
@testable import Hana

// The geometry operation of Mac Interaction needs no application, windows,
// event monitors, or shortcut registration.
struct DisplayPlacementTests {
    let screens: [MacInteraction.Display] = [
        .init(frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
              visibleFrame: CGRect(x: 0, y: 30, width: 1440, height: 845)),
        .init(frame: CGRect(x: -1920, y: 0, width: 1920, height: 1080),
              visibleFrame: CGRect(x: -1920, y: 40, width: 1920, height: 1015))
    ]

    @Test func ownedFocusedWindowWinsOverPointerOnAnotherDisplay() throws {
        let placement = try #require(MacInteraction.placement(
            displays: screens, pointer: CGPoint(x: 100, y: 100),
            focus: .owned(CGRect(x: -1500, y: 100, width: 800, height: 600))))
        #expect(placement.source == "owned")
        #expect(placement.frame(height: 64) == CGRect(x: -1290, y: 891, width: 660, height: 64))
    }

    @Test func accessibilityCoordinatesMapAboveThePrimaryDisplay() throws {
        let above = MacInteraction.Display(frame: CGRect(x: 0, y: 900, width: 1600, height: 1000),
                                           visibleFrame: CGRect(x: 0, y: 900, width: 1600, height: 975))
        let placement = try #require(MacInteraction.placement(
            displays: screens + [above], pointer: CGPoint(x: -100, y: 100),
            focus: .accessibility(CGRect(x: 200, y: -800, width: 900, height: 600))))
        #expect(placement.source == "accessibility")
        #expect(placement.frame(height: 64) == CGRect(x: 470, y: 1711, width: 660, height: 64))
    }

    @Test func invalidFocusedGeometryFallsBackToCapturedPointer() throws {
        for focus in [MacInteraction.WindowFocus.unavailable,
                      .owned(CGRect(x: 5000, y: 5000, width: 400, height: 300)),
                      .accessibility(CGRect(x: CGFloat.nan, y: 0, width: 800, height: 600))] {
            let placement = try #require(MacInteraction.placement(
                displays: screens, pointer: CGPoint(x: -100, y: 100), focus: focus))
            #expect(placement.source == "pointer")
            #expect(placement.frame(height: 64).minX == -1290)
        }
    }

    @Test func expansionAndContractionKeepInputTopUnlessVisibleBoundsRequireMovement() throws {
        let placement = try #require(MacInteraction.placement(displays: screens,
            pointer: CGPoint(x: 100, y: 100), focus: .unavailable))
        #expect(placement.frame(height: 64).maxY == 775)
        #expect(placement.frame(height: 484).maxY == 775)
        #expect(placement.frame(height: 1000) == CGRect(x: 390, y: 30, width: 660, height: 845))
        #expect(placement.frame(height: 64).maxY == 775)
        let small = MacInteraction.Display(frame: CGRect(x: -500, y: -300, width: 400, height: 200),
            visibleFrame: CGRect(x: -500, y: -280, width: 400, height: 150))
        let compact = try #require(MacInteraction.placement(displays: [small], pointer: .zero, focus: .unavailable))
        #expect(compact.frame(height: 484) == small.visibleFrame)
        #expect(MacInteraction.placement(displays: [], pointer: .zero, focus: .unavailable) == nil)
    }

    @Test func failedOrUnresponsiveAccessibilityUsesCapturedPointer() async throws {
        let failed = await MacInteraction.focusedWindowWithinDeadline { nil }
        #expect(failed == nil)
        let clock = ContinuousClock()
        let start = clock.now
        let late = await MacInteraction.focusedWindowWithinDeadline {
            // Deliberately ignores cancellation, like a foreign IPC request.
            try? await Task.sleep(for: .seconds(2))
            return CGRect(x: 100, y: 100, width: 800, height: 600)
        }
        #expect(late == nil)
        #expect(start.duration(to: clock.now) < .seconds(1))
        let placement = try #require(MacInteraction.placement(displays: screens,
            pointer: CGPoint(x: -100, y: 100), focus: late.map(MacInteraction.WindowFocus.accessibility) ?? .unavailable))
        #expect(placement.frame(height: 64).minX == -1290)
    }
}
