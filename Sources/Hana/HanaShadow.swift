import SwiftUI

/// One elevation level: a thin outline ring plus soft drop layers, all black.
/// See docs/design-system.md.
struct ShadowRole: Sendable {
    /// A layer as CSS writes it: offsets, blur and spread in points.
    struct Drop: Sendable {
        let x: CGFloat
        let y: CGFloat
        let blur: CGFloat
        let spread: CGFloat
        let opacity: Double
    }

    /// Opacity of the 1-point ring just outside the shape.
    let outline: Double
    let drops: [Drop]
}

/// Named elevation levels. Flat is the default and has no role; windows, the
/// Search bar and native menus keep the system's own shadow.
enum HanaShadow {
    /// Small white pieces on gray: the selected segment, key hints, cards.
    static let raised = ShadowRole(outline: 0.06, drops: [
        .init(x: 0, y: 1, blur: 2, spread: -1, opacity: 0.06),
        .init(x: 0, y: 2, blur: 4, spread: 0, opacity: 0.04),
    ])
    /// Floating panels Hana draws itself.
    static let popover = ShadowRole(outline: 0.06, drops: [
        .init(x: 0, y: 4, blur: 8, spread: -2, opacity: 0.06),
        .init(x: 0, y: 12, blur: 24, spread: -4, opacity: 0.08),
    ])
}

extension View {
    /// Casts `role` behind an opaque view with these corners. SwiftUI shadows
    /// have no spread, so each layer is cast by a shape grown or shrunk by its
    /// spread; CSS blur is twice SwiftUI's radius.
    func elevation(_ role: ShadowRole, cornerRadius: CGFloat) -> some View {
        background {
            ZStack {
                ForEach(role.drops.indices, id: \.self) { index in
                    let drop = role.drops[index]
                    RoundedRectangle(cornerRadius: max(cornerRadius + drop.spread, 0))
                        .fill(.white)
                        .padding(-drop.spread)
                        .shadow(color: .black.opacity(drop.opacity), radius: drop.blur / 2, x: drop.x, y: drop.y)
                }
                RoundedRectangle(cornerRadius: cornerRadius + 1)
                    .fill(.black.opacity(role.outline))
                    .padding(-1)
            }
        }
    }
}
