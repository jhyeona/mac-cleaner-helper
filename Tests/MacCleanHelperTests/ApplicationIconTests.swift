import AppKit
import SwiftUI
import XCTest
@testable import MacCleanHelper

@MainActor
final class ApplicationIconTests: XCTestCase {
    private func app(version: String = "1", modifiedAt: Date? = nil) -> InstalledApplication {
        InstalledApplication(path: "/fixture/Example.app", name: "Example", version: version,
                             bundleIdentifier: "org.example.test", modifiedAt: modifiedAt, blockedReason: nil)
    }

    func testRowsAndDetailsReuseIconAndRefreshReloadsIt() {
        var loads = 0
        let expected = NSImage(size: NSSize(width: 64, height: 64))
        let cache = ApplicationIconCache { path in
            XCTAssertEqual(path, "/fixture/Example.app")
            loads += 1
            return expected
        }
        XCTAssertTrue(cache.icon(for: app()) === expected)
        XCTAssertTrue(cache.icon(for: app()) === expected)
        XCTAssertEqual(loads, 1)
        _ = cache.icon(for: app(version: "2"))
        XCTAssertEqual(loads, 2)
        _ = cache.icon(for: app(modifiedAt: Date(timeIntervalSince1970: 123)))
        XCTAssertEqual(loads, 3)
        cache.removeAll()
        _ = cache.icon(for: app())
        XCTAssertEqual(loads, 4)
    }

    func testMissingAppHasSystemFallbackAndFixedIconDimensions() throws {
        let image = ApplicationIconCache().icon(for: app())
        XCTAssertTrue(image.isValid)
        for size: CGFloat in [24, 56] {
            let renderer = ImageRenderer(content: InstalledApplicationIcon(app: app(), size: size))
            let rendered = try XCTUnwrap(renderer.cgImage)
            XCTAssertEqual(rendered.width, Int(size))
            XCTAssertEqual(rendered.height, Int(size))
        }
    }
}
