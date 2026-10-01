import XCTest
@testable import MacCleanHelper

@MainActor
final class ExplorerBasketTests: XCTestCase {
    func testParentSelectionRemovesNestedSelectionsAndPreventsDoubleCounting() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "Biu.ExplorerBasket.\(UUID().uuidString)"))
        let model = DashboardModel(
            folderStore: FolderBookmarkStore(defaults: defaults),
            receiptStore: nil,
            snapshotStore: nil
        )
        let parent = item(path: "/tmp/project", size: 10_000, kind: .directory)
        let child = item(path: "/tmp/project/build", size: 4_000, kind: .directory)

        model.toggleExplorerSelection(child, calculationIsComplete: true)
        model.toggleExplorerSelection(parent, calculationIsComplete: true)

        XCTAssertEqual(model.selectedItems.map(\.path), [parent.path])
        XCTAssertEqual(model.selectedSize, parent.size)

        model.toggleExplorerSelection(child, calculationIsComplete: true)
        XCTAssertEqual(model.selectedItems.map(\.path), [parent.path])
        XCTAssertEqual(model.selectedSize, parent.size)
    }

    func testIncompleteAndSymbolicLinkEntriesCannotEnterBasket() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "Biu.ExplorerBasket.\(UUID().uuidString)"))
        let model = DashboardModel(
            folderStore: FolderBookmarkStore(defaults: defaults),
            receiptStore: nil,
            snapshotStore: nil
        )
        let pending = item(path: "/tmp/pending", size: 0, kind: .directory)
        let link = item(path: "/tmp/link", size: 8, kind: .symbolicLink)

        model.toggleExplorerSelection(pending, calculationIsComplete: false)
        model.toggleExplorerSelection(link, calculationIsComplete: true)

        XCTAssertTrue(model.selectedItems.isEmpty)
    }

    private func item(path: String, size: Int64, kind: CandidateKind) -> CleanupItem {
        let candidate = CleanupCandidate(
            path: path,
            logicalSize: size,
            allocatedSize: size,
            tool: "파일 시스템",
            category: .other,
            modifiedAt: nil,
            detectionReason: "용량 탐색에서 선택함",
            source: .folderScan,
            kind: kind
        )
        return CleanupItem(
            candidate: candidate,
            assessment: SafetyClassifier().classify(candidate: candidate),
            recommendedAction: .moveToTrash
        )
    }
}
