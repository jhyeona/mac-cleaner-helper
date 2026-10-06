import AppKit
import Darwin
import Foundation

struct RunningApplication: Sendable {
    let path: String?
    let bundleIdentifier: String?
    let name: String

    static func current() -> [Self] {
        NSWorkspace.shared.runningApplications.map {
            Self(path: $0.bundleURL?.resolvingSymlinksInPath().path,
                 bundleIdentifier: $0.bundleIdentifier,
                 name: $0.localizedName ?? "실행 중인 앱")
        }
    }
}

enum ApplicationRemovalPolicy {
    static func isApplication(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "app"
    }

    static func blockedReason(at url: URL) -> String? {
        let resolved = url.resolvingSymlinksInPath()
        if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true {
            return "심볼릭 링크는 삭제하지 않습니다. 원본 위치를 확인하세요."
        }
        if SafetyClassifier().isProtected(path: url.path)
            || SafetyClassifier().isProtected(path: resolved.path) {
            return "macOS 또는 보호 영역의 앱은 삭제할 수 없습니다."
        }
        if Bundle(url: resolved)?.bundleIdentifier == "io.biu.mac-clean-helper"
            || (isApplication(Bundle.main.bundleURL) && resolved == Bundle.main.bundleURL.resolvingSymlinksInPath()) {
            return "현재 사용하는 비우 앱은 보호합니다."
        }
        if resolved.deletingLastPathComponent().pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") }) {
            return "다른 앱에 포함된 구성 요소입니다. 상위 앱에서 관리하세요."
        }
        guard FileManager.default.fileExists(atPath: url.path) else {
            return "앱을 찾을 수 없습니다. 볼륨 연결 상태를 확인하세요."
        }
        if (try? url.resourceValues(forKeys: [.volumeIsReadOnlyKey]))?.volumeIsReadOnly == true {
            return "읽기 전용 볼륨의 앱은 휴지통으로 이동할 수 없습니다."
        }
        // Lack of the caller's write permission is not a protected-app verdict.
        // The system trash operation must be allowed to handle authorization.
        return nil
    }

    /// Also blocks deleting a parent folder that contains a running application.
    static func blockers(for path: String, running: [RunningApplication]) -> [String] {
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        let identifier = isApplication(url) ? Bundle(url: url)?.bundleIdentifier : nil
        return Array(Set(running.compactMap { app in
            let containsRunningApp = app.path.map { $0 == url.path || $0.hasPrefix(url.path + "/") } ?? false
            return containsRunningApp || (identifier != nil && identifier == app.bundleIdentifier) ? app.name : nil
        })).sorted()
    }
}

struct InstalledApplication: Identifiable, Hashable, Sendable {
    let path: String
    let name: String
    let version: String
    let bundleIdentifier: String?
    let modifiedAt: Date?
    let blockedReason: String?
    var allocatedSize: Int64?
    var logicalSize: Int64?
    var sizeError: String?
    var id: String { path }
    var formattedSize: String {
        allocatedSize.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
            ?? (sizeError == nil ? "계산 대기" : "확인 불가")
    }

    var cleanupItem: CleanupItem {
        CleanupItem(candidate: CleanupCandidate(
            path: path, logicalSize: logicalSize ?? 0, allocatedSize: allocatedSize ?? 0,
            tool: name, category: .application, modifiedAt: modifiedAt,
            detectionReason: "설치된 앱 번들 · 앱 데이터와 설정은 포함하지 않음",
            source: .folderScan, kind: .package
        ), assessment: SafetyAssessment(
            risk: blockedReason == nil ? .review : .avoid,
            reason: blockedReason ?? "사용자가 설치한 앱입니다. 삭제 후에는 실행할 수 없습니다.",
            impact: "앱 본체만 휴지통으로 옮깁니다. 문서·설정·계정 데이터는 지우지 않습니다. 별도 제거 도구가 있는 앱은 해당 도구를 권장합니다.",
            recovery: .trash, canAutoSelect: false
        ), recommendedAction: .moveToTrash)
    }
}

enum ApplicationScanEvent: Sendable {
    case discovered(InstalledApplication)
    case measured(InstalledApplication)
    case issue(ScanIssue)
}

struct InstalledApplicationScanner: Sendable {
    static var standardRoots: [URL] {
        [URL(fileURLWithPath: "/Applications"),
         FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
         URL(fileURLWithPath: "/System/Applications"),
         URL(fileURLWithPath: "/System/Library/CoreServices")]
    }

