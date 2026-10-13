import Foundation

extension MacInteraction {
    struct Display: Sendable {
        let frame: CGRect
        let visibleFrame: CGRect
    }

    enum WindowFocus: Sendable {
        case owned(CGRect)
        // AX uses a top-left origin on the primary display, in points.
        case accessibility(CGRect)
        case unavailable
    }

    struct Placement: Sendable {
        let visibleFrame: CGRect
        let source: String

        func frame(height: CGFloat) -> CGRect {
            let width = min(660, visibleFrame.width)
            let height = min(height, visibleFrame.height)
            let top = visibleFrame.maxY - 100
            return CGRect(x: visibleFrame.midX - width / 2,
                          y: max(visibleFrame.minY, min(visibleFrame.maxY - height, top - height)),
                          width: width, height: height)
        }
    }

    /// Resolve captured OS geometry without querying the current pointer again.
    nonisolated static func placement(displays: [Display], pointer: CGPoint, focus: WindowFocus) -> Placement? {
        let window: CGRect
        let source: String
        switch focus {
        case .owned(let rect): window = rect; source = "owned"
        case .accessibility(let rect):
            window = CGRect(x: rect.minX, y: (displays.first?.frame.maxY ?? 0) - rect.maxY,
                            width: rect.width, height: rect.height)
            source = "accessibility"
        case .unavailable: window = .null; source = "pointer"
        }
        if valid(window),
           let display = displays.max(by: { area($0.frame.intersection(window)) < area($1.frame.intersection(window)) }),
           area(display.frame.intersection(window)) > 0 {
            return Placement(visibleFrame: display.visibleFrame, source: source)
        }
        guard let display = displays.first(where: { $0.frame.contains(pointer) }) ?? displays.first else { return nil }
        return Placement(visibleFrame: display.visibleFrame, source: "pointer")
    }

    private nonisolated static func area(_ rect: CGRect) -> CGFloat {
        rect.isNull ? 0 : rect.width * rect.height
    }

    private nonisolated static func valid(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite && rect.origin.y.isFinite && rect.width.isFinite && rect.height.isFinite
            && rect.width > 0 && rect.height > 0
    }
}
