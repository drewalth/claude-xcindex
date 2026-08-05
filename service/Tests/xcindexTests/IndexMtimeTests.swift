import Foundation
import Testing
@testable import xcindex

/// Covers `IndexQuerier.newestDirectoryWrite(inTreeAt:)`, the freshness basis for
/// `xcindex_status` and — by the same reasoning — for `hooks/session-start.sh`.
///
/// The regression these pin: reading the DataStore ROOT's mtime under-reports
/// freshness permanently. The indexer writes into `v5/units` and `v5/records`,
/// which bumps those directories and never the root, so a store rebuilt minutes
/// ago still reports the date it was first created. Downstream that surfaced as a
/// standing false "stale" alarm against an index that was in fact current.
///
/// These need no IndexStore and no Xcode — they build a directory tree and stamp
/// mtimes directly — so they stay in the fast half of the suite. Each test gets a
/// uniquely-named temp root, so they are parallel-safe.
@Suite("Index mtime")
struct IndexMtimeTests {
    private static let old = Date(timeIntervalSince1970: 1_000_000)
    private static let recent = Date(timeIntervalSince1970: 2_000_000)

    /// Build `<root>/v5/units` and stamp each level with an explicit mtime.
    ///
    /// Stamped deepest-first: creating the tree bumps every ancestor, so the
    /// parents have to be set after the children they contain.
    private func makeStore(root: Date, v5: Date, units: Date) throws -> URL {
        let fm = FileManager.default
        let storeRoot = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("xcindex-mtime-\(UUID().uuidString)")
        let unitsURL = storeRoot.appendingPathComponent("v5/units")
        try fm.createDirectory(at: unitsURL, withIntermediateDirectories: true)

        for (url, date) in [
            (unitsURL, units),
            (storeRoot.appendingPathComponent("v5"), v5),
            (storeRoot, root)
        ] {
            try fm.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
        return storeRoot
    }

    /// Filesystem timestamp round-tripping is not bit-exact across filesystems;
    /// one second is far tighter than the multi-day error being tested for.
    private func isSameInstant(_ lhs: Date, _ rhs: Date) -> Bool {
        abs(lhs.timeIntervalSince(rhs)) < 1
    }

    @Test("reports the newest nested write, not the frozen root")
    func newestNestedWriteWins() throws {
        let storeRoot = try makeStore(root: Self.old, v5: Self.old, units: Self.recent)
        defer { try? FileManager.default.removeItem(at: storeRoot) }

        let found = try #require(IndexQuerier.newestDirectoryWrite(inTreeAt: storeRoot.path))
        #expect(
            isSameInstant(found, Self.recent),
            "reading the root alone would have reported \(Self.old), got \(found)"
        )
    }

    @Test("uses the root when the root is the newest thing in the tree")
    func rootWinsWhenNewest() throws {
        let storeRoot = try makeStore(root: Self.recent, v5: Self.old, units: Self.old)
        defer { try? FileManager.default.removeItem(at: storeRoot) }

        let found = try #require(IndexQuerier.newestDirectoryWrite(inTreeAt: storeRoot.path))
        #expect(isSameInstant(found, Self.recent))
    }

    @Test("a missing store is nil, so callers can say 'not found' rather than 1970")
    func missingStoreIsNil() {
        let absent = NSTemporaryDirectory() + "/xcindex-absent-\(UUID().uuidString)"
        #expect(IndexQuerier.newestDirectoryWrite(inTreeAt: absent) == nil)
    }
}
