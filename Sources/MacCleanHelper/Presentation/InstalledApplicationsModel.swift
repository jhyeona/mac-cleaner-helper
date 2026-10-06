import AppKit
import Foundation

enum ApplicationSort: String, CaseIterable {
    case size = "용량 큰 순"
    case name = "이름순"
}

@MainActor
final class InstalledApplicationsModel: NSObject, ObservableObject {
    @Published private(set) var applications: [String: InstalledApplication] = [:]
    @Published private(set) var isScanning = false
    @Published private(set) var issues: [ScanIssue] = []
    @Published private(set) var status = "앱 목록을 불러오세요."
    @Published private(set) var running: [RunningApplication] = []
    @Published var searchText = "" {
        didSet {
            if let selection, !filteredApplications.contains(where: { $0.id == selection }) {
                self.selection = nil
            }
        }
    }
    @Published var sort: ApplicationSort = .size
    @Published var selection: String?
    private var scanTask: Task<Void, Never>?
    private var queryTimeout: Task<Void, Never>?
    private var query: NSMetadataQuery?
    private var generation = UUID()
    private var pendingURLs: [URL] = []
    private var extraRoots: [URL] = []
    private var hasLoaded = false
    private let roots: [URL]
    private let usesSpotlight: Bool

    init(roots: [URL] = InstalledApplicationScanner.standardRoots, usesSpotlight: Bool = true) {
        self.roots = roots
        self.usesSpotlight = usesSpotlight
        super.init()
    }

    var selectedApplication: InstalledApplication? { selection.flatMap { applications[$0] } }
    var filteredApplications: [InstalledApplication] {
        applications.values.filter {
            searchText.isEmpty || $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.path.localizedCaseInsensitiveContains(searchText)
                || ($0.bundleIdentifier?.localizedCaseInsensitiveContains(searchText) ?? false)
        }.sorted { lhs, rhs in
            if sort == .size, lhs.allocatedSize != rhs.allocatedSize {
                return (lhs.allocatedSize ?? -1) > (rhs.allocatedSize ?? -1)
            }
            let order = lhs.name.localizedStandardCompare(rhs.name)
            return order == .orderedSame ? lhs.path < rhs.path : order == .orderedAscending
        }
    }

    func loadIfNeeded() {
        refreshRunningApplications()
        if !hasLoaded { refresh() }
    }

    func refreshRunningApplications() { running = RunningApplication.current() }
    func blockers(for app: InstalledApplication) -> [String] {
        ApplicationRemovalPolicy.blockers(for: app.path, running: running)
    }

    func refresh() {
        cancel()
        hasLoaded = true
        applications = [:]
        issues = []
        status = "앱을 찾고 크기를 계산하고 있습니다."
        refreshRunningApplications()
        if usesSpotlight { startSpotlight() }
        scan(roots: roots + extraRoots, urls: [])
    }

    func cancel() {
        generation = UUID()
        scanTask?.cancel()
        scanTask = nil
        stopSpotlight()
        pendingURLs = []
        isScanning = false
        status = "중단됨 · 찾은 앱은 유지합니다. 새로고침으로 다시 계산할 수 있습니다."
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "앱이 설치된 다른 폴더 선택"
        panel.message = "선택한 폴더에서 앱을 찾습니다. 파일은 변경하지 않습니다."
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.showsHiddenFiles = true
        panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls where !extraRoots.contains(url) { extraRoots.append(url) }
        refresh()
    }

    func handleSuccessfulCleanup(paths: [String]) {
        guard hasLoaded, !paths.isEmpty else { return }
        // Invalidate in-flight results before removing entries, so deleted apps cannot reappear.
        cancel()
        applications = applications.filter { key, _ in
            !paths.contains { key == $0 || key.hasPrefix($0 + "/") }
        }
        if let selection, applications[selection] == nil { self.selection = nil }
        status = "정리 결과를 반영했습니다. 새로고침으로 설치 목록을 다시 확인할 수 있습니다."
        refreshRunningApplications()
    }

    private func scan(roots: [URL], urls: [URL]) {
        let token = generation
        isScanning = true
        scanTask = Task {
            do {
                for try await event in InstalledApplicationScanner().events(roots: roots, additionalURLs: urls) {
                    try Task.checkCancellation()
                    guard generation == token else { return }
                    switch event {
                    case .discovered(let app), .measured(let app): applications[app.path] = app
                    case .issue(let issue): issues.append(issue)
                    }
                }
            } catch is CancellationError { return }
            catch {
                guard generation == token else { return }
                issues.append(ScanIssue(path: "앱 검색", message: error.localizedDescription))
            }
            guard generation == token else { return }
            scanTask = nil
            continuePendingScan()
        }
    }

    private func continuePendingScan() {
        guard scanTask == nil else { return }
        let urls = pendingURLs.filter { applications[$0.standardizedFileURL.path] == nil }
        pendingURLs = []
        if !urls.isEmpty { scan(roots: [], urls: urls); return }
        isScanning = query != nil
        if !isScanning {
            status = "\(applications.count)개 앱 · 앱 본체 크기만 계산했습니다."
        }
    }

    private func startSpotlight() {
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryLocalComputerScope]
        query.predicate = NSPredicate(format: "kMDItemContentTypeTree == %@", "com.apple.application-bundle")
        NotificationCenter.default.addObserver(self, selector: #selector(spotlightFinished(_:)),
                                              name: .NSMetadataQueryDidFinishGathering, object: query)
        self.query = query
        if !query.start() {
            issues.append(ScanIssue(path: "Spotlight", message: "검색을 시작하지 못했습니다. 기본 앱 폴더만 확인합니다."))
            stopSpotlight()
            return
        }
        let token = generation
        queryTimeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, let self, self.generation == token, self.query != nil else { return }
            self.issues.append(ScanIssue(path: "Spotlight", message: "검색 시간이 초과되어 현재 결과만 표시합니다. 누락된 위치는 ‘다른 폴더’로 추가하세요."))
            self.collectSpotlightResults()
        }
    }

    @objc private func spotlightFinished(_ notification: Notification) { collectSpotlightResults() }

    private func collectSpotlightResults() {
        guard let query else { return }
        query.disableUpdates()
        pendingURLs += query.results.compactMap { result in
            guard let item = result as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { return nil }
            return URL(fileURLWithPath: path)
        }
        stopSpotlight()
        continuePendingScan()
    }

    private func stopSpotlight() {
        queryTimeout?.cancel()
        queryTimeout = nil
        if let query {
            NotificationCenter.default.removeObserver(self, name: .NSMetadataQueryDidFinishGathering, object: query)
            query.stop()
        }
        query = nil
    }
}
