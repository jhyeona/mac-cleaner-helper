import Foundation
import XCTest
@testable import MacCleanHelper

final class CleanupSortTests: XCTestCase {
    func testAllocatedSizeDefaultsToLargestFirst() {
        let items = [item(name: "small", allocated: 10), item(name: "large", allocated: 20)]

        let sorted = CleanupSortKey.allocatedSize.sorted(items, ascending: false)

        XCTAssertEqual(sorted.map(\.name), ["large", "small"])
    }

    func testNameUsesFinderLikeAscendingOrder() {
        let items = [item(name: "Cache 10", allocated: 10), item(name: "Cache 2", allocated: 20)]

        let sorted = CleanupSortKey.name.sorted(items, ascending: true)

        XCTAssertEqual(sorted.map(\.name), ["Cache 2", "Cache 10"])
    }

    func testUnknownModificationDateAlwaysAppearsLast() {
        let known = item(name: "known", allocated: 10, modifiedAt: Date(timeIntervalSince1970: 100))
        let unknown = item(name: "unknown", allocated: 20, modifiedAt: nil)

        XCTAssertEqual(
            CleanupSortKey.modifiedAt.sorted([unknown, known], ascending: true).map(\.name),
            ["known", "unknown"]
        )
        XCTAssertEqual(
            CleanupSortKey.modifiedAt.sorted([unknown, known], ascending: false).map(\.name),
            ["known", "unknown"]
        )
    }

    private func item(name: String, allocated: Int64, modifiedAt: Date? = nil) -> CleanupItem {
        CleanupItem(
            candidate: CleanupCandidate(
                path: "/tmp/\(name)",
                logicalSize: allocated / 2,
                allocatedSize: allocated,
                tool: "테스트",
                category: .cache,
                modifiedAt: modifiedAt,
                detectionReason: "테스트",
                source: .folderScan,
                kind: .directory
            ),
            assessment: SafetyAssessment(
                risk: .safe,
                reason: "테스트",
                impact: "테스트"
            ),
            recommendedAction: .moveToTrash
        )
    }
}
