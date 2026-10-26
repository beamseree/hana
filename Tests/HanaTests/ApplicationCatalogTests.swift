import Foundation
import Testing
@testable import Hana

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct ApplicationCatalogTests {
    @Test func idleCatalogDoesNoFilesystemWorkAfterLaunch() async throws {
        // A conventional root on the sealed system volume: real applications,
        // and no recent changes still to be reported.
        let catalog = ApplicationCatalog(roots: [URL(fileURLWithPath: "/System/Library/CoreServices/Applications")])
        await catalog.wait { $0.status == .ready }
        try await Task.sleep(for: .seconds(3))
        #expect(catalog.scans == 1)
    }

    @Test func rewritingFilesInsideABundleCausesNoRescan() async throws {
        let root = try temporaryRoot(apps: ["Updating.app/Contents/Resources"])
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try await settledCatalog(root)
        let settled = catalog.scans
        // Waves spread over several coalescing windows, like a long app update.
        let resources = root.appendingPathComponent("Updating.app/Contents/Resources")
        for wave in 0..<5 {
            for file in 0..<40 { try Data().write(to: resources.appendingPathComponent("\(wave)-\(file).dat")) }
            try await Task.sleep(for: .milliseconds(700))
        }
        // Events arrive in order, so the sentinel's rescan follows every wave's.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sentinel.app"), withIntermediateDirectories: true)
        await catalog.wait { $0.results.contains { $0.name == "Sentinel" } }
        // The sentinel's rescan, allowing its report to be split in two.
        #expect(catalog.scans - settled <= 2)
    }

    @Test func aBurstOfChangesCoalescesIntoFewRescans() async throws {
        let root = try temporaryRoot(apps: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try await settledCatalog(root)
        let settled = catalog.scans
        // Many organizational folders, like a large suite's installation.
        for index in 0..<300 {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Suite/Resources \(index)/Data"),
                                                    withIntermediateDirectories: true)
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Suite/Tool.app"), withIntermediateDirectories: true)
        await catalog.wait { $0.results.contains { $0.name == "Tool" } }
        #expect(catalog.scans - settled <= 3)
    }

    @Test func aLongInstallationRescansAtABoundedRate() async throws {
        let root = try temporaryRoot(apps: [])
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try await settledCatalog(root)
        let settled = catalog.scans
        // A new folder every quarter second for four seconds, spanning many
        // coalescing windows.
        for index in 0..<16 {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Suite/Part \(index)"), withIntermediateDirectories: true)
            try await Task.sleep(for: .milliseconds(250))
        }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Suite/Tool.app"), withIntermediateDirectories: true)
        await catalog.wait { $0.results.contains { $0.name == "Tool" } }
        #expect(catalog.scans - settled <= 4)
    }
}

private func temporaryRoot(apps: [String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for app in apps {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(app), withIntermediateDirectories: true)
    }
    return root
}

/// A launched catalog after the reports of its fixture's creation, made just
/// before watching began, have had time to arrive.
@MainActor
private func settledCatalog(_ root: URL) async throws -> ApplicationCatalog {
    let catalog = ApplicationCatalog(roots: [root])
    await catalog.wait { $0.status == .ready }
    try await Task.sleep(for: .seconds(2))
    return catalog
}

private extension ApplicationCatalog {
    /// Waits until a snapshot satisfies the condition.
    func wait(until condition: (SourceSnapshot) -> Bool) async {
        for await snapshot in snapshots() where condition(snapshot) { return }
    }
}
