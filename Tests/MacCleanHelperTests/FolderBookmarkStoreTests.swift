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
        XCTAssertEqual(restoredStore.selectedFolders.map(\.url.standardizedFileURL.path), [folder.path])
    }

    func testFolderAnalysisSelectionPersistsSeparatelyFromRegistration() throws {
        let suiteName = "Biu.FolderSelectionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("biu-selection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let firstStore = FolderBookmarkStore(defaults: defaults)
        try firstStore.add(folder)
        let registeredFolder = try XCTUnwrap(firstStore.folders.first)
        XCTAssertTrue(firstStore.isSelected(registeredFolder))

        firstStore.setSelected(false, for: registeredFolder)
        let restoredStore = FolderBookmarkStore(defaults: defaults)

        XCTAssertEqual(restoredStore.folders.count, 1)
        XCTAssertTrue(restoredStore.selectedFolders.isEmpty)
    }

    func testSelectAllSkipsStaleFoldersAndCanClearSelection() throws {
        let suiteName = "Biu.FolderSelectAllTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let available = FileManager.default.temporaryDirectory
            .appendingPathComponent("biu-available-\(UUID().uuidString)", isDirectory: true)
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("biu-missing-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: available, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: available) }

        let records = [
            RegisteredFolderRecord(path: available.path, bookmarkData: nil),
            RegisteredFolderRecord(path: missing.path, bookmarkData: nil)
        ]
        defaults.set(try JSONEncoder().encode(records), forKey: FolderBookmarkStore.storageKey)
        defaults.set([], forKey: FolderBookmarkStore.selectionKey)
        let store = FolderBookmarkStore(defaults: defaults)

        store.setAllSelected(true)
        XCTAssertEqual(store.selectedFolders.map(\.url.standardizedFileURL.path), [available.path])

        store.setAllSelected(false)
        XCTAssertTrue(store.selectedFolders.isEmpty)
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
