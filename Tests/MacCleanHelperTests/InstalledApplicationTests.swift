import AppKit
import SwiftUI
import XCTest
@testable import MacCleanHelper

/// Exercise the actual cleanup engine without touching the user's real Trash.
private final class FixtureTrashFileManager: FileManager, @unchecked Sendable {
    let fixtureTrash: URL
    init(fixtureTrash: URL) { self.fixtureTrash = fixtureTrash; super.init() }
    override func trashItem(at url: URL, resultingItemURL: AutoreleasingUnsafeMutablePointer<NSURL?>?) throws {
        let destination = fixtureTrash.appendingPathComponent(url.lastPathComponent)
        try moveItem(at: url, to: destination)
        resultingItemURL?.pointee = destination as NSURL
    }
}

final class InstalledApplicationTests: XCTestCase {
    private func fixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("biu-app-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @discardableResult
    private func makeApp(_ root: URL, name: String = "Example.app", identifier: String = "org.example.test") throws -> URL {
        let url = root.appendingPathComponent(name)
        let contents = url.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: String] = ["CFBundleIdentifier": identifier, "CFBundleName": "Example",
                                      "CFBundleShortVersionString": "1.2.3", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: contents.appendingPathComponent("Info.plist"))
        try Data(repeating: 42, count: 8192).write(to: contents.appendingPathComponent("payload"))
        return url
    }

