import Foundation

/// Fixture-only export callers. Both source and destination roots must already
/// be marked disposable; validation accepts one direct package child only.
enum CollectionExportFixture {
    enum Failure: Error { case usage }

    static func run(_ action: String, root: URL, options: [String: String]) async throws -> CollectionRecovery.ExportResult {
        let location = try CollectionLocation.fixture(root)
        switch action {
        case "export":
            guard let path = options["--destination"] else { throw Failure.usage }
            let destination = try CollectionLocation.fixture(URL(fileURLWithPath: path))
            let store = try await CollectionStore.open(location)
            do {
                let result = try await CollectionRecovery.export(from: store, in: store.generation, to: destination.root)
                await store.close()
                return result
            } catch {
                await store.close()
                throw error
            }
        case "validate-export":
            guard let name = options["--package"], name.hasPrefix("Hana-export-"),
                  UUID(uuidString: String(name.dropFirst("Hana-export-".count))) != nil
            else { throw Failure.usage }
            return try await CollectionRecovery.validateExport(at: root.appendingPathComponent(name))
        default: throw Failure.usage
        }
    }
}
