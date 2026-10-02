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

    func testBasketSurvivesNewAnalysisAndCancellationDoesNotRestoreRemovedSelection() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("biu-basket-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "Biu.BasketScan.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DashboardModel(folderStore: FolderBookmarkStore(defaults: defaults), receiptStore: nil, snapshotStore: nil)
        try Data("keep me".utf8).write(to: root.appendingPathComponent("selected.txt"))
        // Use the scanner's spelling of the path (macOS may expand /var to /private/var).
        let scanned = try XCTUnwrap(DirectoryScanner().scanTopLevel(at: root).first)
        let selected = item(path: scanned.path, size: 10, kind: .regularFile)
        model.toggleSelection(of: selected)
        model.scan(folder: root)
        XCTAssertEqual(model.selectedItems.map(\.id), [selected.id])
        for _ in 0..<500 {
            if !model.isScanning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.isScanning)
        XCTAssertEqual(model.selectedItems.map(\.id), [selected.id])
        XCTAssertEqual(model.selectedItems.first?.size, model.items.first { $0.id == selected.id }?.size,
                       "items: \(model.items.map(\.path)), issues: \(model.scanIssues), error: \(model.errorMessage ?? "none")")
        XCTAssertNotEqual(model.selectedSize, 10, "바구니의 오래된 용량을 새 분석 결과로 갱신해야 합니다.")
        model.scan(folder: root)
        model.removeFromBasket(selected.id)
        model.cancelScan()
        XCTAssertTrue(model.selectedItems.isEmpty)
        XCTAssertTrue(model.selectedIDs.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: selected.path))
    }

    func testOneMissingItemDoesNotBlockValidPreparationAndExcludingAllCannotExecute() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("biu-preparation-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "Biu.BasketPrepare.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = DashboardModel(folderStore: FolderBookmarkStore(defaults: defaults), receiptStore: nil, snapshotStore: nil)
        let valid = item(path: root.appendingPathComponent("valid.txt").path, size: 10, kind: .regularFile)
        let missing = item(path: root.appendingPathComponent("missing.txt").path, size: 10, kind: .regularFile)
        try Data("keep me".utf8).write(to: URL(fileURLWithPath: valid.path))
        model.toggleSelection(of: valid)
        model.toggleSelection(of: missing)
        model.prepareSelectedCleanup()
        for _ in 0..<500 {
            if !model.isPreparingCleanup { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.isPreparingCleanup)
        XCTAssertEqual(model.confirmation?.preparations.map(\.item.id), [valid.id])
        XCTAssertEqual(model.preparationIssues.map(\.path), [missing.path])
        model.executeConfirmedCleanup(excluding: [valid.id])
        XCTAssertFalse(model.isCleaning)
        XCTAssertTrue(FileManager.default.fileExists(atPath: valid.path))
        model.clearBasket()
        XCTAssertTrue(model.selectedItems.isEmpty)
        XCTAssertTrue(model.explorerBasketItems.isEmpty)
        XCTAssertTrue(model.preparationIssues.isEmpty)
    }
}
