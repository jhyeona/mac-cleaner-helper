import AppKit
import Foundation

enum ExplorerSortKey: String, CaseIterable, Identifiable, Sendable {
    case allocatedSize
    case logicalSize
    case name
    case modifiedAt
    case kind
    case risk

    var id: String { rawValue }
    var title: String {
        switch self {
        case .allocatedSize: "실제 크기"
        case .logicalSize: "논리 크기"
        case .name: "이름"
        case .modifiedAt: "수정일"
        case .kind: "유형"
        case .risk: "안전도"
        }
    }
}

struct ExplorerLocation: Identifiable, Hashable {
    enum Kind: Hashable { case home, registered, startupDisk, external }
    let url: URL
    let title: String
    let subtitle: String
    let kind: Kind
    var id: String { "\(kind)-\(url.standardizedFileURL.path)" }
}

@MainActor
final class FolderExplorerModel: ObservableObject {
    @Published private(set) var currentURL: URL?
    @Published private(set) var entries: [ExplorerEntry] = []
    @Published private(set) var selectedPath: String?
    @Published private(set) var isScanning = false
    @Published private(set) var progress = ExplorerProgress(
        completedDirectoryCount: 0,
        totalDirectoryCount: 0,
        visitedItemCount: 0,
        currentPath: nil
    )
    @Published private(set) var issues: [ScanIssue] = []
    @Published private(set) var cachedAt: Date?
    @Published private(set) var staleMessage: String?
    @Published private(set) var cacheCount = 0
    @Published var searchText = ""
    @Published var sortKey: ExplorerSortKey = .allocatedSize
    @Published var sortAscending = false
    @Published var showStartupDiskWarning = false
    @Published var errorMessage: String?

    let folderStore: FolderBookmarkStore

    private let scanner: FolderExplorerScanner
    private let cache: FolderExplorerCacheStore
    private let detectors: DetectorRegistry
    private var scanTask: Task<Void, Never>?
    private var scanGeneration = UUID()
    private var entryMap: [String: ExplorerEntry] = [:]
    private var discoveredPaths: Set<String> = []
    private var history: [URL] = []
    private var historyIndex = -1
    private var pendingStartupURL: URL?
    private var currentAccess: SecurityScopedAccess?
    private var scanStartedAt = Date()
    private var currentScanComplete = false
    private var hasUnsavedScanChanges = false

    init(
        folderStore: FolderBookmarkStore,
        scanner: FolderExplorerScanner = FolderExplorerScanner(),
        cache: FolderExplorerCacheStore? = nil,
        detectors: DetectorRegistry = DetectorRegistry()
    ) {
        self.folderStore = folderStore
        self.scanner = scanner
        self.cache = cache ?? FolderExplorerCacheStore()
        self.detectors = detectors
        cacheCount = self.cache.count
        restoreLastLocation()
    }

    var selectedEntry: ExplorerEntry? {
        guard let selectedPath else { return nil }
        return entryMap[selectedPath]
    }

