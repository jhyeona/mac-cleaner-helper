import XCTest
@testable import MacCleanHelper

@MainActor
final class ExplorerNavigationTests: XCTestCase {
    func testCachedNavigationIsManualRefreshAndRejectsMissingPathsAndSymlinks() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("biu-navigation-\(UUID())")
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "Biu.Navigation.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = FolderExplorerCacheStore(fileURL: root.appendingPathComponent("cache/cache.json"))
        try cache.save(folder: folder, entries: [], scannedAt: Date(), isComplete: true)
        let model = FolderExplorerModel(folderStore: FolderBookmarkStore(defaults: defaults), cache: cache)
        model.showLocations()
        XCTAssertFalse(model.canGoUp)
        model.openPath(folder.path)
        XCTAssertEqual(model.currentURL?.path, folder.path)
        XCTAssertFalse(model.isScanning)

        try Data("new".utf8).write(to: folder.appendingPathComponent("new.txt"))
        XCTAssertTrue(model.entries.isEmpty)
        model.refresh()
        for _ in 0..<500 {
            if !model.isScanning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.isScanning)
        XCTAssertEqual(model.entries.map(\.name), ["new.txt"])
        model.searchText = "new.txt"
        model.requestOpen(root)
        XCTAssertEqual(model.searchText, "")
        model.cancel()
        model.requestOpen(folder)
        model.openPath(root.appendingPathComponent("missing").path)
        XCTAssertEqual(model.currentURL?.path, folder.path)
        XCTAssertNotNil(model.errorMessage)
        let link = root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        model.requestOpen(link)
        XCTAssertEqual(model.currentURL?.path, folder.path)
        model.refresh()
        model.cancel()
        XCTAssertFalse(model.isScanning)
        XCTAssertFalse(model.entries.contains { $0.calculationState == .calculating || $0.calculationState == .pending })
        XCTAssertNotNil(model.staleMessage)
    }

    func testCleanupInvalidatesStartupVolumeCache() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("biu-root-cache-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = FolderExplorerCacheStore(fileURL: root.appendingPathComponent("cache/cache.json"))
        try cache.save(folder: URL(fileURLWithPath: "/"), entries: [], scannedAt: Date(), isComplete: true)
        cache.invalidate(targetPaths: ["/tmp/example/payload"])
        XCTAssertNil(cache.load(path: "/", touch: false))
    }

    func testLeavingCachedFolderDoesNotRewriteItsScanOrModificationTime() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("biu-cache-age-\(UUID())")
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "Biu.CacheAge.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = FolderExplorerCacheStore(fileURL: root.appendingPathComponent("cache/cache.json"))
        try cache.save(folder: folder, entries: [], scannedAt: Date(timeIntervalSince1970: 100), isComplete: true)
        let before = try XCTUnwrap(cache.load(path: folder.path, touch: false))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 200)], ofItemAtPath: folder.path)
        let model = FolderExplorerModel(folderStore: FolderBookmarkStore(defaults: defaults), cache: cache)
        XCTAssertNotNil(model.staleMessage)
        model.showLocations()
        let after = try XCTUnwrap(cache.load(path: folder.path, touch: false))
        XCTAssertEqual(after.snapshot.scannedAt, before.snapshot.scannedAt)
        XCTAssertEqual(after.snapshot.folderModifiedAt, before.snapshot.folderModifiedAt)
        XCTAssertNotNil(after.staleReason)
        model.requestOpen(folder)
        model.clearCache()
        model.showLocations()
        XCTAssertEqual(cache.count, 0)
    }
}