    func testDiscoveryIncludesHiddenAndNestedFoldersButNotEmbeddedAppsOrTrash() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let outer = try makeApp(root)
        let hidden = try makeApp(root, name: ".Hidden.app", identifier: "org.example.hidden")
        let nested = try makeApp(root, name: "Utilities/Nested.app", identifier: "org.example.nested")
        try makeApp(outer.appendingPathComponent("Contents"), name: "Helper.app")
        try makeApp(root, name: ".Trash/Deleted.app")
        let link = root.appendingPathComponent("Alias.app")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outer)
        var discovered: [InstalledApplication] = []
        var measured: [InstalledApplication] = []
        for try await event in InstalledApplicationScanner().events(roots: [root, root], additionalURLs: [outer]) {
            switch event {
            case .discovered(let app):
                XCTAssertTrue(measured.isEmpty, "Discover the list before measuring bundle contents")
                discovered.append(app)
            case .measured(let app): measured.append(app)
            case .issue(let issue): XCTFail(issue.message)
            }
        }
        XCTAssertEqual(Set(discovered.map(\.path)), Set([outer, hidden, nested, link].map(\.path)))
        XCTAssertEqual(discovered.count, 4)
        XCTAssertEqual(measured.count, 4)
        let app = try XCTUnwrap(measured.first { $0.path == outer.path })
        XCTAssertEqual(app.name, "Example")
        XCTAssertEqual(app.version, "1.2.3")
        XCTAssertNil(app.blockedReason)
        XCTAssertGreaterThan(try XCTUnwrap(app.logicalSize), 8192)
        XCTAssertGreaterThan(try XCTUnwrap(app.allocatedSize), 0)
        XCTAssertEqual(app.cleanupItem.recommendedAction, .moveToTrash)
        XCTAssertEqual(app.cleanupItem.assessment.risk, .review)
        XCTAssertFalse(app.cleanupItem.assessment.canAutoSelect)
        XCTAssertEqual(measured.first { $0.path == link.path }?.cleanupItem.assessment.risk, .avoid)
    }

    func testSystemSelfAndEmbeddedAppsAreProtected() throws {
        XCTAssertNotNil(ApplicationRemovalPolicy.blockedReason(at: URL(fileURLWithPath: "/System/Applications/Finder.app")))
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let own = try makeApp(root, name: "Biu.app", identifier: "io.biu.mac-clean-helper")
        XCTAssertNotNil(ApplicationRemovalPolicy.blockedReason(at: own))
        let helper = try makeApp(own.appendingPathComponent("Contents"), name: "Helper.app")
        XCTAssertNotNil(ApplicationRemovalPolicy.blockedReason(at: helper))
        XCTAssertNil(InstalledApplicationScanner().application(at: helper))
    }

    func testPreparationNeverDeletesAndAppCannotUseImmediateDeletion() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try makeApp(root)
        let app = try XCTUnwrap(InstalledApplicationScanner().application(at: url))
        let engine = CleanupEngine(runningApplicationProvider: { [] })
        let preparation = try await engine.prepare(item: app.cleanupItem)
        XCTAssertEqual(preparation.action, .moveToTrash)
        XCTAssertNotNil(preparation.identity)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        do {
            _ = try await engine.prepare(item: app.cleanupItem, action: .deleteRegeneratableCache)
            XCTFail("App deletion bypassed Trash")
        } catch let error as CleanupEngineError {
            XCTAssertEqual(error, .unverifiedImmediateDeletion)
        }
    }

    func testAppLaunchedAfterPreparationBlocksExecutionAndProducesFailureReceipt() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try makeApp(root)
        let app = try XCTUnwrap(InstalledApplicationScanner().application(at: url))
        let stoppedEngine = CleanupEngine(runningApplicationProvider: { [] })
        let preparation = try await stoppedEngine.prepare(item: app.cleanupItem)
        let runningEngine = CleanupEngine(runningApplicationProvider: {
            [RunningApplication(path: url.path, bundleIdentifier: "org.example.test", name: "Example")]
        })
        let blocked = try await runningEngine.prepare(item: app.cleanupItem)
        XCTAssertEqual(blocked.blockingApplications, ["Example"])
        let receipt = await runningEngine.execute(preparation)
        XCTAssertFalse(receipt.succeeded)
        XCTAssertTrue(receipt.failureReason?.contains("종료") == true)
        XCTAssertEqual(receipt.path, url.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path), "A real running app must never be removed")
        XCTAssertEqual(ApplicationRemovalPolicy.blockers(for: root.path, running: [
            RunningApplication(path: url.path + "/Contents/Helpers/Agent.app", bundleIdentifier: nil, name: "Agent")
        ]), ["Agent"])
        XCTAssertTrue(ApplicationRemovalPolicy.blockers(for: url.path, running: [
            RunningApplication(path: url.path + "2", bundleIdentifier: nil, name: "Other")
        ]).isEmpty)
    }

    func testConfirmedAppRemovalUsesTrashAndKeepsSeparateUserData() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try makeApp(root)
        let trash = root.appendingPathComponent("FixtureTrash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        let userData = root.appendingPathComponent("Application Support/Example/document")
        try FileManager.default.createDirectory(at: userData.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("keep this document".utf8).write(to: userData)
        var app = try XCTUnwrap(InstalledApplicationScanner().application(at: url))
        let measured = try FolderExplorerScanner().measureApplication(at: url)
        app.allocatedSize = measured.allocatedSize
        app.logicalSize = measured.logicalSize
        let engine = CleanupEngine(fileManager: FixtureTrashFileManager(fixtureTrash: trash), runningApplicationProvider: { [] })
        let preparation = try await engine.prepare(item: app.cleanupItem)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let receipt = await engine.execute(preparation)
        XCTAssertTrue(receipt.succeeded, receipt.failureReason ?? "")
        XCTAssertEqual(receipt.action, .moveToTrash)
        XCTAssertEqual(receipt.sizeBefore, measured.allocatedSize)
        XCTAssertEqual(receipt.sizeAfter, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: trash.appendingPathComponent("Example.app/Contents/payload").path))
        XCTAssertEqual(try String(contentsOf: userData, encoding: .utf8), "keep this document")
    }

    func testMeasurementDoesNotFollowSymlinkAndHandlesDisappearedApp() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try makeApp(root)
        let baseline = try FolderExplorerScanner().measureApplication(at: url)
        let outside = root.appendingPathComponent("outside")
        try Data(repeating: 0x42, count: 1_000_000).write(to: outside)
        try FileManager.default.createSymbolicLink(at: url.appendingPathComponent("Contents/link"), withDestinationURL: outside)
        let measured = try FolderExplorerScanner().measureApplication(at: url)
        XCTAssertLessThan(measured.logicalSize - baseline.logicalSize, 100_000)
        let app = try XCTUnwrap(InstalledApplicationScanner().application(at: url))
        try FileManager.default.removeItem(at: url)
        do {
            _ = try await CleanupEngine().prepare(item: app.cleanupItem)
            XCTFail("Missing app was allowed")
        } catch let error as CleanupEngineError { XCTAssertEqual(error, .targetMissing) }
    }

    func testCancellingInventoryTerminatesPromptly() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        for index in 0..<40 { try makeApp(root, name: "App\(index).app") }
        let started = Date()
        let consumer = Task {
            for try await _ in InstalledApplicationScanner().events(roots: [root]) {
                try Task.checkCancellation()
            }
        }
        consumer.cancel()
        do { try await consumer.value } catch is CancellationError {}
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
    }

    @MainActor
    func testApplicationBasketUsesExistingParentDeduplication() throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let url = try makeApp(root)
        let app = try XCTUnwrap(InstalledApplicationScanner().application(at: url))
        let suite = "Biu.AppBasket.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let dashboard = DashboardModel(folderStore: FolderBookmarkStore(defaults: defaults), receiptStore: nil, snapshotStore: nil)
        let child = CleanupItem(path: url.appendingPathComponent("Contents/payload").path, size: 8192,
                                category: .other, assessment: SafetyAssessment(risk: .review, reason: "fixture", impact: "fixture"))
        dashboard.toggleSelection(of: child)
        dashboard.toggleSelection(of: app.cleanupItem)
        XCTAssertEqual(dashboard.selectedItems.map(\.path), [url.path])
        XCTAssertFalse(dashboard.showBasket, "Navigation and selection must not open a deletion sheet")
    }

    @MainActor
    func testModelRefreshSearchCancellationAndCleanupInvalidation() async throws {
        let root = try fixtureRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try makeApp(root, name: "First.app", identifier: "org.example.first")
        let second = try makeApp(root, name: "Second.app", identifier: "org.example.second")
        try Data(repeating: 0x42, count: 100_000).write(to: second.appendingPathComponent("Contents/larger"))
        let model = InstalledApplicationsModel(roots: [root], usesSpotlight: false)
        model.refresh()
        for _ in 0..<500 {
            if !model.isScanning { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertFalse(model.isScanning)
        XCTAssertEqual(model.applications.count, 2)
        XCTAssertTrue(model.applications.values.allSatisfy { $0.allocatedSize != nil })
        XCTAssertEqual(model.filteredApplications.first?.path, second.path)
        model.sort = .name
        XCTAssertEqual(model.filteredApplications.first?.path, first.path)
        if let directory = ProcessInfo.processInfo.environment["BIU_LAYOUT_SNAPSHOT_DIR"] {
            let suite = "Biu.AppLayout.\(UUID())"
            let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            defer { defaults.removePersistentDomain(forName: suite) }
            let dashboard = DashboardModel(folderStore: FolderBookmarkStore(defaults: defaults), receiptStore: nil, snapshotStore: nil)
            model.selection = first.path
            for width: CGFloat in [680, 940] {
                let view = HStack(spacing: 0) {
                    InstalledApplicationsView(model: model, dashboard: dashboard).frame(width: width - 300)
                    Divider()
                    InstalledApplicationDetailView(model: model, dashboard: dashboard).frame(width: 299)
                }.frame(width: width, height: 620)
                let renderer = ImageRenderer(content: view.environment(\.colorScheme, .light).background(Color.white))
                let image = try XCTUnwrap(renderer.cgImage)
                let url = URL(fileURLWithPath: directory, isDirectory: true)
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                try data.write(to: url.appendingPathComponent("applications-\(Int(width)).png"))
            }
        }
        model.selection = first.path
        model.searchText = "org.example.second"
        XCTAssertNil(model.selection, "Searching for another app must not leave the previous app's delete button visible")
        XCTAssertEqual(model.filteredApplications.map(\.path), [second.path])
        model.searchText = "First.app"
        XCTAssertEqual(model.filteredApplications.map(\.path), [first.path])
        model.selection = first.path
        model.handleSuccessfulCleanup(paths: [first.path])
        XCTAssertNil(model.selection)
        XCTAssertNil(model.applications[first.path])
        XCTAssertNotNil(model.applications[second.path])
        model.refresh()
        model.cancel()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertFalse(model.isScanning)
        XCTAssertTrue(model.applications.isEmpty, "Late results must not repopulate a cancelled generation")
    }

    @MainActor
    func testLongAppNamesCannotWidenColumns() throws {
        BiuTypography.registerBundledFont()
        for viewport: CGFloat in [380, 486, 800] {
            let layout = ApplicationTableLayout(viewportWidth: viewport)
            XCTAssertEqual(layout.tableWidth, max(486, viewport))
            for name in ["Example", String(repeating: "아주 긴 앱 이름 Application ", count: 30)] {
                let app = InstalledApplication(path: "/Applications/\(name).app", name: name, version: "1.2.3",
                                               bundleIdentifier: "org.example.test", modifiedAt: nil, blockedReason: nil,
                                               allocatedSize: 1_234_567_890, logicalSize: 2_345_678_901)
                let row = ApplicationListRow(app: app, layout: layout, isSelected: true, isInBasket: false,
                                             isRunning: false, isScanning: false, canToggle: true, select: {}, toggleBasket: {})
                let renderer = ImageRenderer(content: row.environment(\.colorScheme, .light).background(Color.white))
                let image = try XCTUnwrap(renderer.cgImage)
                XCTAssertEqual(image.width, Int(layout.tableWidth))
                XCTAssertEqual(image.height, 58)
                if let directory = ProcessInfo.processInfo.environment["BIU_LAYOUT_SNAPSHOT_DIR"] {
                    let url = URL(fileURLWithPath: directory, isDirectory: true)
                    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
                    let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
                    try data.write(to: url.appendingPathComponent("app-row-\(Int(viewport))-\(name == "Example" ? "short" : "long").png"))
                }
            }
        }
    }
}
