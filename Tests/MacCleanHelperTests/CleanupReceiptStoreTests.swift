import XCTest
@testable import MacCleanHelper

@MainActor
final class CleanupReceiptStoreTests: XCTestCase {
    func testPersistsExportsAndDeletesReceipts() throws {
        let store = try CleanupReceiptStore(inMemory: true)
        let receipt = CleanupReceipt(
            path: "/tmp/example", action: .moveToTrash,
            sizeBefore: 4_096, sizeAfter: 0, estimatedBytes: 4_096,
            availableCapacityChange: 4_096, succeeded: true,
            failureReason: nil
        )

        try store.append(receipt)
        XCTAssertEqual(try store.all(), [receipt])
        let exported = try store.exportData()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try XCTUnwrap(decoder.decode([CleanupReceipt].self, from: exported).first)
        XCTAssertEqual(decoded.id, receipt.id)
        XCTAssertEqual(decoded.path, receipt.path)
        XCTAssertEqual(decoded.action, receipt.action)
        XCTAssertEqual(decoded.estimatedBytes, receipt.estimatedBytes)
        XCTAssertTrue(decoded.succeeded)

        try store.deleteAll()
        XCTAssertTrue(try store.all().isEmpty)
    }
}
