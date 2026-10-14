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
        /// At least one visible match was supplied by a source for this
        /// request, rather than surviving only in the previous-result cache.
        let hasFreshResults: Bool
        var status: SourceStatus {
            if appStatus == .failed || fileStatus == .failed { return .failed }
            if appStatus == .loading || fileStatus == .loading { return .loading }
            if appStatus == .partial || fileStatus == .partial { return .partial }
            return .ready
        }
    }
    /// The bounded recheck is available synchronously to the editor and is
    /// always the first batch, even if source updates arrive before iteration.
    struct Batches: AsyncSequence {
        let initial: Batch
        let updates: AsyncStream<Batch>
        struct AsyncIterator: AsyncIteratorProtocol {
            var initial: Batch?
            var updates: AsyncStream<Batch>.Iterator
            mutating func next() async -> Batch? {
                if let initial { self.initial = nil; return initial }
                return await updates.next()
            }
        }
        func makeAsyncIterator() -> AsyncIterator {
            AsyncIterator(initial: initial, updates: updates.makeAsyncIterator())
        }
    }
    private final class SourceState {
        var apps: SourceSnapshot
        var files: SourceSnapshot
        var freshApps: [SearchResult] = []
        var freshFiles: [SearchResult] = []
        var visibleIDs: Set<SearchResult.ID>
        init(apps: [SearchResult], files: [SearchResult], hasFiles: Bool) {
            self.apps = SourceSnapshot(results: apps, status: .loading)
            self.files = SourceSnapshot(results: files, status: hasFiles ? .loading : .ready)
            visibleIDs = Set((apps + files).map(\.id))
        }

        func receive(_ snapshot: SourceSnapshot, for key: ReferenceWritableKeyPath<SourceState, SourceSnapshot>) {
            let previous = self[keyPath: key]
            let freshIDs = Set(snapshot.results.map(\.id))
            let retained = snapshot.status == .loading
                ? previous.results.filter { visibleIDs.contains($0.id) && !freshIDs.contains($0.id) } : []
            self[keyPath: key] = SourceSnapshot(results: snapshot.results + retained, status: snapshot.status)
        }
    }
    // Only previously visible matches, with source ownership kept for replacement.
    private var retainedApps: [SearchResult] = []
    private var retainedFiles: [SearchResult] = []
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

    func search(_ request: Request) -> Batches {
        task?.cancel()
        generation = request.generation
        let (stream, continuation) = AsyncStream<Batch>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let query = Self.normalized(request.text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            retainedApps = []
            retainedFiles = []
            let initial = Batch(generation: request.generation, results: [], appStatus: .ready, fileStatus: .ready, hasFreshResults: false)
            continuation.finish()
            return Batches(initial: initial, updates: stream)
        }
        let source = source
        let files = files
        let debounce = debounce
        let state = SourceState(apps: retainedApps, files: retainedFiles, hasFiles: files != nil)
        let initialResults = Self.rank(state.apps.results + state.files.results, query: query, usage: usage)
        retain(initialResults, from: state)
        state.visibleIDs = Set(initialResults.map(\.id))
        let initial = Batch(generation: request.generation, results: initialResults,
                            appStatus: state.apps.status, fileStatus: state.files.status, hasFreshResults: false)
        task = Task { [weak self] in
            defer { continuation.finish() }
            guard !Task.isCancelled, self?.generation == request.generation else { return }
            // Each producer is independently consumed: slow metadata never blocks
            // an available catalog snapshot. Only value snapshots enter the merger.
            let (updates, sink) = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
            let apps = Task {
                for await snapshot in source() {
                    state.freshApps = snapshot.results
                    state.receive(snapshot, for: \.apps)
                    sink.yield(())
                }
            }
            let metadata = Task {
                if let files {
                    do { try await Task.sleep(for: debounce) } catch { return }
                    for await snapshot in files(request.text) {
                        state.freshFiles = snapshot.results
                        state.receive(snapshot, for: \.files)
                        sink.yield(())
                    }
                }
            }
            let completion = Task { await apps.value; await metadata.value; sink.finish() }
            defer { apps.cancel(); metadata.cancel(); completion.cancel(); sink.finish() }
            for await _ in updates {
                guard !Task.isCancelled, self?.generation == request.generation else { return }
                let appSnapshot = state.apps, fileSnapshot = state.files
                let usage = self?.usage ?? [:]
                let candidates = appSnapshot.results + fileSnapshot.results
                let freshCandidates = state.freshApps + state.freshFiles
                let work = Task.detached(priority: .userInitiated) {
                    let results = Self.rank(candidates, query: query, usage: usage)
                    let visible = Set(results.map(\.id))
                    let hasFreshResults = freshCandidates.contains { result in
                        visible.contains(result.id) && ([result.name] + result.alternateNames).contains {
                            Self.matchTier($0, query: query) != nil
                        }
                    }
                    return (results, hasFreshResults)
                }
                let (results, hasFreshResults) = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
                guard !Task.isCancelled, self?.generation == request.generation else { return }
                state.visibleIDs = Set(results.map(\.id))
                self?.retain(results, apps: appSnapshot.results, files: fileSnapshot.results)
                continuation.yield(Batch(generation: request.generation, results: results,
                                         appStatus: appSnapshot.status, fileStatus: fileSnapshot.status, hasFreshResults: hasFreshResults))
            }
        }
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                if self?.generation == request.generation { self?.task?.cancel() }
            }
        }
        return Batches(initial: initial, updates: stream)
    }

    private func retain(_ results: [SearchResult], from state: SourceState) {
        retain(results, apps: state.apps.results, files: state.files.results)
    }

    private func retain(_ results: [SearchResult], apps: [SearchResult], files: [SearchResult]) {
        let visible = Set(results.map(\.id))
        func retained(from source: [SearchResult]) -> [SearchResult] {
            var destinations: [SearchResult.ID: SearchResult] = [:]
            for result in source where visible.contains(result.id) {
                Self.merge(result, into: &destinations)
            }
            return results.compactMap { destinations[$0.id] }
        }
        // Preserve source-local aliases: a file-only name must disappear when
        // the file source replaces it, even if the catalog is still loading.
        retainedApps = retained(from: apps)
        retainedFiles = retained(from: files)
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
    // The retained shortlist is bounded; ranking checks cancellation every 128 candidates.
    nonisolated static func compactCandidates(_ results: [SearchResult], query: String, limit: Int, usage: [SearchResult.ID: Usage] = [:]) async -> [SearchResult] {
        await Task.yield()
        return rank(results, query: normalized(query), usage: usage, limit: limit)
    }

    private nonisolated static func rank(_ results: [SearchResult], query: String,
                                         usage: [SearchResult.ID: Usage], limit: Int = 20) -> [SearchResult] {
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
            }
            guard retained.contains(result.id) else { continue }
            merge(result, into: &destinations)
        }
        return best.compactMap { destinations[$0.id] }
    }

    private nonisolated static func merge(_ result: SearchResult, into destinations: inout [SearchResult.ID: SearchResult]) {
        if let existing = destinations[result.id] {
            destinations[result.id] = SearchResult(name: existing.name, url: existing.url,
                alternateNames: Array(Set(existing.alternateNames + [result.name] + result.alternateNames)).sorted(), kind: existing.kind)
        } else { destinations[result.id] = result }
    }
}
