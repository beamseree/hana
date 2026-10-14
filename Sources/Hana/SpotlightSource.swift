import Foundation

/// Internal adapter: query start/stop, notification delivery and metadata reads
/// belong to the application's main run loop. No NSMetadataItem leaves it.
@MainActor
final class SpotlightSource: NSObject {
    private struct Stage {
        let query: NSMetadataQuery
        var results: [SearchResult] = []
        var status: SourceStatus = .loading
        var revision = 0
        var processing: Task<Void, Never>?
    }
    private struct Item: Sendable {
        let name: String
        let url: URL
        let kind: SearchResult.Kind
    }
    // Bound each main-actor copy, not a prefix of the result universe. Literal
    // verification can reject thousands of conservative metadata matches.
    private static let scanChunk = 128
    private nonisolated static let candidateLimit = 256
    private let usage: [SearchResult.ID: Search.Usage]
    private let text: String
    private let continuation: AsyncStream<SourceSnapshot>.Continuation
    private var stages: [Stage] = []
    private var stopped = false

    static func snapshots(for text: String, usage: [SearchResult.ID: Search.Usage] = [:]) -> AsyncStream<SourceSnapshot> {
        let (stream, continuation) = AsyncStream<SourceSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let source = SpotlightSource(text: text, usage: usage, continuation: continuation)
        continuation.onTermination = { _ in Task { @MainActor in source.stop() } }
        source.startStage()
        return stream
    }

