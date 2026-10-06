import Carbon
import XCTest
@testable import MacCleanHelper

private actor StubTrashMover: TrashMoving {
    private(set) var calls = 0
    let failure: TrashMoveFailure?
    init(failure: TrashMoveFailure? = nil) { self.failure = failure }
    func moveToTrash(_ url: URL) async throws -> URL {
        calls += 1
        if let failure { throw failure }
        return url.deletingLastPathComponent().appendingPathComponent("fixture-trash").appendingPathComponent(url.lastPathComponent)
    }
}

private struct ReplacingTrashMover: TrashMoving {
    func moveToTrash(_ url: URL) async throws -> URL {
        try FileManager.default.moveItem(at: url, to: url.appendingPathExtension("original"))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        throw TrashMoveFailure.permissionDenied("fixture")
    }
}

final class FinderTrashMoverTests: XCTestCase {
    private func fixture() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("biu-finder-test-\(UUID())").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testRequestContainsOnlySelectedAliasAndFixedFinderDeleteCommand() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("한글 ' \" ; $(not-a-command)\n.app")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let request = try FinderTrashMover.deleteEvent(for: url)
        XCTAssertEqual(request.eventClass, AEEventClass(kCoreEventClass))
        XCTAssertEqual(request.eventID, AEEventID(kAEDelete))
        let target = try XCTUnwrap(request.attributeDescriptor(forKeyword: AEKeyword(keyAddressAttr)))
        XCTAssertEqual(target.descriptorType, DescType(typeApplicationBundleID))
        XCTAssertEqual(String(data: target.data, encoding: .utf8), "com.apple.finder")
        let selected = try XCTUnwrap(request.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)))
        XCTAssertEqual(selected.descriptorType, DescType(typeAlias))
        XCTAssertEqual(selected.fileURLValue?.standardizedFileURL, url.standardizedFileURL)
        XCTAssertEqual(request.numberOfItems, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "Building a request must not send it")
    }

    func testReplySeparatesConsentCancellationPermissionAndTimeout() throws {
        for (code, expected) in [(-1743, TrashMoveFailure.automationDenied), (-128, .cancelled), (-1712, .timedOut)] {
            let reply = NSAppleEventDescriptor.record()
            reply.setParam(NSAppleEventDescriptor(int32: Int32(code)), forKeyword: AEKeyword(keyErrorNumber))
            XCTAssertThrowsError(try FinderTrashMover.resultDescriptor(from: reply)) {
                XCTAssertEqual($0 as? TrashMoveFailure, expected)
            }
        }
        guard case .permissionDenied = FinderTrashMover.failure(code: -5000) as? TrashMoveFailure else {
            return XCTFail("Finder access denied must retain its distinct cause")
        }
    }

    func testMissingAndMultipleResultsAreNotSuccess() throws {
        let reply = NSAppleEventDescriptor.record()
        XCTAssertThrowsError(try FinderTrashMover.resultDescriptor(from: reply))
        let list = NSAppleEventDescriptor.list()
        reply.setParam(list, forKeyword: AEKeyword(keyDirectObject))
        XCTAssertThrowsError(try FinderTrashMover.resultDescriptor(from: reply))
        let url = URL(fileURLWithPath: "/fixture/.Trash/App.app")
        list.insert(NSAppleEventDescriptor(fileURL: url), at: 1)
        reply.setParam(list, forKeyword: AEKeyword(keyDirectObject))
        XCTAssertEqual(try FinderTrashMover.resultDescriptor(from: reply).fileURLValue, url)
        list.insert(NSAppleEventDescriptor(fileURL: url), at: 2)
        reply.setParam(list, forKeyword: AEKeyword(keyDirectObject))
        XCTAssertThrowsError(try FinderTrashMover.resultDescriptor(from: reply))
    }

    func testDestinationMustBeDirectlyInsideActualUserTrash() throws {
        let source = URL(fileURLWithPath: "/Applications/App.app")
        let trash = URL(fileURLWithPath: "/Users/fixture/.Trash")
        try FinderTrashMover.validateDestination(trash.appendingPathComponent("App 2.app"), original: source, trashDirectories: [trash])
        for path in [source.path, "/Users/fixture/.TrashFake/App.app", "/Users/fixture/.Trash/nested/App.app", "/elsewhere/App.app"] {
            XCTAssertThrowsError(try FinderTrashMover.validateDestination(URL(fileURLWithPath: path), original: source, trashDirectories: [trash]))
        }
        XCTAssertThrowsError(try FinderTrashMover.validateDestination(URL(string: "https://example.com/App.app")!, original: source, trashDirectories: [trash]))
    }

    func testAuthenticationValidationRejectsProtectedSymlinkAndNonAppTargets() throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Test.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        _ = try FinderTrashMover.validateApplication(app)
        let link = root.appendingPathComponent("Link.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: app)
        let parentLink = root.appendingPathComponent("parent")
        try FileManager.default.createSymbolicLink(at: parentLink, withDestinationURL: root)
        for url in [link, parentLink.appendingPathComponent("Test.app"), root, URL(fileURLWithPath: "/System/Applications/Notes.app")] {
            XCTAssertThrowsError(try FinderTrashMover.validateApplication(url))
        }
        let notDirectory = root.appendingPathComponent("File.app")
        try Data().write(to: notDirectory)
        XCTAssertThrowsError(try FinderTrashMover.validateApplication(notDirectory))
    }

    func testOnlyExplicitAppPermissionFailureReachesAuthentication() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("Example.app")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        let item = try XCTUnwrap(InstalledApplicationScanner().application(at: url)).cleanupItem
        for failure in [TrashMoveFailure.permissionDenied("fixture"), .cancelled, .timedOut, .unconfirmed, .automationDenied] {
            let normal = StubTrashMover(failure: failure)
            let authenticated = StubTrashMover()
            let engine = CleanupEngine(trashMover: normal, authenticatedTrashMover: authenticated, runningApplicationProvider: { [] })
            let preparation = try await engine.prepare(item: item)
            let receipt = await engine.execute(preparation)
            let calls = await authenticated.calls
            XCTAssertEqual(calls, failure == .permissionDenied("fixture") ? 1 : 0)
            XCTAssertEqual(receipt.succeeded, calls == 1)
        }
        let normal = StubTrashMover()
        let authenticated = StubTrashMover()
        let engine = CleanupEngine(trashMover: normal, authenticatedTrashMover: authenticated, runningApplicationProvider: { [] })
        let preparation = try await engine.prepare(item: item)
        let receipt = await engine.execute(preparation)
        let calls = await authenticated.calls
        XCTAssertTrue(receipt.succeeded)
        XCTAssertEqual(calls, 0)
    }

    func testOrdinaryFolderDoesNotGainAuthenticationOnPermissionFailure() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let authenticated = StubTrashMover()
        let engine = CleanupEngine(trashMover: StubTrashMover(failure: .permissionDenied("fixture")),
                                   authenticatedTrashMover: authenticated, runningApplicationProvider: { [] })
        let item = CleanupItem(path: root.path, size: 0, category: .personal,
                               assessment: SafetyAssessment(risk: .review, reason: "fixture", impact: "fixture"))
        let preparation = try await engine.prepare(item: item)
        let receipt = await engine.execute(preparation)
        let calls = await authenticated.calls
        XCTAssertFalse(receipt.succeeded)
        XCTAssertEqual(calls, 0)
    }

    func testReplacedAppDoesNotReachAuthentication() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Example.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let item = try XCTUnwrap(InstalledApplicationScanner().application(at: app)).cleanupItem
        let authenticated = StubTrashMover()
        let engine = CleanupEngine(trashMover: ReplacingTrashMover(), authenticatedTrashMover: authenticated,
                                   runningApplicationProvider: { [] })
        let preparation = try await engine.prepare(item: item)
        let receipt = await engine.execute(preparation)
        let calls = await authenticated.calls
        XCTAssertFalse(receipt.succeeded)
        XCTAssertEqual(receipt.failureReason, CleanupEngineError.targetChanged.localizedDescription)
        XCTAssertEqual(calls, 0)
    }

    func testAuthenticationCancellationPreservesFailureReceipt() async throws {
        let root = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let app = root.appendingPathComponent("Example.app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let item = try XCTUnwrap(InstalledApplicationScanner().application(at: app)).cleanupItem
        let engine = CleanupEngine(trashMover: StubTrashMover(failure: .permissionDenied("fixture")),
                                   authenticatedTrashMover: StubTrashMover(failure: .cancelled), runningApplicationProvider: { [] })
        let preparation = try await engine.prepare(item: item)
        let receipt = await engine.execute(preparation)
        XCTAssertFalse(receipt.succeeded)
        XCTAssertEqual(receipt.failureReason, TrashMoveFailure.cancelled.localizedDescription)
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
    }
}