    var canGoBack: Bool { historyIndex > 0 }
    var canGoUp: Bool { currentURL != nil && currentURL?.path != "/" }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.title = "용량을 확인할 폴더를 선택하세요"
        panel.prompt = "폴더 열기"
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.showsHiddenFiles = true
        panel.directoryURL = currentURL
        guard panel.runModal() == .OK, let url = panel.url else { return }
        requestOpen(url)
    }

    func openPath(_ path: String) {
        let expanded = (path.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else {
            errorMessage = "절대 경로나 ~/로 시작하는 경로를 입력해 주세요."
            return
        }
        requestOpen(URL(fileURLWithPath: expanded, isDirectory: true))
    }

    var visibleEntries: [ExplorerEntry] {
        let filtered = entryMap.values.filter {
            searchText.isEmpty
                || $0.name.localizedCaseInsensitiveContains(searchText)
                || $0.path.localizedCaseInsensitiveContains(searchText)
        }
        return filtered.sorted { lhs, rhs in
            if sortKey == .modifiedAt, (lhs.modifiedAt == nil) != (rhs.modifiedAt == nil) {
                return lhs.modifiedAt != nil
            }
            let comparison = compare(lhs, rhs)
            if comparison == .orderedSame {
                return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
            return sortAscending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    func selectSortKey(_ key: ExplorerSortKey) {
        guard sortKey != key else { return }
        sortKey = key
        sortAscending = key == .name || key == .kind || key == .risk
    }

    var locations: [ExplorerLocation] {
        var result: [ExplorerLocation] = []
        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        result.append(ExplorerLocation(
            url: home,
            title: "홈 폴더",
            subtitle: home.path,
            kind: .home
        ))
        result.append(contentsOf: folderStore.folders.filter { !$0.isStale }.map {
            ExplorerLocation(
                url: $0.url.standardizedFileURL,
                title: $0.url.lastPathComponent,
                subtitle: "등록한 개발 폴더 · \($0.url.path)",
                kind: .registered
            )
        })
        result.append(ExplorerLocation(
            url: URL(fileURLWithPath: "/", isDirectory: true),
            title: "시동 볼륨",
            subtitle: "/ · 볼륨 경계를 넘지 않음",
            kind: .startupDisk
        ))
        result.append(contentsOf: externalVolumes())

        var seen = Set<String>()
        return result.filter { seen.insert($0.url.standardizedFileURL.path).inserted }
    }

    var breadcrumbURLs: [URL] {
        guard let currentURL else { return [] }
        let components = currentURL.standardizedFileURL.pathComponents
        var urls: [URL] = []
        var path = ""
        for component in components {
            if component == "/" {
                path = "/"
            } else {
                path = URL(fileURLWithPath: path, isDirectory: true)
                    .appendingPathComponent(component, isDirectory: true).path
            }
            urls.append(URL(fileURLWithPath: path, isDirectory: true))
        }
        return urls
    }

    var commandPreview: String? {
        guard let currentURL else { return nil }
        return "/usr/bin/du -x -k -d 1 \(Self.shellQuote(currentURL.path)) | /usr/bin/sort -nr"
    }

    func requestOpen(_ url: URL, enterPackage: Bool = false) {
        let normalized = url.standardizedFileURL
        guard let values = try? normalized.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]),
              values.isDirectory == true, values.isSymbolicLink != true else {
            errorMessage = "폴더를 열 수 없습니다. 경로와 연결 상태를 확인해 주세요. 심볼릭 링크는 탐색하지 않습니다."
            return
        }
        if normalized.path == "/" {
            pendingStartupURL = normalized
            showStartupDiskWarning = true
            return
        }
        if isPackage(normalized), !enterPackage {
            errorMessage = "패키지는 행의 ‘패키지 내부 보기’를 선택해야 열 수 있습니다."
            return
        }
        open(normalized, addToHistory: true, scan: true)
    }

    func confirmStartupDiskOpen() {
        showStartupDiskWarning = false
        let target = pendingStartupURL ?? URL(fileURLWithPath: "/", isDirectory: true)
        pendingStartupURL = nil
        open(target, addToHistory: true, scan: true)
    }

    func goBack() {
        guard canGoBack else { return }
        historyIndex -= 1
        open(history[historyIndex], addToHistory: false, scan: true)
    }

    func goUp() {
        guard let currentURL, currentURL.path != "/" else { return }
        requestOpen(currentURL.deletingLastPathComponent())
    }

    func showLocations() {
        persistCurrent(isComplete: currentScanComplete)
        scanGeneration = UUID()
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        currentAccess = nil
        currentURL = nil
        selectedPath = nil
        entryMap = [:]
        entries = []
        history = []
        historyIndex = -1
        cachedAt = nil
        staleMessage = nil
        issues = []
    }

    func refresh() {
        guard let currentURL else { return }
        startScan(at: currentURL)
    }

    func cancel() {
        guard isScanning else { return }
        scanGeneration = UUID()
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        entryMap = entryMap.mapValues {
            $0.calculationState == .pending || $0.calculationState == .calculating
                ? replacing($0, state: .stale, error: $0.errorMessage) : $0
        }
        staleMessage = "계산을 중단했습니다. 완료된 항목은 유지되며 새로고침하면 다시 계산합니다."
        entries = visibleEntries
        persistCurrent(isComplete: false)
    }

    func select(_ entry: ExplorerEntry?) {
        selectedPath = entry?.path
    }

    func enter(_ entry: ExplorerEntry) {
        guard entry.kind == .directory else { return }
        requestOpen(URL(fileURLWithPath: entry.path, isDirectory: true))
    }

    func enterPackage(_ entry: ExplorerEntry) {
        guard entry.kind == .package else { return }
        requestOpen(URL(fileURLWithPath: entry.path, isDirectory: true), enterPackage: true)
    }

    func cleanupItem(for entry: ExplorerEntry) -> CleanupItem {
        let cleanupKind: CandidateKind = entry.errorMessage == nil ? entry.kind : .inaccessible
        return detectors.item(for: ScannedEntry(
            path: entry.path,
            logicalSize: entry.logicalSize,
            allocatedSize: entry.allocatedSize,
            modifiedAt: entry.modifiedAt,
            kind: cleanupKind,
            isHidden: entry.isHidden,
            isOnExternalVolume: false,
            isComplete: entry.calculationState == .complete
        ))
    }

    func copyCurrentPath() {
        guard let path = currentURL?.path else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
    }

    func copyCommand() {
        guard let commandPreview else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(commandPreview, forType: .string)
    }

    func clearCache() {
        cancel()
        do {
            try cache.clear()
            cacheCount = 0
            cachedAt = nil
            staleMessage = nil
        } catch {
            errorMessage = "탐색 캐시를 삭제하지 못했습니다: \(error.localizedDescription)"
        }
    }

    func handleSuccessfulCleanup(paths: [String]) {
        guard !paths.isEmpty else { return }
        cache.invalidate(targetPaths: paths)
        cacheCount = cache.count
        guard let current = currentURL?.standardizedFileURL.path,
              paths.contains(where: { current == "/" || $0 == current || $0.hasPrefix(current + "/") }) else { return }
        refresh()
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    private func restoreLastLocation() {
        guard let cached = cache.loadLastAvailable() else { return }
        let url = URL(fileURLWithPath: cached.snapshot.folderPath, isDirectory: true)
        currentURL = url
        history = [url]
        historyIndex = 0
        apply(cached: cached)
        acquireAccess(for: url)
    }

    private func open(_ url: URL, addToHistory: Bool, scan: Bool) {
        persistCurrent(isComplete: currentScanComplete)
        scanGeneration = UUID()
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        acquireAccess(for: url)
        if currentURL?.standardizedFileURL.path != url.standardizedFileURL.path {
            searchText = ""
        }
        currentURL = url
        selectedPath = nil
        issues = []
        progress = ExplorerProgress(
            completedDirectoryCount: 0,
            totalDirectoryCount: 0,
            visitedItemCount: 0,
            currentPath: nil
        )
        if addToHistory {
            if historyIndex + 1 < history.count {
                history.removeSubrange((historyIndex + 1)..<history.count)
            }
            if history.last?.standardizedFileURL.path != url.standardizedFileURL.path {
                history.append(url)
            }
            historyIndex = history.count - 1
        }
        if let cached = cache.load(path: url.path) {
            apply(cached: cached)
            return
        } else {
            entryMap = [:]
            entries = []
            cachedAt = nil
            staleMessage = nil
            currentScanComplete = false
        }
        if scan { startScan(at: url) }
    }

    private func startScan(at url: URL) {
        persistCurrent(isComplete: currentScanComplete)
        scanGeneration = UUID()
        scanTask?.cancel()
        let generation = scanGeneration
        discoveredPaths = []
        entryMap = entryMap.mapValues { replacing($0, state: .stale, error: $0.errorMessage) }
        entries = visibleEntries
        issues = []
        staleMessage = nil
        isScanning = true
        currentScanComplete = false
        scanStartedAt = Date()
        hasUnsavedScanChanges = true

        scanTask = Task { [scanner] in
            var discoveredCount = 0
            var calculationUpdateCount = 0
            do {
                for try await event in scanner.events(at: url) {
                    try Task.checkCancellation()
                    guard scanGeneration == generation,
                          currentURL?.standardizedFileURL.path == url.standardizedFileURL.path else {
                        throw CancellationError()
                    }
                    hasUnsavedScanChanges = true
                    switch event {
                    case .childDiscovered(let entry):
                        discoveredCount += 1
                        discoveredPaths.insert(entry.path)
                        entryMap[entry.path] = entry
                        if discoveredCount <= 10 || discoveredCount.isMultiple(of: 1_000) {
                            entries = visibleEntries
                        }
                    case .sizeCalculationStarted(let path):
                        if let entry = entryMap[path] {
                            entryMap[path] = replacing(entry, state: .calculating, error: entry.errorMessage)
                            calculationUpdateCount += 1
                            if calculationUpdateCount.isMultiple(of: 20) { entries = visibleEntries }
                        }
                    case .sizeCalculationCompleted(let entry):
                        entryMap[entry.path] = entry
                        calculationUpdateCount += 1
                        if calculationUpdateCount.isMultiple(of: 10) { entries = visibleEntries }
                    case .progress(let newProgress):
                        progress = newProgress
                    case .accessError(let path, let message):
                        if issues.count < 200 { issues.append(ScanIssue(path: path, message: message)) }
                    case .finished(let scannedAt):
                        entryMap = entryMap.filter { discoveredPaths.contains($0.key) }
                        entries = visibleEntries
                        cachedAt = scannedAt
                        currentScanComplete = true
                        persistCurrent(isComplete: true, scannedAt: scannedAt)
                    }
                }
            } catch is CancellationError {
                // 이동·취소 시 이전 세대의 결과는 현재 화면을 갱신하지 않는다.
            } catch {
                if scanGeneration == generation {
                    errorMessage = "폴더를 탐색하지 못했습니다: \(error.localizedDescription)"
                    persistCurrent(isComplete: false)
                }
            }
            if scanGeneration == generation {
                isScanning = false
                scanTask = nil
            }
        }
    }

    private func apply(cached: ExplorerCachedFolder) {
        hasUnsavedScanChanges = false
        let cachedEntries: [ExplorerEntry]
        if cached.staleReason == nil {
            cachedEntries = cached.snapshot.entries
        } else {
            cachedEntries = cached.snapshot.entries.map {
                replacing($0, state: .stale, error: $0.errorMessage)
            }
        }
        entryMap = Dictionary(uniqueKeysWithValues: cachedEntries.map { ($0.path, $0) })
        entries = visibleEntries
        cachedAt = cached.snapshot.scannedAt
        staleMessage = cached.staleReason
        currentScanComplete = cached.snapshot.isComplete
    }

    private func persistCurrent(isComplete: Bool, scannedAt: Date? = nil) {
        // Revisiting cached data must not give old measurements a new folder timestamp.
        guard let currentURL, hasUnsavedScanChanges else { return }
        try? cache.save(
            folder: currentURL,
            entries: Array(entryMap.values),
            scannedAt: scannedAt ?? cachedAt ?? scanStartedAt,
            isComplete: isComplete
        )
        cacheCount = cache.count
        hasUnsavedScanChanges = false
    }

    private func acquireAccess(for url: URL) {
        currentAccess = nil
        let path = url.standardizedFileURL.path
        if let registered = folderStore.folders.first(where: {
            let root = $0.url.standardizedFileURL.path
            return path == root || path.hasPrefix(root + "/")
        }) {
            currentAccess = folderStore.beginAccessing(registered)
        }
    }

    private func externalVolumes() -> [ExplorerLocation] {
        let keys: [URLResourceKey] = [.volumeNameKey, .volumeIsInternalKey, .volumeIsBrowsableKey]
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys,
            options: [.skipHiddenVolumes]
        ) ?? []
        return urls.compactMap { url in
            guard url.standardizedFileURL.path != "/",
                  let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.volumeIsBrowsable != false,
                  values.volumeIsInternal != true else { return nil }
            return ExplorerLocation(
                url: url,
                title: values.volumeName ?? url.lastPathComponent,
                subtitle: "연결된 외장 볼륨 · \(url.path)",
                kind: .external
            )
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func isPackage(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isPackageKey]))?.isPackage == true
    }

    private func replacing(
        _ entry: ExplorerEntry,
        state: ExplorerCalculationState,
        error: String?
    ) -> ExplorerEntry {
        ExplorerEntry(
            path: entry.path,
            kind: entry.kind,
            allocatedSize: entry.allocatedSize,
            logicalSize: entry.logicalSize,
            modifiedAt: entry.modifiedAt,
            isHidden: entry.isHidden,
            volumeIdentifier: entry.volumeIdentifier,
            calculationState: state,
            errorMessage: error
        )
    }

    private func compare(_ lhs: ExplorerEntry, _ rhs: ExplorerEntry) -> ComparisonResult {
        switch sortKey {
        case .allocatedSize:
            compare(lhs.allocatedSize, rhs.allocatedSize)
        case .logicalSize:
            compare(lhs.logicalSize, rhs.logicalSize)
        case .name:
            lhs.name.localizedStandardCompare(rhs.name)
        case .modifiedAt:
            compare(lhs.modifiedAt, rhs.modifiedAt)
        case .kind:
            lhs.kind.title.localizedStandardCompare(rhs.kind.title)
        case .risk:
            compare(riskRank(cleanupItem(for: lhs).assessment.risk), riskRank(cleanupItem(for: rhs).assessment.risk))
        }
    }

    private func compare<T: Comparable>(_ lhs: T?, _ rhs: T?) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (.some(lhs), .some(rhs)): compare(lhs, rhs)
        case (.none, .some): .orderedDescending
        case (.some, .none): .orderedAscending
        case (.none, .none): .orderedSame
        }
    }

    private func compare<T: Comparable>(_ lhs: T, _ rhs: T) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    private func riskRank(_ risk: CleanupRisk) -> Int {
        switch risk { case .safe: 0; case .review: 1; case .avoid: 2 }
    }
}
