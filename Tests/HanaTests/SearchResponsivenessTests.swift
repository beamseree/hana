import Foundation
import Testing
@testable import Hana

/// Live-index performance regression, opt-in because index/host load vary.
/// Requires existing indexed Hana fixtures; not permission or physical typing proof.
@Suite(.serialized)
@MainActor
struct SearchResponsivenessTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HANA_PERFORMANCE_CHECK"] == "1"))
    func liveIndexedSearchLeavesInputActorResponsive() async throws {
        let search = Search(roots: ApplicationCatalog.conventionalRoots, indexedFiles: true, debounce: .zero)
        var worstDelay = 0.0
        var fileSeen = false
        let heartbeat = Task {
            while !Task.isCancelled {
                let start = ProcessInfo.processInfo.systemUptime
                do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
                worstDelay = max(worstDelay, (ProcessInfo.processInfo.systemUptime - start) * 1000 - 5)
            }
        }
        defer { heartbeat.cancel() }
        for _ in 0..<5 {
            let stream = search.search(Search.Request(text: "Hana"))
            let receiver = Task {
                for await batch in stream {
                    fileSeen = fileSeen || batch.results.contains { $0.kind != .application }
                }
            }
            try await Task.sleep(for: .seconds(1))
            receiver.cancel()
        }
        heartbeat.cancel()
        await heartbeat.value
        #expect(fileSeen, "Requires existing indexed Hana fixtures")
        #expect(worstDelay < 50, "Main-actor scheduling excess: \(worstDelay) ms")
    }
}
