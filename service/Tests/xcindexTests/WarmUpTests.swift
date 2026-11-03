import Foundation
import Testing
@testable import xcindex

/// Opening an IndexStoreDB on a large DataStore takes seconds; warmUp pays
/// that at launch so the first tool call reuses the cached querier.
@Suite("RequestProcessor.warmUp", .serialized)
struct WarmUpTests {
    @Test("warmUp opens and caches the querier the first query then reuses")
    func warmUpPopulatesCache() async throws {
        let fixture = try FixtureBuilder.buildCanaryIndex()
        let processor = RequestProcessor()

        let opened = await processor.warmUp(projectPath: nil, indexStorePath: fixture.storePath)
        #expect(opened)
        #expect(await processor.querierCacheCount() == 1)

        let lookup = await processor.handle(Request(
            op: "findSymbol",
            indexStorePath: fixture.storePath,
            symbolName: "UserService"
        ))
        #expect(lookup.symbols?.isEmpty == false)
        #expect(await processor.querierCacheCount() == 1)
    }

    @Test("warmUp outside an Xcode project is a quiet no-op")
    func warmUpWithoutProject() async throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xcindex-warm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let processor = RequestProcessor()
        let opened = await processor.warmUp(projectPath: dir.path)
        #expect(!opened)
        #expect(await processor.querierCacheCount() == 0)
    }
}
