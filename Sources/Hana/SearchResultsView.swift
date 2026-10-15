import SwiftUI

/// A row in Search's list: an actual match, or a capture suggestion. Suggestions
/// always follow every match.
enum SearchRow: Identifiable, Equatable {
    case result(SearchResult)
    case suggestion(CaptureSession.Suggestion)

    enum ID: Hashable {
        case result(SearchResult.ID)
        case suggestion(CaptureSession.Suggestion)
    }

    var id: ID {
        switch self {
        case .result(let result): .result(result.id)
        case .suggestion(let suggestion): .suggestion(suggestion)
        }
    }
}

struct SearchResultsView: View {
    var rows: [SearchRow] = []
    /// The Search text a suggestion would capture, on one line.
    var query = ""
    var selectedID: SearchRow.ID?
    var status: String?
    /// Values only: the view owns no cache and does no filesystem work.
    var icons: [SearchResult.ID: ResultIcon] = [:]
    var scrollResetID: UUID?
    var followsFirstResult = true
    var scrollOffsetChanged: (CGFloat) -> Void = { _ in }
    var select: (SearchRow.ID) -> Void = { _ in }
    var rowAppeared: (SearchResult.ID) -> Void = { _ in }

    @State private var scroll = ScrollMetrics()

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
            if !rows.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(rows) { row in
                                Button { select(row.id) } label: { label(row) }
                                    .buttonStyle(.plain)
                                    .accessibilityLabel(accessibilityLabel(row))
                                    .accessibilityAddTraits(selectedID == row.id ? .isSelected : [])
                                    .id(row.id)
                                    .onAppear { if case .result(let result) = row { rowAppeared(result.id) } }
                            }
                        }
                        .padding(.trailing, BarStyle.cardPadding)
                    }
                    .scrollIndicators(.never)
                    .onScrollGeometryChange(for: ScrollMetrics.self) {
                        ScrollMetrics(offset: $0.contentOffset.y, content: $0.contentSize.height, visible: $0.containerSize.height)
                    } action: { _, metrics in
                        scroll = metrics
                        scrollOffsetChanged(metrics.offset)
                    }
                    .overlay(alignment: .topTrailing) { scrollThumb }
                    .frame(height: CGFloat(min(rows.count, Self.maxVisibleRows)) * Self.rowHeight)
                    .onChange(of: selectedID) { _, id in
                        if let id { proxy.scrollTo(id, anchor: followsFirstResult ? .top : nil) }
                    }
                }
                // Recreate the scroll position on every edit, including edits
                // whose first result has the same ID as before.
                .id(scrollResetID)
            }
            if let status {
                Text(status).font(.system(size: 12)).foregroundStyle(Color(nsColor: BarStyle.secondaryColor))
                    .lineLimit(2)
                    .padding(.horizontal, 8).frame(maxWidth: .infinity, minHeight: Self.statusHeight, alignment: .leading)
                    .padding(.trailing, BarStyle.cardPadding)
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .foregroundStyle(Color(nsColor: BarStyle.textColor))
        .environment(\.colorScheme, .light)
    }

    /// A thin, always-visible thumb centred in the card's trailing padding,
    /// clear of the row highlight, only when rows overflow. The system
    /// scroller stays hidden: its legacy style would claim a wide opaque track.
    @ViewBuilder private var scrollThumb: some View {
        let track = scroll.visible
        if scroll.content > scroll.visible + 0.5, track > 0 {
            let height = max(Self.thumbMinHeight, track * scroll.visible / scroll.content)
            let progress = min(max(scroll.offset / (scroll.content - scroll.visible), 0), 1)
            Capsule()
                .fill(Color.black.opacity(0.16))
                .frame(width: Self.thumbWidth, height: height)
                .offset(y: progress * (track - height))
                .padding(.trailing, Self.thumbTrailing)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private static let thumbWidth: CGFloat = 3
    private static let thumbMinHeight: CGFloat = 24
    private static let thumbTrailing = (BarStyle.cardPadding - thumbWidth) / 2

    // Icons share the mode icon's center line and names start with the query
    // text. The surface sits cardPadding inside the card's leading edge and
    // runs to its trailing edge; rows keep cardPadding clear on the right.
    // Icons and type labels sit equally far inside the highlight.
    private static let rowInset = BarStyle.resultIconInset
    private static let nameLeading = BarStyle.textInset - BarStyle.cardPadding - rowInset - BarStyle.resultIconSize

    private func accessibilityLabel(_ row: SearchRow) -> String {
        switch row {
        case .result(let result): "\(result.name), \(result.typeLabel), \(result.subtitle)"
        case .suggestion(let suggestion): "\(suggestion.title), \(query)"
        }
    }

    @ViewBuilder private func label(_ row: SearchRow) -> some View {
        switch row {
        case .result(let result):
            self.row(id: row.id, name: result.name, subtitle: result.subtitle, typeLabel: result.typeLabel) { icon(result) }
        case .suggestion(let suggestion):
            // The capture keeps every character; only this preview is one line.
            self.row(id: row.id, name: suggestion.title, subtitle: query, typeLabel: nil) {
                Image(systemName: suggestion.symbolName)
                    .font(.system(size: 18))
                    .foregroundStyle(Color(nsColor: BarStyle.iconColor))
            }
        }
    }

    private func row(id: SearchRow.ID, name: String, subtitle: String, typeLabel: String?,
                     @ViewBuilder icon: () -> some View) -> some View {
        HStack(spacing: Self.nameLeading) {
            icon()
                .frame(width: BarStyle.resultIconSize, height: BarStyle.resultIconSize)
                // Arrival swaps the image in place, never animated.
                .transaction { $0.animation = nil }
            VStack(alignment: .leading, spacing: 1) {
                Text(name).font(.system(size: 16)).tracking(-0.16).lineLimit(1)
                Text(subtitle).font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: BarStyle.secondaryColor))
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer(minLength: 8)
            if let typeLabel {
                Text(typeLabel).font(.system(size: 12))
                    .foregroundStyle(Color(nsColor: BarStyle.secondaryColor))
            }
        }
        .padding(.horizontal, Self.rowInset).frame(height: Self.rowHeight)
        .background(selectedID == id ? Color.black.opacity(0.06) : Color.clear)
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

private struct ScrollMetrics: Equatable {
    var offset: CGFloat = 0
    var content: CGFloat = 0
    var visible: CGFloat = 0
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

private extension CaptureSession.Suggestion {
    var title: String {
        switch self {
        case .note: "New note"
        case .task: "New task"
        }
    }

    /// Echo the Note and Task mode icons: lines on a rounded square, a checked circle.
    var symbolName: String {
        switch self {
        case .note: "note.text"
        case .task: "checkmark.circle"
        }
    }
}
