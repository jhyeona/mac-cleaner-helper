import AppKit
import Darwin
import XCTest
@testable import MacCleanHelper

private actor FailingTrashMover: TrashMoving {
    private(set) var calls = 0
    let failure: TrashMoveFailure
    init(_ failure: TrashMoveFailure) { self.failure = failure }
    func moveToTrash(_ url: URL) async throws -> URL {
        calls += 1
        throw failure
    }
}

final class TrashMoverTests: XCTestCase {
    func testSystemResultRequiresConfirmedDestination() throws {
        let original = URL(fileURLWithPath: "/fixture/App.app")
        let destination = URL(fileURLWithPath: "/fixture/Trash/App.app")
        XCTAssertEqual(try SystemTrashMover.confirmedDestination(for: original, destinations: [original: destination], error: nil), destination)
        XCTAssertThrowsError(try SystemTrashMover.confirmedDestination(for: original, destinations: [:], error: nil)) {
            XCTAssertEqual($0 as? TrashMoveFailure, .unconfirmed)
        }
        XCTAssertThrowsError(try SystemTrashMover.confirmedDestination(
            for: original, destinations: [original: destination], error: CocoaError(.userCancelled)
        )) { XCTAssertEqual($0 as? TrashMoveFailure, .cancelled) }
    }

    func testCancellationAndPermissionErrorsAreDistinctIncludingUnderlyingErrors() {
        for error in [NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError),
                      NSError(domain: NSOSStatusErrorDomain, code: -128),
                      NSError(domain: NSPOSIXErrorDomain, code: Int(ECANCELED))] {
            XCTAssertEqual(TrashMoveFailure.classify(error) as? TrashMoveFailure, .cancelled)
        }
        for error in [NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError),
                      NSError(domain: NSPOSIXErrorDomain, code: Int(EPERM)),
                      NSError(domain: NSOSStatusErrorDomain, code: -54)] {
            let wrapper = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteUnknownError,
                                  userInfo: [NSUnderlyingErrorKey: error])
            guard case .permissionDenied = TrashMoveFailure.classify(wrapper) as? TrashMoveFailure else {
                XCTFail("Expected a permission-specific recovery message"); continue
            }
        }
        let unknown = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError)
        XCTAssertEqual(TrashMoveFailure.classify(unknown) as NSError, unknown)
    }

    func testPermissionOnlyAppCanReachSystemTrashAndDenialDoesNotDeleteAnything() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("biu-auth-test-\(UUID())")
        let appURL = root.appendingPathComponent("Example.app")
        try FileManager.default.createDirectory(at: appURL, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
            try? FileManager.default.removeItem(at: root)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: root.path)
        XCTAssertFalse(FileManager.default.isDeletableFile(atPath: appURL.path))
        XCTAssertNil(ApplicationRemovalPolicy.blockedReason(at: appURL), "Permission-only failures must not be classified as protected apps")
        let app = try XCTUnwrap(InstalledApplicationScanner().application(at: appURL))
        for failure in [TrashMoveFailure.cancelled, .permissionDenied("fixture")] {
            let mover = FailingTrashMover(failure)
            let engine = CleanupEngine(trashMover: mover, runningApplicationProvider: { [] })
            let preparation = try await engine.prepare(item: app.cleanupItem)
            let receipt = await engine.execute(preparation)
            let calls = await mover.calls
            XCTAssertEqual(calls, 1)
            XCTAssertFalse(receipt.succeeded)
            XCTAssertEqual(receipt.failureReason, failure.localizedDescription)
            XCTAssertTrue(FileManager.default.fileExists(atPath: appURL.path))
        }
    }

    func testProtectedAppsNeverReachSystemTrashEvenWithForgedPreparation() async {
        let mover = FailingTrashMover(.unconfirmed)
        let engine = CleanupEngine(trashMover: mover, runningApplicationProvider: { [] })
        let item = CleanupItem(path: "/System", size: 0, category: .system,
                               assessment: SafetyAssessment(risk: .review, reason: "fixture", impact: "fixture"))
        let forged = CleanupPreparation(item: item, action: .moveToTrash, identity: nil,
                                        commandPreview: nil, blockingApplications: [])
        let receipt = await engine.execute(forged)
        XCTAssertFalse(receipt.succeeded)
        let calls = await mover.calls
        XCTAssertEqual(calls, 0)
    }

    @MainActor
    func testSystemTrashRoundTripForDisposableFixture() async throws {
        guard ProcessInfo.processInfo.environment["BIU_TEST_SYSTEM_TRASH"] == "1" else {
            throw XCTSkip("Opt-in native Trash integration test; no installed apps are touched")
        }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("biu-native-trash-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("Biu-disposable-fixture-\(UUID()).txt")
        let payload = Data("Disposable Biu integration-test fixture".utf8)
        try payload.write(to: original)
        let destination = try await SystemTrashMover().moveToTrash(original)
        // Always restore this exact test-created file, never empty or enumerate Trash.
        defer { try? FileManager.default.moveItem(at: destination, to: original) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path))
        XCTAssertEqual(try Data(contentsOf: destination), payload)
        try FileManager.default.moveItem(at: destination, to: original)
        XCTAssertEqual(try Data(contentsOf: original), payload)
    }
}
