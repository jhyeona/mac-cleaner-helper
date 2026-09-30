import Foundation
import XCTest
@testable import MacCleanHelper

@MainActor
final class FolderBookmarkStoreTests: XCTestCase {
    func testRegisteredFolderSurvivesStoreRecreation() throws {
        let suiteName = "Biu.FolderBookmarkStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("biu-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let firstStore = FolderBookmarkStore(defaults: defaults)
        try firstStore.add(folder)
        let restoredStore = FolderBookmarkStore(defaults: defaults)

        XCTAssertEqual(restoredStore.folders.map(\.url.standardizedFileURL.path), [folder.path])
        XCTAssertFalse(try XCTUnwrap(restoredStore.folders.first).isStale)
    }

    func testFallsBackToSavedPathWhenBookmarkCannotBeResolved() throws {
        let suiteName = "Biu.FolderBookmarkFallbackTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("biu-fallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let records = [RegisteredFolderRecord(path: folder.path, bookmarkData: Data([0, 1, 2]))]
        defaults.set(try JSONEncoder().encode(records), forKey: FolderBookmarkStore.storageKey)

        let store = FolderBookmarkStore(defaults: defaults)

        XCTAssertEqual(store.folders.map(\.url.standardizedFileURL.path), [folder.path])
        XCTAssertFalse(try XCTUnwrap(store.folders.first).isStale)
    }
}
