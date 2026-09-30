import XCTest
@testable import MacCleanHelper

final class CleanupEngineTests: XCTestCase {
    func testVerifiedCacheCanBeDeletedAndProducesSuccessfulReceipt() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("biu-cleanup-execute-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("cache".utf8).write(to: root.appendingPathComponent("payload"))
        defer { try? FileManager.default.removeItem(at: root) }

        let item = verifiedCacheItem(at: root)
        let engine = CleanupEngine()
        let preparation = try await engine.prepare(item: item)
        let receipt = await engine.execute(preparation)

        XCTAssertTrue(receipt.succeeded, receipt.failureReason ?? "")
        XCTAssertEqual(receipt.action, .deleteRegeneratableCache)
        XCTAssertEqual(receipt.sizeAfter, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testExecutionStopsWhenPreparedTargetWasReplaced() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("biu-cleanup-replaced-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let item = verifiedCacheItem(at: root)
        let engine = CleanupEngine()
        let preparation = try await engine.prepare(item: item)

        try FileManager.default.removeItem(at: root)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let receipt = await engine.execute(preparation)

        XCTAssertFalse(receipt.succeeded)
        XCTAssertTrue(receipt.failureReason?.contains("대상이 바뀌어") == true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    }

    func testOfficialCommandAllowListRejectsExtraArguments() throws {
        let policy = OfficialCommandPolicy()
        XCTAssertTrue(policy.validate(tool: .xcrun, arguments: ["simctl", "delete", "unavailable"]))
        XCTAssertFalse(policy.validate(tool: .xcrun, arguments: ["simctl", "delete", "all"]))
        XCTAssertFalse(policy.validate(tool: .docker, arguments: ["volume", "prune", "--force"]))
        XCTAssertEqual(
            try policy.preview(
                tool: .xcrun,
                arguments: ["simctl", "delete", "unavailable"],
                executableURL: URL(fileURLWithPath: "/usr/bin/xcrun")
            ),
            "/usr/bin/xcrun simctl delete unavailable"
        )
    }

    func testUnverifiedFolderCannotUseImmediateDeletion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("biu-cleanup-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let candidate = CleanupCandidate(
            path: root.path, logicalSize: 0, allocatedSize: 0,
            tool: "Unknown", category: .cache, modifiedAt: nil,
            detectionReason: "test", source: .folderScan, kind: .directory
        )
        let item = CleanupItem(
            candidate: candidate,
            assessment: SafetyAssessment(
                risk: .safe, reason: "test", impact: "test", recovery: .regenerated
            ),
            recommendedAction: .deleteRegeneratableCache
        )

        do {
            _ = try await CleanupEngine().prepare(item: item)
            XCTFail("검증되지 않은 즉시 삭제가 허용됨")
        } catch let error as CleanupEngineError {
            XCTAssertEqual(error, .unverifiedImmediateDeletion)
        }
    }

    func testProtectedPathCannotBePreparedForTrash() async throws {
        let candidate = CleanupCandidate(
            path: "/System", logicalSize: 0, allocatedSize: 0,
            tool: "System", category: .system, modifiedAt: nil,
            detectionReason: "test", source: .folderScan, kind: .directory
        )
        let assessment = SafetyClassifier().classify(candidate: candidate)
        let item = CleanupItem(candidate: candidate, assessment: assessment, recommendedAction: .moveToTrash)

        do {
            _ = try await CleanupEngine().prepare(item: item)
            XCTFail("보호 경로가 허용됨")
        } catch let error as CleanupEngineError {
            XCTAssertEqual(error, .protectedTarget)
        }
    }

    private func verifiedCacheItem(at url: URL) -> CleanupItem {
        CleanupItem(
            candidate: CleanupCandidate(
                path: url.path,
                logicalSize: 5,
                allocatedSize: 5,
                tool: "Test Cache",
                category: .cache,
                modifiedAt: nil,
                detectionReason: "테스트용 검증 캐시",
                source: .detectorPack("test"),
                kind: .directory
            ),
            assessment: SafetyAssessment(
                risk: .safe,
                reason: "테스트",
                impact: "다시 생성됨",
                recovery: .regenerated
            ),
            recommendedAction: .deleteRegeneratableCache
        )
    }
}
