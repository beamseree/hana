import SwiftUI

struct SearchResultsView: View {
    var results: [SearchResult] = []
    var selectedID: SearchResult.ID?
    var status: String?
    var select: (SearchResult.ID) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !results.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(results) { result in
                                Button { select(result.id) } label: {
                                    VStack(alignment: .leading, spacing: 3) {
                                        HStack {
                                            Text(result.name).font(.system(size: 15, weight: .medium)).lineLimit(1)
                                            Spacer()
                                            Text(result.typeLabel).font(.system(size: 11)).foregroundStyle(.secondary)
                                        }
                                        Text(result.subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                                            .lineLimit(1).truncationMode(.middle)
                                    }
                                    .padding(.horizontal, 10).frame(height: 56)
                                    .background(selectedID == result.id ? Color.black.opacity(0.08) : Color.clear)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("\(result.name), \(result.typeLabel), \(result.subtitle)")
                                .accessibilityAddTraits(selectedID == result.id ? .isSelected : [])
                                .id(result.id)
                            }
                        }
                    }
                    .onChange(of: selectedID) { _, id in if let id { proxy.scrollTo(id) } }
                }
            }
            if let status {
                Text(status).font(.system(size: 12)).foregroundStyle(.secondary)
                    .padding(.horizontal, 10).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
            }
        }
        .foregroundStyle(.black)
        .environment(\.colorScheme, .light)
    }
}
