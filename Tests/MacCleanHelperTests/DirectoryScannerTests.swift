import XCTest
@testable import MacCleanHelper

final class DirectoryScannerTests: XCTestCase {
    func testReturnsTopLevelEntriesLargestFirst() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleaner-helper-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let small = root.appendingPathComponent("small.bin")
        let largeFolder = root.appendingPathComponent("large")
        try FileManager.default.createDirectory(at: largeFolder, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 64).write(to: small)
        try Data(repeating: 2, count: 8_192).write(to: largeFolder.appendingPathComponent("data.bin"))

        let results = try DirectoryScanner().scanTopLevel(at: root)

        XCTAssertEqual(results.map { URL(fileURLWithPath: $0.path).lastPathComponent }, ["large", "small.bin"])
        XCTAssertGreaterThan(results[0].size, results[1].size)
    }

    func testDoesNotFollowSymbolicLinks() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleaner-helper-link-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let target = root.appendingPathComponent("target.bin")
        let link = root.appendingPathComponent("target-link")
        try Data(repeating: 1, count: 1_024).write(to: target)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let results = try DirectoryScanner().scanTopLevel(at: root)
        let linkResult = try XCTUnwrap(results.first {
            URL(fileURLWithPath: $0.path).lastPathComponent == link.lastPathComponent
        })

        XCTAssertEqual(linkResult.size, 0)
        XCTAssertEqual(linkResult.kind, .symbolicLink)
    }

    func testReportsLogicalAndAllocatedSizesSeparately() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleaner-helper-size-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let data = Data(repeating: 7, count: 5_123)
        try data.write(to: root.appendingPathComponent("odd-size.bin"))

        let result = try XCTUnwrap(DirectoryScanner().scanTopLevel(at: root).first)
        XCTAssertEqual(result.logicalSize, 5_123)
        XCTAssertGreaterThanOrEqual(result.allocatedSize, result.logicalSize)
    }

    func testStreamEmitsDiscoveredEntryBeforeCompletedDirectory() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleaner-helper-stream-test-\(UUID().uuidString)")
        let child = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 256).write(to: child.appendingPathComponent("data.bin"))
        defer { try? FileManager.default.removeItem(at: root) }

        var entries: [ScannedEntry] = []
        for try await event in DirectoryScanner().events(at: root) {
            if case .entry(let entry) = event { entries.append(entry) }
        }

        XCTAssertEqual(entries.count, 2)
        XCTAssertFalse(entries[0].isComplete)
        XCTAssertTrue(entries[1].isComplete)
        XCTAssertGreaterThan(entries[1].logicalSize, 0)
    }

    func testSingleItemMeasurementHonorsCancellation() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cleaner-helper-cancel-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0..<64 {
            try Data(repeating: UInt8(index), count: 1_024)
                .write(to: root.appendingPathComponent("\(index).bin"))
        }
        defer { try? FileManager.default.removeItem(at: root) }

        let task = Task.detached {
            try DirectoryScanner().measure(at: root)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("취소된 단일 경로 측정이 완료됨")
        } catch is CancellationError {
            // expected
        }
    }
}
