import XCTest
@testable import MacCleanHelper

final class DetectorPackTests: XCTestCase {
    private func entry(path: String) -> ScannedEntry {
        ScannedEntry(
            path: path, logicalSize: 1_000, allocatedSize: 4_096,
            modifiedAt: Date(), kind: .directory, isHidden: false,
            isOnExternalVolume: false, isComplete: true
        )
    }

    func testVerifiedHomeCacheIsRegeneratable() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let item = DetectorRegistry().item(for: entry(path: "\(home)/.gradle/caches"))

        XCTAssertEqual(item.candidate.tool, "Gradle")
        XCTAssertEqual(item.assessment.risk, .safe)
        XCTAssertEqual(item.recommendedAction, .deleteRegeneratableCache)
        XCTAssertTrue(item.candidate.source.isRuleVerified)
    }

    func testAmbiguousProjectDependencyFolderRequiresReview() {
        let item = DetectorRegistry().item(for: entry(path: "/tmp/example/node_modules"))

        XCTAssertEqual(item.candidate.tool, "Node.js")
        XCTAssertEqual(item.assessment.risk, .review)
        XCTAssertFalse(item.assessment.canAutoSelect)
    }

    func testUserRuleCanOnlyContainData() throws {
        let rule = try UserPathRule(
            pathPattern: "**/.cache", explanation: "팀 캐시", category: .cache
        )
        XCTAssertEqual(rule.pathPattern, "**/.cache")
        XCTAssertEqual(rule.explanation, "팀 캐시")
    }
}
