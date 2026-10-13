import SwiftUI

struct SearchResultsView: View {
    var results: [SearchResult] = []
    var selectedID: SearchResult.ID?
    var status: String?
    /// Values only: the view owns no cache and does no filesystem work.
    var icons: [SearchResult.ID: ResultIcon] = [:]
    var select: (SearchResult.ID) -> Void = { _ in }
    var rowAppeared: (SearchResult.ID) -> Void = { _ in }

    static let rowHeight: CGFloat = 56
    static let statusHeight: CGFloat = 44
    static let maxVisibleRows = 7

    /// The content height, so the panel and the view agree on geometry. The
    /// card around it supplies the padding.
    static func height(rowCount: Int, hasStatus: Bool) -> CGFloat {
        CGFloat(min(rowCount, maxVisibleRows)) * rowHeight + (hasStatus ? statusHeight : 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !results.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(results) { result in
                                Button { select(result.id) } label: { row(result) }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel("\(result.name), \(result.typeLabel), \(result.subtitle)")
                                    .accessibilityAddTraits(selectedID == result.id ? .isSelected : [])
                                    .id(result.id)
                                    .onAppear { rowAppeared(result.id) }
                            }
                        }
                    }
                    .scrollIndicators(.never)
                    .frame(height: CGFloat(min(results.count, Self.maxVisibleRows)) * Self.rowHeight)
                    .onChange(of: selectedID) { _, id in if let id { proxy.scrollTo(id) } }
                }
            }
            if let status {
                Text(status).font(.system(size: 12)).foregroundStyle(Color(nsColor: BarStyle.secondaryColor))
                    .lineLimit(2)
                    .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: Self.statusHeight, alignment: .leading)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .foregroundStyle(Color(nsColor: BarStyle.textColor))
        .environment(\.colorScheme, .light)
    }

    // Icons share the mode icon's center line and names start with the query
    // text. The surface sits cardPadding inside the card.
    private static let iconLeading = BarStyle.resultIconInset
    private static let nameLeading = BarStyle.textInset - BarStyle.cardPadding - iconLeading - BarStyle.resultIconSize

    private func row(_ result: SearchResult) -> some View {
        HStack(spacing: Self.nameLeading) {
            icon(result)
                .frame(width: BarStyle.resultIconSize, height: BarStyle.resultIconSize)
                // Arrival swaps the image in place, never animated.
                .transaction { $0.animation = nil }
            VStack(alignment: .leading, spacing: 1) {
                Text(result.name).font(.system(size: 16)).tracking(-0.16).lineLimit(1)
                Text(result.subtitle).font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: BarStyle.secondaryColor))
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            Text(result.typeLabel).font(.system(size: 12))
                .foregroundStyle(Color(nsColor: BarStyle.secondaryColor))
        }
        .padding(.leading, Self.iconLeading).padding(.trailing, 8).frame(height: Self.rowHeight)
        .background(selectedID == result.id ? Color.black.opacity(0.06) : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: BarStyle.cardRadius - BarStyle.cardPadding))
        .contentShape(Rectangle())
    }

    /// The generic symbol is both the loading placeholder and the fallback.
    /// Application icons keep their own colours; other kinds stay monochrome.
    @ViewBuilder private func icon(_ result: SearchResult) -> some View {
        if let icon = icons[result.id] {
            Image(decorative: icon.image, scale: icon.scale).resizable().interpolation(.high)
        } else {
            Image(systemName: result.symbolName)
                .font(.system(size: 18))
                .foregroundStyle(Color(nsColor: BarStyle.iconColor))
        }
    }
}

private extension SearchResult {
    var symbolName: String {
        switch kind {
        case .application: "app.dashed"
        case .file: "doc"
        case .folder: "folder"
        }
    }
}
