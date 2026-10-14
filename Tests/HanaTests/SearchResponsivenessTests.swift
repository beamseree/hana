import AppKit
import Testing
@testable import Hana

/// Live-index input-queue regression, opt-in because index/host load vary.
/// Requires AppKit and indexed Hana fixtures; not physical shortcut/typing proof.
@Suite(.serialized)
@MainActor
struct SearchResponsivenessTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["HANA_PERFORMANCE_CHECK"] == "1"))
    func liveIndexedSearchKeepsInputQueueResponsive() async throws {
        // Match the app's main-queue integration. A Foundation-only SwiftPM
        // async-main runner is not the native app's event-loop environment.
        _ = NSApplication.shared
        let previousPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        defer { NSApp.setActivationPolicy(previousPolicy) }
        let search = Search(roots: ApplicationCatalog.conventionalRoots, indexedFiles: true, typingGap: .zero)
        // Real icon loading, as visible application rows request it.
        let icons = ResultIcons()
        var iconsLoaded = 0
        var iconLoads: [Task<Void, Never>] = []
        var worstSleepExcess = 0.0
        var fileSeen = false
        var samples = 0
        let input = InputProbeState()
        // Start the clock when a callback is ready to enter the input queue,
        // excluding timer wake-up and cooperative-executor scheduling before it.
        let producer = DispatchSource.makeTimerSource(queue: DispatchQueue(label: "HanaTests.input", qos: .userInitiated))
        producer.schedule(deadline: .now() + .milliseconds(5), repeating: .milliseconds(5))
        producer.setEventHandler { @Sendable in
            let sent = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.async {
                input.samples += 1
                input.worstDelay = max(input.worstDelay, (ProcessInfo.processInfo.systemUptime - sent)*1000)
            }
        }
        producer.resume()
        defer { producer.cancel() }
        // Retain the old metric for diagnosis. Task.sleep excess alone does not
        // establish that the input queue was blocked during that interval.
        let heartbeat = Task {
            while !Task.isCancelled {
                let start = ProcessInfo.processInfo.systemUptime
                do { try await Task.sleep(for: .milliseconds(5)) } catch { return }
                samples += 1
                worstSleepExcess = max(worstSleepExcess, (ProcessInfo.processInfo.systemUptime - start) * 1000 - 5)
            }
        }
        defer { heartbeat.cancel() }
        for _ in 0..<5 {
            let stream = search.search(Search.Request(text: "Hana"))
            let receiver = Task {
                for await batch in stream {
                    fileSeen = fileSeen || batch.results.contains { $0.kind != .application }
                    for result in batch.results.prefix(SearchResultsView.maxVisibleRows) where result.kind == .application {
                        iconLoads.append(Task { if await icons.icon(for: result.url, scale: 2) != nil { iconsLoaded += 1 } })
                    }
                }
            }
            defer { receiver.cancel() }
            try await Task.sleep(for: .seconds(1))
        }
        heartbeat.cancel()
        await heartbeat.value
        for load in iconLoads { await load.value }
        // Cancel the producer and drain callbacks already submitted by it.
        await withCheckedContinuation { (finished: CheckedContinuation<Void, Never>) in
            producer.setCancelHandler { @Sendable in
                DispatchQueue.main.async { finished.resume() }
            }
            producer.cancel()
        }
        print("Sleep scheduling diagnostic: samples=\(samples), maximumExcessMs=\(worstSleepExcess)")
        #expect(fileSeen, "Requires existing indexed Hana fixtures")
        print("Input-queue scheduling: samples=\(input.samples), maximumEnqueueDelayMs=\(input.worstDelay), iconsLoaded=\(iconsLoaded)")
        #expect(iconsLoaded > 0, "Requires an installed application matching the query")
        #expect(input.samples > 50)
        #expect(input.worstDelay < 50, "Input queue enqueue-to-execution: \(input.worstDelay) ms")
    }
}

@MainActor
private final class InputProbeState {
    var samples = 0
    var worstDelay = 0.0
}
