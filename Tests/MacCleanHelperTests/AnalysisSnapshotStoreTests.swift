import Foundation
import XCTest
@testable import MacCleanHelper

@MainActor
final class AnalysisSnapshotStoreTests: XCTestCase {
    func testPersistsAndRestoresLastCompletedAnalysis() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("biu-snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AnalysisSnapshotStore(baseDirectory: root)
        let savedAt = Date(timeIntervalSince1970: 1_700_000_000)
        let item = CleanupItem(
            candidate: CleanupCandidate(
                path: "/tmp/build-cache",
                logicalSize: 1_024,
                allocatedSize: 4_096,
                tool: "테스트 도구",
                category: .cache,
                modifiedAt: savedAt,
                detectionReason: "테스트 캐시",
                source: .detectorPack("test"),
                kind: .directory
            ),
            assessment: SafetyAssessment(
                risk: .safe,
                reason: "다시 만들 수 있음",
                impact: "다음 실행이 느릴 수 있음",
                recovery: .regenerated
            ),
            recommendedAction: .deleteRegeneratableCache
        )
        let expected = AnalysisSnapshot(
            savedAt: savedAt,
            scannedFolderPaths: ["/tmp"],
            items: [item],
            issues: [ScanIssue(path: "/tmp/locked", message: "접근 거부")]
        )

        try store.save(expected)
        let restored = try store.load()

        XCTAssertEqual(restored, expected)
    }

    func testDeleteRemovesSavedAnalysis() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("biu-snapshot-delete-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AnalysisSnapshotStore(baseDirectory: root)
        try store.save(AnalysisSnapshot(scannedFolderPaths: [], items: [], issues: []))

        try store.delete()

        XCTAssertNil(try store.load())
    }

    func testDashboardRestoresSnapshotWithoutSelectingItems() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("biu-dashboard-restore-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AnalysisSnapshotStore(baseDirectory: root)
        let item = CleanupItem(
            path: "/tmp/restored-cache",
            size: 8_192,
            category: .cache,
            assessment: SafetyAssessment(
                risk: .safe,
                reason: "복원 테스트",
                impact: "없음"
            )
        )
        let savedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try store.save(AnalysisSnapshot(
            savedAt: savedAt,
            scannedFolderPaths: ["/tmp/project"],
            items: [item],
            issues: []
        ))
        let suiteName = "Biu.AnalysisRestoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = DashboardModel(
            folderStore: FolderBookmarkStore(defaults: defaults),
            receiptStore: nil,
            snapshotStore: store
        )

