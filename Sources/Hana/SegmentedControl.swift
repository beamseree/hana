import SwiftUI

/// A one-of-several choice from the design system: a gray track holding a
/// white, raised segment for the choice. Values only; the owner decides.
struct SegmentedControl: View {
    var labels: [String] = []
    var selection = 0
    var isEnabled = true
    var accessibilityTitle = ""
    var choose: (Int) -> Void = { _ in }

    static let height: CGFloat = 28
    /// The gap between the track and the selected segment.
    static let inset: CGFloat = 3
    static let segmentRadius = HanaRadius.nested(in: HanaRadius.control, inset: inset)

    var body: some View {
        HStack(spacing: 2) {
            ForEach(labels.indices, id: \.self) { index in
                Button { choose(index) } label: { segment(index) }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(index == selection ? .isSelected : [])
            }
        }
        .padding(Self.inset)
        .frame(height: Self.height)
        .background(RoundedRectangle(cornerRadius: HanaRadius.control).fill(Color(nsColor: HanaColor.Control.fill)))
        .disabled(!isEnabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityTitle)
    }

    private func segment(_ index: Int) -> some View {
        let selected = index == selection
        let color = !isEnabled ? HanaColor.Text.tertiary : selected ? HanaColor.Text.primary : HanaColor.Text.secondary
        return Text(labels[index]).font(HanaFont.body)
            .foregroundStyle(Color(nsColor: color))
            .padding(.horizontal, 10)
            .frame(maxHeight: .infinity)
            .background {
                if selected {
                    RoundedRectangle(cornerRadius: Self.segmentRadius)
                        .fill(Color(nsColor: HanaColor.Surface.card))
                        .elevation(HanaShadow.raised, cornerRadius: Self.segmentRadius)
                }
            }
            .contentShape(Rectangle())
    }
}
