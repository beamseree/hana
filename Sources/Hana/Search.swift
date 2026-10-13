import Foundation

struct SearchResult: Identifiable, Equatable, Sendable {
    struct ID: Hashable, Sendable { let destination: URL }
    let name: String
    let url: URL
    let alternateNames: [String]
    enum Kind: String, Sendable { case application = "Application", file = "File", folder = "Folder" }
    let kind: Kind
    init(name: String, url: URL, alternateNames: [String] = [], kind: Kind = .application) {
        self.name = name
        self.url = url
        self.alternateNames = alternateNames
        self.kind = kind
    }
    var id: ID { ID(destination: url.standardizedFileURL) }
    var subtitle: String { url.path }
    var typeLabel: String { kind.rawValue }
}

enum SourceStatus: String, Equatable, Sendable {
    case loading, partial, ready, failed
}

struct SourceSnapshot: Sendable {
    let results: [SearchResult]
    let status: SourceStatus
}

/// Query-to-batches boundary. The source is an internal adapter, never a UI API.
@MainActor
final class Search {
    struct Request: Sendable {
        let generation = UUID()
        let text: String
    }
    struct Batch: Sendable {
        let generation: UUID
        let results: [SearchResult]
        let appStatus: SourceStatus
        let fileStatus: SourceStatus
        var status: SourceStatus {
            if appStatus == .failed || fileStatus == .failed { return .failed }
            if appStatus == .loading || fileStatus == .loading { return .loading }
            if appStatus == .partial || fileStatus == .partial { return .partial }
            return .ready
        }
    }
    private final class SourceState {
        var apps = SourceSnapshot(results: [], status: .loading)
        var files: SourceSnapshot
        init(hasFiles: Bool) { files = SourceSnapshot(results: [], status: hasFiles ? .loading : .ready) }
    }
    private let source: () -> AsyncStream<SourceSnapshot>
    private var files: ((String) -> AsyncStream<SourceSnapshot>)?
    private let debounce: Duration
    private var task: Task<Void, Never>?
    private var generation: UUID?
    struct Usage: Sendable { var count = 0; var sequence = 0 }
    private var usage: [SearchResult.ID: Usage] = [:]
    private var sequence = 0

    deinit { task?.cancel() }

    func recordOpened(_ id: SearchResult.ID) {
        sequence += 1
        usage[id, default: Usage()].count = min(10, usage[id, default: Usage()].count + 1)
        usage[id]?.sequence = sequence
    }

    init(source: @escaping () -> AsyncStream<SourceSnapshot>, files: ((String) -> AsyncStream<SourceSnapshot>)? = nil, debounce: Duration = .milliseconds(100)) {
        self.files = files
        self.source = source
        self.debounce = debounce
    }

    convenience init(roots: [URL], indexedFiles: Bool = false, fileDelay: Duration = .zero, debounce: Duration = .milliseconds(100)) {
        let catalog = ApplicationCatalog(roots: roots)
        self.init(source: { catalog.snapshots() }, debounce: debounce)
        if indexedFiles {
            self.files = { [weak self] text in
                // Opening dismisses the query. Each subsequent query captures
                // the latest acknowledged session usage before adapter limits.
                let usage = self?.usage ?? [:]
                let (stream, continuation) = AsyncStream<SourceSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
                let task = Task {
                    defer { continuation.finish() }
                    do { try await Task.sleep(for: fileDelay) } catch { return }
                    for await snapshot in SpotlightSource.snapshots(for: text, usage: usage) { continuation.yield(snapshot) }
                }
                continuation.onTermination = { _ in task.cancel() }
                return stream
            }
        }
    }

    convenience init() {
        self.init(roots: ApplicationCatalog.conventionalRoots, indexedFiles: true)
    }

