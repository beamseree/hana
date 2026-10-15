import AppKit

/// Search's thin thumb, with AppKit retaining native scrolling and dragging.
@MainActor
final class NoteScroller: NSScroller {
    override class func scrollerWidth(for controlSize: NSControl.ControlSize,
                                     scrollerStyle: NSScroller.Style) -> CGFloat {
        BarStyle.cardPadding
    }

    override func draw(_ dirtyRect: NSRect) {
        guard isEnabled, knobProportion < 1 else { return }
        drawKnob()
    }

    override func drawKnob() {
        let knob = rect(for: .knob)
        let thumb = NSRect(x: bounds.midX - BarStyle.scrollThumbWidth / 2, y: knob.minY,
                           width: BarStyle.scrollThumbWidth, height: knob.height)
        NSColor.black.withAlphaComponent(BarStyle.scrollThumbOpacity).setFill()
        NSBezierPath(roundedRect: thumb, xRadius: BarStyle.scrollThumbWidth / 2,
                     yRadius: BarStyle.scrollThumbWidth / 2).fill()
    }
}
