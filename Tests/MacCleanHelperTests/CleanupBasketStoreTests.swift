import XCTest
@testable import MacCleanHelper

private struct BasketFixtureTrashMover: TrashMoving {
    let destination: URL
    func moveToTrash(_ url: URL) async throws -> URL {
        if url.lastPathComponent == "fail.txt" { throw TrashMoveFailure.cancelled }
        let target = destination.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: target)
        return target
    }
}

@MainActor
final class CleanupBasketStoreTests: XCTestCase {
    private struct Fixture {
        let root: URL
        let store: CleanupBasketStore
        let defaults: UserDefaults
        let suite: String
        init() throws {
            root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
                .appendingPathComponent("biu-basket-persistence-\(UUID())")
            store = try CleanupBasketStore(baseDirectory: root.appendingPathComponent("state"))
            suite = "Biu.BasketPersistence.\(UUID())"
            defaults = UserDefaults(suiteName: suite)!
        }
        @MainActor func model(engine: CleanupEngine = CleanupEngine()) -> DashboardModel {
            DashboardModel(folderStore: FolderBookmarkStore(defaults: defaults), receiptStore: nil,
                           snapshotStore: nil, basketStore: store, cleanupEngine: engine)
        }
        func cleanup() {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func item(_ path: String, category: CleanupCategory = .other) -> CleanupItem {
        CleanupItem(candidate: CleanupCandidate(path: path, logicalSize: 12, allocatedSize: 4096,
            tool: "테스트", category: category, modifiedAt: Date(timeIntervalSince1970: 123),
            detectionReason: "테스트", source: .folderScan, kind: category == .application ? .package : .regularFile),
            assessment: SafetyAssessment(risk: .review, reason: "테스트", impact: "파일은 그대로 유지"),
            recommendedAction: .moveToTrash)
    }

    func testRelaunchRestoresAppAndExplorerSelectionsButNotConfirmation() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let app = f.root.appendingPathComponent("Example.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let file = f.root.appendingPathComponent("keep.txt")
        try Data("keep".utf8).write(to: file)
        let first = f.model()
        first.toggleSelection(of: item(app.path, category: .application))
        first.toggleExplorerSelection(item(file.path), calculationIsComplete: true)
        let next = f.model()
        XCTAssertEqual(next.selectedIDs, [app.path, file.path])
        XCTAssertEqual(next.selectedSize, 8192)
        XCTAssertNil(next.confirmation)
        XCTAssertFalse(next.isCleaning)
        XCTAssertEqual(next.selectedItems.first(where: { $0.path == app.path })?.recommendedAction, .moveToTrash)
        XCTAssertEqual(try Data(contentsOf: file), Data("keep".utf8))
        let permissions = try FileManager.default.attributesOfItem(atPath: f.store.fileURL.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testRemoveAndClearArePersistedWithoutTouchingFiles() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let a = f.root.appendingPathComponent("a.txt"), b = f.root.appendingPathComponent("b.txt")
        try Data("a".utf8).write(to: a)
        try Data("b".utf8).write(to: b)
        let first = f.model()
        first.toggleSelection(of: item(a.path)); first.toggleSelection(of: item(b.path))
        first.removeFromBasket(a.path)
        let next = f.model()
        XCTAssertEqual(next.selectedIDs, [b.path])
        next.clearBasket()
        XCTAssertTrue(f.model().selectedItems.isEmpty)
        XCTAssertEqual(try f.store.load(), [])
        XCTAssertEqual(try Data(contentsOf: a), Data("a".utf8))
        XCTAssertEqual(try Data(contentsOf: b), Data("b".utf8))
    }

    func testParentDeduplicationSurvivesRelaunchAndMalformedDuplicateSnapshot() throws {
        let f = try Fixture(); defer { f.cleanup() }
        let parent = item(f.root.appendingPathComponent("project").path)
        let child = item(parent.path + "/build")
        let model = f.model()
        model.toggleSelection(of: child); model.toggleSelection(of: parent)
        XCTAssertEqual(f.model().selectedIDs, [parent.path])
        try f.store.save([child, parent, parent])
        let restored = f.model()
        XCTAssertEqual(restored.selectedIDs, [parent.path])
        XCTAssertEqual(restored.selectedSize, parent.size)
    }

    func testMissingSelectionIsRetainedButCannotBePrepared() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let missing = item(f.root.appendingPathComponent("offline.txt").path)
        let first = f.model(); first.toggleSelection(of: missing)
        let next = f.model()
        XCTAssertEqual(next.selectedIDs, [missing.id])
        next.prepareSelectedCleanup()
        for _ in 0..<200 where next.isPreparingCleanup { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(next.confirmation)
        XCTAssertEqual(next.preparationIssues.map(\.path), [missing.path])
        XCTAssertEqual(f.model().selectedIDs, [missing.id])
    }

    func testRestorationRechecksProtectionInsteadOfTrustingStoredAssessment() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try f.store.save([item("/System"), item("/Applications")])
        let restored = f.model()
        XCTAssertEqual(restored.selectedItems.count, 2, "Show protected selections so users can remove them")
        XCTAssertTrue(restored.selectedItems.allSatisfy { $0.assessment.risk == .avoid })
        XCTAssertNil(restored.confirmation)
    }

    func testCorruptionAndSaveFailureAreVisibleInsteadOfSilentlyLosingSelections() throws {
        let f = try Fixture(); defer { f.cleanup() }
        try Data("not json".utf8).write(to: f.store.fileURL)
        let corrupt = f.model()
        XCTAssertNotNil(corrupt.basketPersistenceError)
        XCTAssertTrue(corrupt.selectedItems.isEmpty)
        try FileManager.default.removeItem(at: f.store.fileURL)
        try FileManager.default.createDirectory(at: f.store.fileURL, withIntermediateDirectories: false)
        let model = f.model()
        let chosen = item(f.root.appendingPathComponent("keep.txt").path)
        model.toggleSelection(of: chosen)
        XCTAssertEqual(model.selectedIDs, [chosen.id])
        XCTAssertNotNil(model.basketPersistenceError)
    }

    func testSuccessfulCleanupIsRemovedAndFailedCleanupIsRestored() async throws {
        let f = try Fixture(); defer { f.cleanup() }
        let trash = f.root.appendingPathComponent("fixture-trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: false)
        let good = f.root.appendingPathComponent("good.txt"), fail = f.root.appendingPathComponent("fail.txt")
        try Data("good".utf8).write(to: good); try Data("keep".utf8).write(to: fail)
        let engine = CleanupEngine(trashMover: BasketFixtureTrashMover(destination: trash),
                                   authenticatedTrashMover: nil, runningApplicationProvider: { [] })
        let model = f.model(engine: engine)
        model.toggleSelection(of: item(good.path)); model.toggleSelection(of: item(fail.path))
        model.prepareSelectedCleanup()
        for _ in 0..<200 where model.isPreparingCleanup { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNotNil(model.confirmation)
        model.executeConfirmedCleanup()
        for _ in 0..<200 where model.isCleaning { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(model.cleanupResult?.succeededCount, 1)
        XCTAssertEqual(model.cleanupResult?.failedCount, 1)
        XCTAssertEqual(f.model().selectedIDs, [fail.path])
        XCTAssertEqual(try Data(contentsOf: fail), Data("keep".utf8))
    }
}
