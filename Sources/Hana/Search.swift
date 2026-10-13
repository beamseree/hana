import Foundation

struct ApplicationResult: Identifiable, Equatable, Sendable {
    struct ID: Hashable, Sendable { let installation: URL }
    let name: String
    let url: URL
    var alternateNames: [String] = []
    var id: ID { ID(installation: url.standardizedFileURL) }
    var subtitle: String { url.path }
    var typeLabel: String { "Application" }
}

enum CatalogStatus: Equatable, Sendable {
    case loading, ready, failed
}

struct CatalogSnapshot: Sendable {
    let applications: [ApplicationResult]
    let status: CatalogStatus
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
        let results: [ApplicationResult]
        let status: CatalogStatus
    }
    private let source: () -> AsyncStream<CatalogSnapshot>
    private let debounce: Duration
    private var task: Task<Void, Never>?
    private var generation: UUID?
    private struct Usage: Sendable { var count = 0; var sequence = 0 }
    private var usage: [ApplicationResult.ID: Usage] = [:]
    private var sequence = 0

    deinit { task?.cancel() }

    func recordOpened(_ id: ApplicationResult.ID) {
        sequence += 1
        usage[id, default: Usage()].count += 1
        usage[id]?.sequence = sequence
    }

    init(source: @escaping () -> AsyncStream<CatalogSnapshot>, debounce: Duration = .milliseconds(100)) {
        self.source = source
        self.debounce = debounce
    }

    convenience init(roots: [URL] = ApplicationCatalog.conventionalRoots, debounce: Duration = .milliseconds(100)) {
        let catalog = ApplicationCatalog(roots: roots)
        self.init(source: { catalog.snapshots() }, debounce: debounce)
    }

    func search(_ request: Request) -> AsyncStream<Batch> {
        task?.cancel()
        generation = request.generation
        let (stream, continuation) = AsyncStream<Batch>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let query = Self.normalized(request.text).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            continuation.yield(Batch(generation: request.generation, results: [], status: .ready))
            continuation.finish()
            return stream
        }
        let source = source
        let debounce = debounce
        task = Task { [weak self] in
            defer { continuation.finish() }
            do { try await Task.sleep(for: debounce) } catch { return }
            for await snapshot in source() {
                guard !Task.isCancelled, self?.generation == request.generation else { return }
                let usage = self?.usage ?? [:]
                let results = await Task.detached(priority: .userInitiated) {
                    Self.rank(snapshot.applications, query: query, usage: usage)
                }.value
                guard !Task.isCancelled, self?.generation == request.generation else { return }
                continuation.yield(Batch(generation: request.generation, results: results, status: snapshot.status))
            }
        }
        continuation.onTermination = { [weak self] _ in
            Task { @MainActor in
                if self?.generation == request.generation { self?.task?.cancel() }
            }
        }
        return stream
    }

    private nonisolated static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    private nonisolated static func rank(_ applications: [ApplicationResult], query: String,
                                         usage: [ApplicationResult.ID: Usage]) -> [ApplicationResult] {
        struct Candidate {
            let app: ApplicationResult
            let tier: Int
            let name: String
            let usage: Usage
        }
        func precedes(_ lhs: Candidate, _ rhs: Candidate) -> Bool {
            if lhs.tier != rhs.tier { return lhs.tier < rhs.tier }
            if lhs.usage.count != rhs.usage.count { return lhs.usage.count > rhs.usage.count }
            if lhs.usage.sequence != rhs.usage.sequence { return lhs.usage.sequence > rhs.usage.sequence }
            if lhs.name != rhs.name { return lhs.name < rhs.name }
            return lhs.app.url.path < rhs.app.url.path
        }
        var seen = Set<ApplicationResult.ID>()
        var best: [Candidate] = []
        let tokens = query.split(whereSeparator: \.isWhitespace)
        for app in applications where seen.insert(app.id).inserted {
            let name = normalized(app.name)
            let tiers = ([app.name] + app.alternateNames).map(normalized).compactMap { value -> Int? in
                guard tokens.allSatisfy({ value.contains($0) }) else { return nil }
                return value == query ? 0 : value.hasPrefix(query) ? 1 : 2
            }
            guard let tier = tiers.min() else { continue }
            let candidate = Candidate(app: app, tier: tier,
                                      name: name, usage: usage[app.id] ?? Usage())
            let index = best.firstIndex { precedes(candidate, $0) } ?? best.count
            if index < 20 {
                best.insert(candidate, at: index)
                if best.count > 20 { best.removeLast() }
            }
        }
        return best.map(\.app)
    }
}
