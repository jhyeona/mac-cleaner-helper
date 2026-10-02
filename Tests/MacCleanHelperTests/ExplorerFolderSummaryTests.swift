import XCTest
import AppKit
import SwiftUI
@testable import MacCleanHelper

final class ExplorerFolderSummaryTests: XCTestCase {
    private func entry(_ name: String, allocated: Int64, logical: Int64, state: ExplorerCalculationState = .complete, error: String? = nil) -> ExplorerEntry {
        ExplorerEntry(path: "/fixture/\(name)", kind: .directory, allocatedSize: allocated,
                      logicalSize: logical, modifiedAt: nil, isHidden: false,
                      volumeIdentifier: "fixture", calculationState: state, errorMessage: error)
    }

    func testTotalsIncludeNestedFolderMeasurementsAndSeparateLogicalSize() {
        let summary = ExplorerFolderSummary(
            entries: [entry("folder", allocated: 4096, logical: 100_000), entry("file", allocated: 8192, logical: 50)],
            isScanning: false, isComplete: true, isStale: false, hasIssues: false
        )
        XCTAssertEqual(summary.allocatedSize, 12_288)
        XCTAssertEqual(summary.logicalSize, 100_050)
        XCTAssertEqual(summary.itemCount, 2)
        XCTAssertEqual(summary.state, .complete)
    }

    func testCalculatingTotalExcludesPendingAndOldMeasurements() {
        let summary = ExplorerFolderSummary(
            entries: [entry("done", allocated: 10, logical: 20), entry("old", allocated: 1000, logical: 2000, state: .stale),
                      entry("pending", allocated: 500, logical: 500, state: .pending)],
            isScanning: true, isComplete: false, isStale: false, hasIssues: false
        )
        XCTAssertEqual(summary.allocatedSize, 10)
        XCTAssertEqual(summary.logicalSize, 20)
        XCTAssertEqual(summary.state, .calculating)
    }

    func testPartialStaleAndEmptyResultsAreDistinguished() {
        let partial = ExplorerFolderSummary(entries: [entry("partial", allocated: 10, logical: 20, error: "denied")],
            isScanning: false, isComplete: true, isStale: false, hasIssues: false)
        XCTAssertEqual(partial.state, .partial)
        XCTAssertEqual(partial.allocatedSize, 10)
        let stale = ExplorerFolderSummary(entries: [entry("old", allocated: 100, logical: 200, state: .stale)],
            isScanning: false, isComplete: false, isStale: true, hasIssues: false)
        XCTAssertEqual(stale.state, .stale)
        XCTAssertEqual(stale.allocatedSize, 100)
        let empty = ExplorerFolderSummary(entries: [], isScanning: false, isComplete: true, isStale: false, hasIssues: false)
        XCTAssertEqual(empty.state, .complete)
        XCTAssertEqual(empty.allocatedSize, 0)
        let denied = ExplorerFolderSummary(entries: [], isScanning: false, isComplete: false, isStale: false, hasIssues: true)
        XCTAssertEqual(denied.state, .partial)
    }

    @MainActor
    func testSummaryRendersWithinNarrowExplorerWidth() throws {
        BiuTypography.registerBundledFont()
        let summary = ExplorerFolderSummary(entries: [entry("partial", allocated: 9_600_000_000, logical: 100_000_000_000, error: "denied")],
            isScanning: false, isComplete: false, isStale: false, hasIssues: true)
        let renderer = ImageRenderer(content: ExplorerFolderSummaryView(summary: summary)
            .frame(width: 380).environment(\.colorScheme, .light).background(Color.white))
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage)
        XCTAssertEqual(image.width, 760)
        XCTAssertLessThan(image.height, 240)
        if let directory = ProcessInfo.processInfo.environment["BIU_LAYOUT_SNAPSHOT_DIR"] {
            let url = URL(fileURLWithPath: directory, isDirectory: true)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            try data.write(to: url.appendingPathComponent("folder-summary.png"))
        }
    }

    @MainActor
    func testSearchDoesNotChangeFolderTotalAndRefreshDiscardsPreviousTotal() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("biu-summary-\(UUID())")
        let folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "Biu.Summary.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let cache = FolderExplorerCacheStore(fileURL: root.appendingPathComponent("cache/cache.json"))
        try cache.save(folder: folder, entries: [entry("match", allocated: 10, logical: 20), entry("other", allocated: 30, logical: 40)],
                       scannedAt: Date(), isComplete: true)
        let model = FolderExplorerModel(folderStore: FolderBookmarkStore(defaults: defaults), cache: cache)
        XCTAssertEqual(model.currentFolderSummary.allocatedSize, 40)
        model.searchText = "match"
        XCTAssertEqual(model.visibleEntries.count, 1)
        XCTAssertEqual(model.currentFolderSummary.allocatedSize, 40)
        XCTAssertEqual(model.currentFolderSummary.itemCount, 2)
        model.searchText = "no results"
        XCTAssertTrue(model.visibleEntries.isEmpty)
        XCTAssertEqual(model.currentFolderSummary.logicalSize, 60)
        model.refresh()
        XCTAssertEqual(model.currentFolderSummary.state, .calculating)
        XCTAssertEqual(model.currentFolderSummary.allocatedSize, 0)
        model.cancel()
        XCTAssertEqual(model.currentFolderSummary.state, .stale)
    }
}
