import Foundation
import Testing
@testable import Hana

@Suite(.timeLimit(.minutes(1)))
struct CollectionExportHarnessTests {
    @Test func organizedCollectionSurvivesFreshProcessExportAndIndependentReconstruction() async throws {
        let root = try HarnessRoot()
        let destination = root.directory.appendingPathComponent("exports")
        _ = try Harness.run(["create-root", destination.path]).event("fixture.root-created")
        let store = try await CollectionStore.open(CollectionLocation.fixture(URL(fileURLWithPath: root.path)))
        let organized = try await OrganizedCollection.build(in: store, clock: FixedClock(Date()))
        await store.close()
        let sentinel = "HANA-UNSAVED-EXPORT-\(UUID().uuidString)"
        let rejected = try Harness.run(["create-note", root.path, "--operation", UUID().uuidString, "--fail", "before-commit"], stdin: sentinel)
        #expect(rejected.status == 1)
        let exported = try Harness.run(["export", root.path, "--destination", destination.path])
        #expect(exported.status == 0)
        let event = exported.event("collection.exported")
        let name = try #require(event["package"] as? String)
        let package = destination.appendingPathComponent(name)
        #expect(try IndependentExportDecoder.views(IndependentExportDecoder.records(at: package)) == organized.views)
        let checked = try Harness.run(["validate-export", destination.path, "--package", name])
        #expect(checked.status == 0 && checked.event("export.validated")["noteCount"] as? Int == 7)
        #expect(try root.files(containing: sentinel).isEmpty)
        let files = try #require(FileManager.default.enumerator(at: package, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in files.allObjects where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
            let data = try Data(contentsOf: url)
            #expect(data.range(of: Data(sentinel.utf8)) == nil)
            for excluded in ["creation_receipt", "operation_id", "externalReferences", "usageHistory"] {
                #expect(data.range(of: Data(excluded.utf8)) == nil)
            }
        }
        #expect((exported.output + checked.output + rejected.output).range(of: Data(sentinel.utf8)) == nil)
        let live = try Harness.run(["export", root.path, "--destination", CollectionLocation.defaultLiveRoot.path])
        #expect(live.status == 1)
        let traversal = try Harness.run(["validate-export", destination.path, "--package", "../Collection"])
        #expect(traversal.status == 1)
    }
}
