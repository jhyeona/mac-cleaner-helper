import AppKit
import XCTest
@testable import MacCleanHelper

final class BiuTypographyTests: XCTestCase {
    func testBundledFontCanBeRegistered() {
        XCTAssertNotNil(BiuTypography.resourceURL)
        XCTAssertTrue(BiuTypography.registerBundledFont())
        XCTAssertNotNil(NSFont(name: BiuTypography.postScriptName, size: 14))
    }
}
