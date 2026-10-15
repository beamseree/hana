import CoreGraphics

/// Base corner radii for shapes that sit inside no other rounded shape.
/// Nested shapes derive theirs with `nested(in:inset:)`; capsules use half
/// their height. See docs/design-system.md.
enum HanaRadius {
    /// The Search bar's bezel.
    static let bar: CGFloat = 26
    /// Grouped lists in working windows.
    static let group: CGFloat = 16
    /// Fields, segmented controls and buttons.
    static let control: CGFloat = 12
    /// Key hints and small tags.
    static let chip: CGFloat = 6

    /// The concentric rule: an inner corner follows the outer one across the gap.
    static func nested(in outer: CGFloat, inset: CGFloat) -> CGFloat {
        max(outer - inset, 0)
    }
}
