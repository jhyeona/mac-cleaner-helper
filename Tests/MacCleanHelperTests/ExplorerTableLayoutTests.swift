import XCTest
import AppKit
import SwiftUI
@testable import MacCleanHelper

final class ExplorerTableLayoutTests: XCTestCase {
    func testNarrowViewportsKeepEveryColumnAndUseHorizontalOverflow() {
        for width: CGFloat in [0, 380, 500, 699] {
            let layout = ExplorerTableLayout(viewportWidth: width)
            XCTAssertEqual(layout.nameWidth, 160)
            XCTAssertEqual(layout.tableWidth, 700)
            XCTAssertGreaterThan(layout.tableWidth, width)
        }
    }

    func testOnlyNameColumnChangesWhenViewportGrows() {
        for width: CGFloat in [700, 760, 1000, 1600] {
            let layout = ExplorerTableLayout(viewportWidth: width)
            XCTAssertEqual(layout.tableWidth, width)
            XCTAssertEqual(layout.nameWidth, width - 540)
            XCTAssertEqual(layout.tableWidth - layout.nameWidth, 540)
        }
    }

    @MainActor
    func testLongNamesCannotWidenRenderedRowOrChangeRowHeight() throws {
        BiuTypography.registerBundledFont()
        for viewport: CGFloat in [380, 700, 1000] {
            let layout = ExplorerTableLayout(viewportWidth: viewport)
            var shortRowHeight: Int?
            for name in ["short.txt", String(repeating: "아주긴파일이름_long_filename_", count: 12) + ".swift"] {
                let entry = ExplorerEntry(
                    path: "/fixture/" + name, kind: .regularFile,
                    allocatedSize: 123_456_789, logicalSize: 234_567_890,
                    modifiedAt: Date(timeIntervalSince1970: 1_700_000_000),
                    isHidden: true, volumeIdentifier: "fixture",
                    calculationState: .complete, errorMessage: nil
                )
                let row = ExplorerEntryRow(
                    entry: entry, layout: layout, isBusy: false,
                    assessment: SafetyAssessment(risk: .review, reason: "fixture", impact: "fixture"),
                    isSelected: false, isInBasket: false,
                    select: {}, open: {}, openPackage: {}, toggleBasket: {}
                )
                let renderer = ImageRenderer(content: row.environment(\.colorScheme, .light).background(Color.white))
                renderer.scale = 1
                let image = try XCTUnwrap(renderer.cgImage)
                XCTAssertEqual(image.width, Int(layout.tableWidth))
                if let shortRowHeight {
                    XCTAssertEqual(image.height, shortRowHeight)
                } else {
                    shortRowHeight = image.height
                }
                if let directory = ProcessInfo.processInfo.environment["BIU_LAYOUT_SNAPSHOT_DIR"] {
                    let url = URL(fileURLWithPath: directory, isDirectory: true)
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                    try data.write(to: url.appendingPathComponent("row-\(Int(viewport))-\(name == "short.txt" ? "short" : "long").png"))
                }
            }
        }
    }
}