    func search(_ request: Request) -> AsyncStream<Batch> {
        task?.cancel()
        generation = request.generation
        let (stream, continuation) = AsyncStream<Batch>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let query = Self.normalized(request.text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            continuation.yield(Batch(generation: request.generation, results: [], appStatus: .ready, fileStatus: .ready))
            continuation.finish()
            return stream
        }
        let source = source
        let files = files
        let debounce = debounce
        task = Task { [weak self] in
            defer { continuation.finish() }
            do { try await Task.sleep(for: debounce) } catch { return }
            // Each producer is independently consumed: slow metadata never blocks
            // an available catalog snapshot. Only value snapshots enter the merger.
            let state = SourceState(hasFiles: files != nil)
            let (updates, sink) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let apps = Task {
                for await snapshot in source() { state.apps = snapshot; sink.yield(()) }
            }
            let metadata = Task {
                if let files {
                    for await snapshot in files(request.text) { state.files = snapshot; sink.yield(()) }
                }
            }
            let completion = Task { await apps.value; await metadata.value; sink.finish() }
            defer { apps.cancel(); metadata.cancel(); completion.cancel(); sink.finish() }
            for await _ in updates {
                guard !Task.isCancelled, self?.generation == request.generation else { return }
                let appSnapshot = state.apps, fileSnapshot = state.files
                let usage = self?.usage ?? [:]
                let candidates = appSnapshot.results + fileSnapshot.results
                let work = Task.detached(priority: .userInitiated) {
                    await Self.rank(candidates, query: query, usage: usage)
                }
                let results = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
                guard !Task.isCancelled, self?.generation == request.generation else { return }
                continuation.yield(Batch(generation: request.generation, results: results,
                                         appStatus: appSnapshot.status, fileStatus: fileSnapshot.status))
            }
        }
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                if self?.generation == request.generation { self?.task?.cancel() }
            }
        }
        return stream
    }

    /// Shared eligibility is applied before merging/ranking and visible limits.
    nonisolated static func eligible(_ url: URL) -> Bool {
        let url = url.standardizedFileURL
        let components = url.pathComponents
        guard !components.contains(where: { $0.hasPrefix(".") }) else { return false }
        let bundleExtensions: Set<String> = ["app", "bundle", "framework", "plugin", "appex"]
        guard !components.dropLast().contains(where: { bundleExtensions.contains(($0 as NSString).pathExtension.lowercased()) }) else { return false }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let privateRoots = ["Library/Application Support/com.beamseree.hana", "Library/Caches/com.beamseree.hana", "Library/Logs/com.beamseree.hana", "Library/Logs/Hana", "Library/Application Support/Hana", "Library/Caches/Hana", "Library/Preferences/com.beamseree.hana.plist"]
        return !privateRoots.contains { root in
            let path = home.appendingPathComponent(root).path
            return url.path == path || url.path.hasPrefix(path + "/")
        }
    }

    private nonisolated static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    nonisolated static func matchTier(_ name: String, query: String) -> Int? {
        let value = normalized(name), query = normalized(query)
        guard query.split(whereSeparator: \.isWhitespace).allSatisfy({ value.contains($0) }) else { return nil }
        return value == query ? 0 : value.hasPrefix(query) ? 1 : 2
    }

    // Internal adapter compaction uses the same ordering as visible Search.
    // The retained shortlist is bounded; scan work yields every 128 candidates.
    nonisolated static func compactCandidates(_ results: [SearchResult], query: String, limit: Int, usage: [SearchResult.ID: Usage] = [:]) async -> [SearchResult] {
        await rank(results, query: normalized(query), usage: usage, limit: limit)
    }

    private nonisolated static func rank(_ results: [SearchResult], query: String,
                                         usage: [SearchResult.ID: Usage], limit: Int = 20) async -> [SearchResult] {
        struct Candidate {
            let id: SearchResult.ID
            let tier: Int
            let closeness: Int
            let usage: Usage
        }
        func precedes(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            if lhs.closeness != rhs.closeness { return lhs.closeness < rhs.closeness }
            if lhs.usage.sequence != rhs.usage.sequence { return lhs.usage.sequence > rhs.usage.sequence }
            if lhs.usage.count != rhs.usage.count { return lhs.usage.count > rhs.usage.count }
            return lhs.id.destination.path < rhs.id.destination.path
        }
        var best: [Candidate] = []
        for (offset, result) in results.enumerated() {
            if offset.isMultiple(of: 128) {
                if Task.isCancelled { return [] }
                await Task.yield()
            }
            guard eligible(result.url) else { continue }
            var candidate: Candidate?
            for name in [result.name] + result.alternateNames {
                guard let tier = matchTier(name, query: query) else { continue }
                let scored = Candidate(id: result.id, tier: tier,
                    closeness: max(0, normalized(name).count - query.count), usage: usage[result.id] ?? Usage())
                if candidate == nil || precedes(scored, candidate!) { candidate = scored }
            }
            guard let candidate else { continue }
            if let previous = best.firstIndex(where: { $0.id == candidate.id }) {
                guard precedes(candidate, best[previous]) else { continue }
                best.remove(at: previous)
            }
            let index = best.firstIndex { precedes(candidate, $0) } ?? best.count
            if index < limit {
                best.insert(candidate, at: index)
                if best.count > limit { best.removeLast() }
            }
        }
        // Recover presentation only for retained identities. Catalog comes first
        // in the merged input; unmatched catalog names must not hide file aliases.
        let retained = Set(best.map(\.id))
        var destinations: [SearchResult.ID: SearchResult] = [:]
        for (offset, result) in results.enumerated() {
            if offset.isMultiple(of: 128) {
                if Task.isCancelled { return [] }
                await Task.yield()
            }
            guard retained.contains(result.id) else { continue }
            if let existing = destinations[result.id] {
                destinations[result.id] = SearchResult(name: existing.name, url: existing.url,
                    alternateNames: Array(Set(existing.alternateNames + [result.name] + result.alternateNames)).sorted(), kind: existing.kind)
            } else { destinations[result.id] = result }
        }
        return best.compactMap { destinations[$0.id] }
    }
}