    func events(roots: [URL], additionalURLs: [URL] = []) -> AsyncThrowingStream<ApplicationScanEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .utility) {
                do {
                    var apps: [InstalledApplication] = []
                    var seen = Set<String>()
                    func discover(_ url: URL) {
                        guard let app = application(at: url), seen.insert(app.path).inserted else { return }
                        apps.append(app)
                        continuation.yield(.discovered(app))
                    }
                    for root in roots {
                        try Task.checkCancellation()
                        if ApplicationRemovalPolicy.isApplication(root) { discover(root); continue }
                        guard FileManager.default.fileExists(atPath: root.path) else { continue }
                        let values = try root.resourceValues(forKeys: [.isSymbolicLinkKey])
                        guard values.isSymbolicLink != true else { continue }
                        let volume = try deviceIdentifier(at: root)
                        var folders = [root]
                        while let folder = folders.popLast() {
                            try Task.checkCancellation()
                            // A queued directory may have been replaced while another one was read.
                            do {
                                let current = try folder.resourceValues(forKeys: [.isSymbolicLinkKey])
                                guard current.isSymbolicLink != true, try deviceIdentifier(at: folder) == volume else { continue }
                            } catch {
                                continuation.yield(.issue(ScanIssue(path: folder.path, message: error.localizedDescription)))
                                continue
                            }
                            guard let enumerator = FileManager.default.enumerator(
                                at: folder, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey],
                                options: [.skipsSubdirectoryDescendants], errorHandler: { url, error in
                                    continuation.yield(.issue(ScanIssue(path: url.path, message: error.localizedDescription)))
                                    return true
                                }
                            ) else { continue }
                            while let url = enumerator.nextObject() as? URL {
                                try Task.checkCancellation()
                                do {
                                    let values = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey])
                                    if values.isSymbolicLink == true {
                                        if ApplicationRemovalPolicy.isApplication(url) { discover(url) }
                                        continue
                                    }
                                    if try deviceIdentifier(at: url) != volume { continue }
                                    if ApplicationRemovalPolicy.isApplication(url) {
                                        discover(url)
                                    } else if values.isDirectory == true && values.isPackage != true
                                                && ![".Trash", ".Trashes"].contains(url.lastPathComponent) {
                                        folders.append(url)
                                    }
                                } catch {
                                    continuation.yield(.issue(ScanIssue(path: url.path, message: error.localizedDescription)))
                                }
                            }
                        }
                    }
                    for url in additionalURLs {
                        try Task.checkCancellation()
                        discover(url)
                    }
                    // List first, then measure at most two bundles concurrently.
                    try await withThrowingTaskGroup(of: InstalledApplication.self) { group in
                        var index = 0
                        func enqueue() {
                            guard index < apps.count else { return }
                            let app = apps[index]
                            index += 1
                            group.addTask { try measure(app) }
                        }
                        enqueue(); enqueue()
                        while let app = try await group.next() {
                            try Task.checkCancellation()
                            continuation.yield(.measured(app))
                            enqueue()
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func application(at url: URL) -> InstalledApplication? {
        let url = url.standardizedFileURL
        guard ApplicationRemovalPolicy.isApplication(url),
              !url.deletingLastPathComponent().pathComponents.contains(where: { $0.lowercased().hasSuffix(".app") }),
              !url.pathComponents.contains(".Trash"), !url.pathComponents.contains(".Trashes"),
              let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .contentModificationDateKey]),
              values.isDirectory == true || values.isSymbolicLink == true else { return nil }
        let bundle = values.isSymbolicLink == true ? nil : Bundle(url: url)
        return InstalledApplication(
            path: url.path,
            name: bundle?.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
                ?? bundle?.object(forInfoDictionaryKey: "CFBundleName") as? String
                ?? url.deletingPathExtension().lastPathComponent,
            version: bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—",
            bundleIdentifier: bundle?.bundleIdentifier, modifiedAt: values.contentModificationDate,
            blockedReason: ApplicationRemovalPolicy.blockedReason(at: url)
        )
    }

    private func measure(_ app: InstalledApplication) throws -> InstalledApplication {
        try Task.checkCancellation()
        var result = app
        do {
            let entry = try FolderExplorerScanner().measureApplication(at: URL(fileURLWithPath: app.path))
            result.allocatedSize = entry.allocatedSize
            result.logicalSize = entry.logicalSize
            result.sizeError = entry.errorMessage
        } catch is CancellationError { throw CancellationError() }
        catch { result.sizeError = error.localizedDescription }
        return result
    }

    private func deviceIdentifier(at url: URL) throws -> dev_t {
        var information = stat()
        guard lstat(url.path, &information) == 0 else { throw CocoaError(.fileReadUnknown) }
        return information.st_dev
    }
}