    private init(text: String, usage: [SearchResult.ID: Search.Usage], continuation: AsyncStream<SourceSnapshot>.Continuation) {
        self.text = text.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespacesAndNewlines)
        self.continuation = continuation
        self.usage = usage
    }

    private func startStage() {
        guard !stopped, stages.count < 3 else { return }
        let query = NSMetadataQuery()
        query.operationQueue = .main
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        query.notificationBatchingInterval = 0.1
        query.predicate = predicate(for: stages.count)
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSNameKey, ascending: true),
                                 NSSortDescriptor(key: NSMetadataItemPathKey, ascending: true)]
        // Request type values with the query. Per-item value(forAttribute:) can
        // synchronously fetch uncached metadata from Spotlight on the input actor.
        query.valueListAttributes = [NSMetadataItemContentTypeTreeKey]
        stages.append(Stage(query: query))
        for name in [NSNotification.Name.NSMetadataQueryDidFinishGathering, NSNotification.Name.NSMetadataQueryGatheringProgress, NSNotification.Name.NSMetadataQueryDidUpdate] {
            NotificationCenter.default.addObserver(self, selector: #selector(changed(_:)), name: name, object: query)
        }
        if !query.start() {
            stages[stages.count - 1].status = .failed
            publish()
            startStage()
        }
    }

    private func predicate(for tier: Int) -> NSPredicate {
        let special = CharacterSet(charactersIn: "[]*?\\\"'")
        let hasSpecial = text.rangeOfCharacter(from: special) != nil
        if !hasSpecial, tier == 0 {
            return NSCompoundPredicate(orPredicateWithSubpredicates: [
                NSPredicate(format: "%K ==[c] %@", NSMetadataItemFSNameKey, text),
                NSPredicate(format: "%K ==[c] %@", NSMetadataItemFSNameKey, text + ".app")
            ])
        }
        if !hasSpecial, tier == 1 { return NSPredicate(format: "%K BEGINSWITH[c] %@", NSMetadataItemFSNameKey, text) }
        // The metadata translator fails to match some compound punctuation such
        // as [*] on macOS 26.4.1. Bind conservative fragments, then verify the
        // complete literal filename/tier before any eligible-candidate limit.
        var fragments: [String] = []
        var word = ""
        for character in text {
            if character.isWhitespace || character.unicodeScalars.contains(where: { special.contains($0) }) {
                if !word.isEmpty { fragments.append(word); word = "" }
                if !character.isWhitespace { fragments.append(String(character)) }
            } else { word.append(character) }
        }
        if !word.isEmpty { fragments.append(word) }
        var predicates = Array(Set(fragments)).sorted().map { NSPredicate(format: "%K CONTAINS[c] %@", NSMetadataItemFSNameKey, $0) }
        if tier < 2 {
            let prefix = String(text.prefix(while: { !$0.unicodeScalars.contains(where: special.contains) }))
            let suffix = String(text.reversed().prefix(while: { !$0.unicodeScalars.contains(where: special.contains) }).reversed())
            predicates.append(NSPredicate(format: "%K BEGINSWITH[c] %@", NSMetadataItemFSNameKey, prefix.isEmpty ? String(text.prefix(1)) : prefix))
            if tier == 0 {
                let ending = suffix.isEmpty ? String(text.suffix(1)) : suffix
                predicates.append(NSCompoundPredicate(orPredicateWithSubpredicates: [
                    NSPredicate(format: "%K ENDSWITH[c] %@", NSMetadataItemFSNameKey, ending),
                    NSPredicate(format: "%K ENDSWITH[c] %@", NSMetadataItemFSNameKey, ending + ".app")
                ]))
            }
        }
        // NSMetadataQuery rejects a compound predicate with only one child.
        return predicates.count == 1 ? predicates[0] : NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
    }

    @objc private func changed(_ notification: Notification) {
        guard !stopped, let query = notification.object as? NSMetadataQuery,
              let index = stages.firstIndex(where: { $0.query === query }) else { return }
        let complete = !query.isGathering
        stages[index].revision += 1
        let revision = stages[index].revision
        stages[index].processing?.cancel()
        // Keep the previous complete snapshot while replacing it. Publishing
        // partial prefixes here would invalidate a still-existing selection.
        stages[index].status = .loading
        publish()
        let text = text, usage = usage
        stages[index].processing = Task { [weak self] in
            guard let self, !self.stopped, self.stages[index].revision == revision else { return }
            let count = query.resultCount
            var retained: [SearchResult] = []
            for start in stride(from: 0, to: count, by: Self.scanChunk) {
                guard !Task.isCancelled, !self.stopped, self.stages[index].revision == revision else { return }
                query.disableUpdates()
                let end = min(query.resultCount, start + Self.scanChunk)
                let values: [Item] = (min(start, end)..<end).compactMap { offset in
                    // kMDItemPath is not supplied by query.value on the tested OS,
                    // even as a sort key; keep the item's cheap path lookup.
                    guard let item = query.result(at: offset) as? NSMetadataItem,
                          let name = query.value(ofAttribute: NSMetadataItemFSNameKey, forResultAt: offset) as? String,
                          let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
                    let types = query.value(ofAttribute: NSMetadataItemContentTypeTreeKey, forResultAt: offset) as? [String] ?? []
                    let kind: SearchResult.Kind = types.contains("com.apple.application-bundle") ? .application
                        : types.contains("public.folder") ? .folder : .file
                    return Item(name: name, url: URL(fileURLWithPath: path, isDirectory: kind != .file), kind: kind)
                }
                // Never suspend native updates during filesystem work. A live
                // notification increments revision and cancels this replacement.
                query.enableUpdates()
                let previous = retained
                let work = Task.detached(priority: .userInitiated) {
                    var results = previous
                    for item in values {
                        if Task.isCancelled { return previous }
                        let name = item.kind == .application ? item.url.deletingPathExtension().lastPathComponent : item.name
                        guard let tier = [name, item.name].compactMap({ Search.matchTier($0, query: text) }).min(),
                              index == 2 || tier == index,
                              Search.indexedEligible(item.url, kind: item.kind), Self.visibleDestination(item.url) else { continue }
                        results.append(SearchResult(name: name, url: item.url,
                            alternateNames: item.kind == .application ? [item.name] : [], kind: item.kind))
                    }
                    return await Search.compactCandidates(results, query: text, limit: Self.candidateLimit, usage: usage)
                }
                retained = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
                guard !Task.isCancelled, !self.stopped, self.stages[index].revision == revision else { return }
                await Task.yield()
            }
            guard !Task.isCancelled, !self.stopped, self.stages[index].revision == revision else { return }
            self.stages[index].results = retained
            self.stages[index].status = !complete ? .loading : retained.count == Self.candidateLimit ? .partial : .ready
            self.publish()
        }
        // Keep completed queries alive for updates. Start stronger gathering
        // first, without waiting for filesystem validation of its value snapshot.
        if notification.name == NSNotification.Name.NSMetadataQueryDidFinishGathering, index == stages.count - 1 { startStage() }
    }

    nonisolated static func visibleDestination(_ url: URL) -> Bool {
        var current = url
        var isDestination = true
        while current.path != "/" {
            guard let flags = try? current.resourceValues(forKeys: [.isHiddenKey, .isPackageKey]),
                  flags.isHidden != true, isDestination || flags.isPackage != true else { return false }
            isDestination = false
            current.deleteLastPathComponent()
        }
        return true
    }

    private func publish() {
        let status: SourceStatus = stages.contains(where: { $0.status == .failed }) ? .failed
            : stages.count < 3 || stages.contains(where: { $0.status == .loading }) ? .loading
            : stages.contains(where: { $0.status == .partial }) ? .partial : .ready
        continuation.yield(SourceSnapshot(results: stages.flatMap(\.results), status: status))
    }

    private func stop() {
        guard !stopped else { return }
        stopped = true
        for stage in stages {
            stage.processing?.cancel()
            stage.query.stop()
            NotificationCenter.default.removeObserver(self, name: nil, object: stage.query)
        }
        stages.removeAll()
        continuation.finish()
    }
}
