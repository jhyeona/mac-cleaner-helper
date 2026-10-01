import Darwin
import XCTest
@testable import MacCleanHelper

final class FolderExplorerScannerTests: XCTestCase {
    func testDiscoversAllChildrenBeforeDirectoryMeasurementsFinish() async throws {
        let root = try makeTemporaryDirectory("stream")
        defer { try? FileManager.default.removeItem(at: root) }
        let folderA = root.appendingPathComponent("A", isDirectory: true)
        let folderB = root.appendingPathComponent("B", isDirectory: true)
        try FileManager.default.createDirectory(at: folderA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: folderB, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4_096).write(to: folderA.appendingPathComponent("a.bin"))
        try Data(repeating: 2, count: 8_192).write(to: folderB.appendingPathComponent("b.bin"))
        try Data("hidden".utf8).write(to: root.appendingPathComponent(".hidden"))

        var discovered: [ExplorerEntry] = []
        var completed: [ExplorerEntry] = []
        var discoveryCountAtFirstCompletion: Int?
        for try await event in FolderExplorerScanner().events(at: root) {
            switch event {
            case .childDiscovered(let entry): discovered.append(entry)
            case .sizeCalculationCompleted(let entry):
                discoveryCountAtFirstCompletion = discoveryCountAtFirstCompletion ?? discovered.count
                completed.append(entry)
            default: break
            }
        }

        XCTAssertEqual(discovered.count, 3)
        XCTAssertEqual(discoveryCountAtFirstCompletion, 3)
        XCTAssertEqual(completed.count, 2)
        XCTAssertTrue(discovered.contains { $0.name == ".hidden" && $0.isHidden })
        XCTAssertTrue(completed.allSatisfy { $0.calculationState == .complete && $0.logicalSize > 0 })
    }

    func testReportsSparseLogicalAndAllocatedSizeAndDoesNotFollowSymlink() async throws {
        let root = try makeTemporaryDirectory("sparse")
        defer { try? FileManager.default.removeItem(at: root) }
        let sparse = root.appendingPathComponent("sparse.bin")
        let descriptor = open(sparse.path, O_CREAT | O_WRONLY, 0o600)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        XCTAssertEqual(ftruncate(descriptor, 8 * 1_024 * 1_024), 0)
        close(descriptor)
        let link = root.appendingPathComponent("sparse-link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sparse)

        var results: [String: ExplorerEntry] = [:]
        for try await event in FolderExplorerScanner().events(at: root) {
            if case .childDiscovered(let entry) = event { results[entry.name] = entry }
        }

        let sparseEntry = try XCTUnwrap(results["sparse.bin"])
        XCTAssertEqual(sparseEntry.logicalSize, 8 * 1_024 * 1_024)
        XCTAssertLessThan(sparseEntry.allocatedSize, sparseEntry.logicalSize)
        let linkEntry = try XCTUnwrap(results["sparse-link"])
        XCTAssertEqual(linkEntry.kind, .symbolicLink)
        XCTAssertLessThan(linkEntry.logicalSize, sparseEntry.logicalSize)
    }

    func testRecognizesPackageWithoutAutomaticallyEnteringIt() async throws {
        let root = try makeTemporaryDirectory("package")
        defer { try? FileManager.default.removeItem(at: root) }
        let package = root.appendingPathComponent("Sample.app", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data(repeating: 3, count: 2_048).write(to: package.appendingPathComponent("payload"))

        var discovered: ExplorerEntry?
        var completed: ExplorerEntry?
        for try await event in FolderExplorerScanner().events(at: root) {
            if case .childDiscovered(let entry) = event { discovered = entry }
            if case .sizeCalculationCompleted(let entry) = event { completed = entry }
        }

        XCTAssertEqual(discovered?.kind, .package)
        XCTAssertEqual(discovered?.calculationState, .pending)
        XCTAssertEqual(completed?.kind, .package)
        XCTAssertGreaterThan(completed?.allocatedSize ?? 0, 0)
    }

    private func makeTemporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("biu-explorer-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

@MainActor
final class FolderExplorerCacheTests: XCTestCase {
    func testKeepsOnlyOneHundredMostRecentlySavedFolders() throws {
        let root = try makeTemporaryDirectory("lru")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = FolderExplorerCacheStore(fileURL: root.appendingPathComponent("cache/cache.json"))
        var folders: [URL] = []
        for index in 0..<105 {
            let folder = root.appendingPathComponent("folder-\(index)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            folders.append(folder)
            try store.save(folder: folder, entries: [], scannedAt: Date(), isComplete: true)
        }

        XCTAssertEqual(store.count, 100)
        XCTAssertNil(store.load(path: folders[0].path, touch: false))
        XCTAssertNotNil(store.load(path: folders[104].path, touch: false))
    }

    func testRestoresLastLocationAndMarksChangedFolderStale() throws {
        let root = try makeTemporaryDirectory("restore")
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("folder", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let storeURL = root.appendingPathComponent("cache/cache.json")
        let store = FolderExplorerCacheStore(fileURL: storeURL)
        try store.save(folder: folder, entries: [], scannedAt: Date(), isComplete: true)

        let restored = FolderExplorerCacheStore(fileURL: storeURL).loadLastAvailable()
        XCTAssertEqual(restored?.snapshot.folderPath, folder.path)
        XCTAssertNil(restored?.staleReason)

        Thread.sleep(forTimeInterval: 1.05)
        try Data("change".utf8).write(to: folder.appendingPathComponent("new.txt"))
        let stale = FolderExplorerCacheStore(fileURL: storeURL).load(path: folder.path, touch: false)
        XCTAssertNotNil(stale?.staleReason)
    }

    func testInvalidatingTargetAlsoInvalidatesCachedAncestors() throws {
        let root = try makeTemporaryDirectory("invalidate")
        defer { try? FileManager.default.removeItem(at: root) }
        let parent = root.appendingPathComponent("parent", isDirectory: true)
        let child = parent.appendingPathComponent("child", isDirectory: true)
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        let store = FolderExplorerCacheStore(fileURL: root.appendingPathComponent("cache/cache.json"))
        try store.save(folder: root, entries: [], scannedAt: Date(), isComplete: true)
        try store.save(folder: parent, entries: [], scannedAt: Date(), isComplete: true)
        try store.save(folder: child, entries: [], scannedAt: Date(), isComplete: true)

        store.invalidate(targetPaths: [child.appendingPathComponent("payload").path])

        XCTAssertNil(store.load(path: root.path, touch: false))
        XCTAssertNil(store.load(path: parent.path, touch: false))
        XCTAssertNil(store.load(path: child.path, touch: false))
    }

    func testShellCommandEscapesSingleQuotes() {
        XCTAssertEqual(
            FolderExplorerModel.shellQuote("/tmp/it's here"),
            "'/tmp/it'\"'\"'s here'"
        )
    }

    private func makeTemporaryDirectory(_ name: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("biu-cache-\(name)-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