        XCTAssertEqual(model.items.map(\.path), [item.path])
        XCTAssertEqual(model.items.first?.candidate.allocatedSize, item.candidate.allocatedSize)
        XCTAssertEqual(model.items.first?.assessment.risk, .review)
        XCTAssertEqual(model.scannedFolders.map(\.path), ["/tmp/project"])
        XCTAssertEqual(model.lastAnalysisAt, savedAt)
        XCTAssertTrue(model.selectedIDs.isEmpty)
    }

    func testDashboardRechecksStoredSafetyAssessmentWithCurrentRules() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("biu-safety-refresh-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AnalysisSnapshotStore(baseDirectory: root)
        let outdatedItem = CleanupItem(
            candidate: CleanupCandidate(
                path: "/Applications",
                logicalSize: 10,
                allocatedSize: 10,
                tool: "파일 시스템",
                category: .other,
                modifiedAt: nil,
                detectionReason: "이전 판정",
                source: .folderScan,
                kind: .directory
            ),
            assessment: SafetyAssessment(
                risk: .review,
                reason: "이전에는 확인 필요였음",
                impact: "이전 영향"
            ),
            recommendedAction: .moveToTrash
        )
        try store.save(AnalysisSnapshot(
            scannedFolderPaths: ["/"],
            items: [outdatedItem],
            issues: []
        ))
        let suiteName = "Biu.SafetyRefreshTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let model = DashboardModel(
            folderStore: FolderBookmarkStore(defaults: defaults),
            receiptStore: nil,
            snapshotStore: store
        )

        XCTAssertEqual(model.items.first?.assessment.risk, .avoid)
        if case .manualInstructions = model.items.first?.recommendedAction {
            // 기대한 보호 작업 방식
        } else {
            XCTFail("최신 보호 규칙이 수동 안내로 갱신되지 않음")
        }
    }

    func testRegisteredFolderStartsInReadyStateInsteadOfGreeting() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("biu-ready-state-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let suiteName = "Biu.ReadyStateTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let folderStore = FolderBookmarkStore(defaults: defaults)
        try folderStore.add(root)

        let model = DashboardModel(
            folderStore: folderStore,
            receiptStore: nil,
            snapshotStore: nil
        )

        XCTAssertEqual(model.biuState, .resting)
        XCTAssertTrue(model.assistantMessage.contains("준비됐어요"))
    }

    func testHomeFolderRequiresScopeConfirmationBeforeScan() throws {
        let suiteName = "Biu.BroadFolderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let folderStore = FolderBookmarkStore(defaults: defaults)
        try folderStore.add(FileManager.default.homeDirectoryForCurrentUser)
        let model = DashboardModel(
            folderStore: folderStore,
            receiptStore: nil,
            snapshotStore: nil
        )

        model.requestRegisteredFolderScan()

        XCTAssertTrue(model.hasBroadRegisteredFolder)
        XCTAssertTrue(model.showBroadFolderWarning)
        XCTAssertFalse(model.isScanning)
    }

    func testMissingRegisteredFolderIsBlockedBeforeScan() throws {
        let suiteName = "Biu.StaleFolderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("biu-missing-\(UUID().uuidString)", isDirectory: true)
            .path
        defaults.set(
            try JSONEncoder().encode([RegisteredFolderRecord(path: missingPath, bookmarkData: nil)]),
            forKey: FolderBookmarkStore.storageKey
        )
        let model = DashboardModel(
            folderStore: FolderBookmarkStore(defaults: defaults),
            receiptStore: nil,
            snapshotStore: nil
        )

        model.requestRegisteredFolderScan()

        XCTAssertFalse(model.isScanning)
        XCTAssertNotNil(model.errorMessage)
    }

    func testRemovingScannedFolderAlsoRemovesItsRestoredResults() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("biu-remove-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suiteName = "Biu.RemoveFolderTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let folderStore = FolderBookmarkStore(defaults: defaults)
        try folderStore.add(root)
        let snapshotDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("biu-remove-snapshot-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: snapshotDirectory) }
        let snapshotStore = try AnalysisSnapshotStore(baseDirectory: snapshotDirectory)
        let item = CleanupItem(
            path: root.appendingPathComponent("cache").path,
            size: 1_024,
            category: .cache,
            assessment: SafetyAssessment(risk: .review, reason: "테스트", impact: "테스트")
        )
        try snapshotStore.save(AnalysisSnapshot(
            scannedFolderPaths: [root.path],
            items: [item],
            issues: []
        ))
        let model = DashboardModel(
            folderStore: folderStore,
            receiptStore: nil,
            snapshotStore: snapshotStore
        )

        model.removeRegisteredFolder(try XCTUnwrap(folderStore.folders.first))

        XCTAssertTrue(folderStore.folders.isEmpty)
        XCTAssertTrue(model.items.isEmpty)
        XCTAssertTrue(model.scannedFolders.isEmpty)
    }

    func testCleanupResultSeparatesSuccessFailureAndReclaimedSize() {
        let success = CleanupReceipt(
            path: "/tmp/a", action: .moveToTrash,
            sizeBefore: 2_048, sizeAfter: 0, estimatedBytes: 2_048,
            availableCapacityChange: nil, succeeded: true, failureReason: nil
        )
        let failure = CleanupReceipt(
            path: "/tmp/b", action: .moveToTrash,
            sizeBefore: 4_096, sizeAfter: 4_096, estimatedBytes: 4_096,
            availableCapacityChange: nil, succeeded: false, failureReason: "실패"
        )

        let result = CleanupResult(receipts: [success, failure])

        XCTAssertEqual(result.succeededCount, 1)
        XCTAssertEqual(result.failedCount, 1)
        XCTAssertEqual(result.reclaimedBytes, 2_048)
    }

    func testCleanupPreparationCreatesReviewableConfirmationWithoutChangingTarget() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("biu-prepare-\(UUID().uuidString)", isDirectory: true)
        let target = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshotStore = try AnalysisSnapshotStore(baseDirectory: root.appendingPathComponent("snapshot"))
        let item = CleanupItem(
            candidate: CleanupCandidate(
                path: target.path,
                logicalSize: 1_024,
                allocatedSize: 1_024,
                tool: "테스트",
                category: .cache,
                modifiedAt: nil,
                detectionReason: "준비 테스트",
                source: .folderScan,
                kind: .directory
            ),
            assessment: SafetyAssessment(
                risk: .review,
                reason: "확인",
                impact: "휴지통 이동"
            ),
            recommendedAction: .moveToTrash
        )
        try snapshotStore.save(AnalysisSnapshot(
            scannedFolderPaths: [root.path],
            items: [item],
            issues: []
        ))
        let suiteName = "Biu.PrepareTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = DashboardModel(
            folderStore: FolderBookmarkStore(defaults: defaults),
            receiptStore: nil,
            snapshotStore: snapshotStore
        )
        model.toggleSelection(of: item)

        model.prepareSelectedCleanup()
        for _ in 0..<100 where model.confirmation == nil && model.errorMessage == nil {
            try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertFalse(model.isPreparingCleanup)
        XCTAssertEqual(model.confirmation?.preparations.first?.action, .moveToTrash)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
    }

    func testCancellingNewScanRestoresPreviousCompletedAnalysis() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("biu-cancel-restore-\(UUID().uuidString)", isDirectory: true)
        let scanRoot = root.appendingPathComponent("new-scan", isDirectory: true)
        try FileManager.default.createDirectory(at: scanRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let snapshotStore = try AnalysisSnapshotStore(baseDirectory: root.appendingPathComponent("snapshot"))
        let previousItem = CleanupItem(
            path: "/tmp/previous-result",
            size: 2_048,
            category: .cache,
            assessment: SafetyAssessment(risk: .review, reason: "이전", impact: "이전")
        )
        let previousDate = Date(timeIntervalSince1970: 1_800_000_000)
        try snapshotStore.save(AnalysisSnapshot(
            savedAt: previousDate,
            scannedFolderPaths: ["/tmp/previous"],
            items: [previousItem],
            issues: []
        ))
        let suiteName = "Biu.CancelRestoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let model = DashboardModel(
            folderStore: FolderBookmarkStore(defaults: defaults),
            receiptStore: nil,
            snapshotStore: snapshotStore
        )
        let restoredBeforeScan = model.items

        model.scan(folder: scanRoot)
        XCTAssertTrue(model.isScanning)
        model.cancelScan()

        XCTAssertFalse(model.isScanning)
        XCTAssertEqual(model.items, restoredBeforeScan)
        XCTAssertEqual(model.items.map(\.path), [previousItem.path])
        XCTAssertEqual(model.scannedFolders.map(\.path), ["/tmp/previous"])
        XCTAssertEqual(model.lastAnalysisAt, previousDate)
    }
}
