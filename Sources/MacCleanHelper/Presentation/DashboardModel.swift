import AppKit
import Foundation
import UniformTypeIdentifiers

enum BiuState: String, CaseIterable, Sendable {
    case greeting, scanning, cleaning, found, caution, protecting, completed, error, resting
}

enum CleanupSortKey: String, CaseIterable, Identifiable, Sendable {
    case allocatedSize
    case logicalSize
    case name
    case modifiedAt
    case risk
    case tool

    var id: Self { self }

    var title: String {
        switch self {
        case .allocatedSize: "실제 할당 크기"
        case .logicalSize: "논리적 크기"
        case .name: "이름"
        case .modifiedAt: "수정일"
        case .risk: "안전도"
        case .tool: "도구"
        }
    }

    var compactTitle: String {
        switch self {
        case .allocatedSize: "실제 크기"
        case .logicalSize: "논리 크기"
        default: title
        }
    }

    var defaultAscending: Bool {
        switch self {
        case .name, .risk, .tool: true
        case .allocatedSize, .logicalSize, .modifiedAt: false
        }
    }

    func sorted(_ items: [CleanupItem], ascending: Bool) -> [CleanupItem] {
        items.sorted { lhs, rhs in
            if self == .modifiedAt {
                switch (lhs.candidate.modifiedAt, rhs.candidate.modifiedAt) {
                case (.none, .some): return false
                case (.some, .none): return true
                default: break
                }
            }

            let comparison = compare(lhs, rhs)
            if comparison == .orderedSame {
                return lhs.path.localizedStandardCompare(rhs.path) == .orderedAscending
            }
            return ascending
                ? comparison == .orderedAscending
                : comparison == .orderedDescending
        }
    }

    private func compare(_ lhs: CleanupItem, _ rhs: CleanupItem) -> ComparisonResult {
        switch self {
        case .allocatedSize:
            compare(lhs.candidate.allocatedSize, rhs.candidate.allocatedSize)
        case .logicalSize:
            compare(lhs.candidate.logicalSize, rhs.candidate.logicalSize)
        case .name:
            lhs.name.localizedStandardCompare(rhs.name)
        case .modifiedAt:
            compare(lhs.candidate.modifiedAt, rhs.candidate.modifiedAt)
        case .risk:
            compare(riskRank(lhs.assessment.risk), riskRank(rhs.assessment.risk))
        case .tool:
            lhs.candidate.tool.localizedStandardCompare(rhs.candidate.tool)
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
        switch risk {
        case .safe: 0
        case .review: 1
        case .avoid: 2
        }
    }
}

struct CleanupConfirmation: Identifiable, Sendable {
    let id = UUID()
    let preparations: [CleanupPreparation]

    var estimatedBytes: Int64 {
        preparations.reduce(0) { $0 + $1.item.candidate.allocatedSize }
    }
}

struct CleanupResult: Identifiable, Sendable {
    let id = UUID()
    let receipts: [CleanupReceipt]

    var succeededCount: Int { receipts.filter(\.succeeded).count }
    var failedCount: Int { receipts.count - succeededCount }
    var reclaimedBytes: Int64 {
        receipts.filter(\.succeeded).reduce(0) { result, receipt in
            result + max(0, receipt.sizeBefore - receipt.sizeAfter)
        }
    }
}

private struct ScanBackup {
    let items: [CleanupItem]
    let scannedFolders: [URL]
    let issues: [ScanIssue]
    let selectedIDs: Set<CleanupItem.ID>
    let lastAnalysisAt: Date?
}

@MainActor
final class DashboardModel: ObservableObject {
    @Published private(set) var items: [CleanupItem] = []
    @Published private(set) var scannedFolders: [URL] = []
    @Published private(set) var isScanning = false
    @Published private(set) var isPreparingCleanup = false
    @Published private(set) var isCleaning = false
    @Published private(set) var scanProgress = ScanProgress(
        completedTopLevelEntries: 0, totalTopLevelEntries: 0,
        visitedFileCount: 0, currentPath: nil
    )
    @Published private(set) var scanIssues: [ScanIssue] = []
    @Published private(set) var selectedIDs: Set<CleanupItem.ID> = []
    @Published private(set) var explorerBasketItems: [CleanupItem.ID: CleanupItem] = [:]
    @Published private(set) var receipts: [CleanupReceipt] = []
    @Published private(set) var lastAnalysisAt: Date?
    @Published private(set) var lastSuccessfulCleanupPaths: [String] = []
    @Published private(set) var cleanupInvalidationID = UUID()
    @Published private(set) var inspectedID: CleanupItem.ID?
    @Published var errorMessage: String?
    @Published var confirmation: CleanupConfirmation?
    @Published var cleanupResult: CleanupResult?
    @Published var showWholeDiskWarning = false
    @Published var showBroadFolderWarning = false
    @Published var searchText = ""
    @Published var riskFilter: CleanupRisk?
    @Published var categoryFilter: CleanupCategory?
    @Published var sortKey: CleanupSortKey = .allocatedSize {
        didSet { UserDefaults.standard.set(sortKey.rawValue, forKey: "Biu.sortKey") }
    }
    @Published var sortAscending = false {
        didSet { UserDefaults.standard.set(sortAscending, forKey: "Biu.sortAscending") }
    }
    @Published var allowsImmediateCacheDeletion = false {
        didSet {
            UserDefaults.standard.set(allowsImmediateCacheDeletion, forKey: "Biu.allowsImmediateCacheDeletion")
        }
    }

    let folderStore: FolderBookmarkStore

    private let scanner = DirectoryScanner()
    private let detectors = DetectorRegistry()
    private let cleanupEngine = CleanupEngine()
    private let receiptStore: CleanupReceiptStore?
    private let snapshotStore: AnalysisSnapshotStore?
    private var scanTask: Task<Void, Never>?
    private var scanGeneration = UUID()
    private var scanBackup: ScanBackup?
    private var didCompleteCleanupThisSession = false
    private var didFailCleanupThisSession = false

    init() {
        folderStore = FolderBookmarkStore()
        receiptStore = try? CleanupReceiptStore()
        snapshotStore = try? AnalysisSnapshotStore()
        restorePersistentState()
    }

    init(
        folderStore: FolderBookmarkStore,
        receiptStore: CleanupReceiptStore?,
        snapshotStore: AnalysisSnapshotStore?
    ) {
        self.folderStore = folderStore
        self.receiptStore = receiptStore
        self.snapshotStore = snapshotStore
        restorePersistentState()
    }

    private func restorePersistentState() {
        receipts = (try? receiptStore?.all()) ?? []
        if let snapshotStore,
           let snapshot = try? snapshotStore.load() {
            // 크기와 경로는 마지막 완료 분석에서 즉시 복원하되, 안전 판정은
            // 앱에 포함된 최신 보호 규칙으로 다시 계산한다. 규칙이 강화된 뒤에도
            // 오래된 스냅샷의 선택 가능 상태가 남는 일을 막는다.
            items = snapshot.items.map(refreshSafetyAssessment)
            scannedFolders = snapshot.scannedFolderPaths.map {
                URL(fileURLWithPath: $0, isDirectory: true)
            }
            scanIssues = snapshot.issues
            lastAnalysisAt = snapshot.savedAt
        }
        allowsImmediateCacheDeletion = UserDefaults.standard.bool(forKey: "Biu.allowsImmediateCacheDeletion")
        if let savedSortKey = UserDefaults.standard.string(forKey: "Biu.sortKey"),
           let sortKey = CleanupSortKey(rawValue: savedSortKey) {
            self.sortKey = sortKey
            sortAscending = UserDefaults.standard.bool(forKey: "Biu.sortAscending")
        }
    }

    private func refreshSafetyAssessment(for storedItem: CleanupItem) -> CleanupItem {
        let candidate = storedItem.candidate
        return detectors.item(for: ScannedEntry(
            path: candidate.path,
            logicalSize: candidate.logicalSize,
            allocatedSize: candidate.allocatedSize,
            modifiedAt: candidate.modifiedAt,
            kind: candidate.kind,
            isHidden: URL(fileURLWithPath: candidate.path).lastPathComponent.hasPrefix("."),
            isOnExternalVolume: false,
            isComplete: true
        ))
    }

    var filteredItems: [CleanupItem] {
        let filtered = items.filter { item in
            let matchesSearch = searchText.isEmpty
                || item.name.localizedCaseInsensitiveContains(searchText)
                || item.path.localizedCaseInsensitiveContains(searchText)
                || item.candidate.tool.localizedCaseInsensitiveContains(searchText)
            let matchesRisk = riskFilter == nil || item.assessment.risk == riskFilter
            let matchesCategory = categoryFilter == nil || item.category == categoryFilter
            return matchesSearch && matchesRisk && matchesCategory
        }
        return sortKey.sorted(filtered, ascending: sortAscending)
    }

    func selectSortKey(_ key: CleanupSortKey) {
        guard key != sortKey else { return }
        sortKey = key
        sortAscending = key.defaultAscending
    }

    func toggleSortDirection() {
        sortAscending.toggle()
    }

    var selectedItems: [CleanupItem] {
        var byID = Dictionary(uniqueKeysWithValues: items
            .filter { selectedIDs.contains($0.id) }
            .map { ($0.id, $0) })
        for (id, item) in explorerBasketItems where selectedIDs.contains(id) {
            byID[id] = item
        }
        return byID.values.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    var selectedSize: Int64 { selectedItems.reduce(0) { $0 + $1.size } }
    var reclaimableSize: Int64 {
        items.filter { $0.assessment.risk == .safe }.reduce(0) { $0 + $1.size }
    }

    var isBusy: Bool { isScanning || isPreparingCleanup || isCleaning }

    var hasBroadRegisteredFolder: Bool {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        return folderStore.selectedFolders.contains { folder in
            guard !folder.isStale else { return false }
            let path = folder.url.standardizedFileURL.path
            return path == "/" || path == homePath
        }
    }

    var biuState: BiuState {
        if errorMessage != nil { return .error }
        if isScanning { return .scanning }
        if isCleaning { return .cleaning }
        if didFailCleanupThisSession { return .error }
        if didCompleteCleanupThisSession { return .completed }
        if inspectedItem?.assessment.risk == .avoid { return .protecting }
        if inspectedItem?.assessment.risk == .review
            || selectedItems.contains(where: { $0.assessment.risk == .review }) { return .caution }
        if !items.isEmpty { return .found }
        if scannedFolders.isEmpty, folderStore.folders.isEmpty { return .greeting }
        return .resting
    }

    private var inspectedItem: CleanupItem? {
        items.first { $0.id == inspectedID }
    }

    var assistantMessage: String {
        switch biuState {
        case .greeting:
            "안녕하세요, 비우예요. 개발 폴더를 등록하면 무엇이 공간을 쓰는지 영향까지 설명해 드릴게요."
        case .scanning:
            "파일은 건드리지 않고 살펴보는 중이에요. 원할 때 언제든 분석을 취소할 수 있어요."
        case .cleaning:
            "선택한 항목을 정리하고 있어요. 결과가 나올 때까지 앱을 종료하지 말아 주세요."
        case .found:
            "후보를 찾았어요. \(sortKey.title) \(sortAscending ? "오름차순" : "내림차순")으로 보여드리며, 아무 항목도 자동 선택하지 않았어요."
        case .caution:
            "확인이 필요한 항목이에요. 영향과 복구 방법을 읽고 선택해 주세요."
        case .protecting:
            "이 항목은 보호 대상이라 비우가 정리하지 않아요. 해당 앱에서 직접 관리해 주세요."
        case .completed:
            "정리 결과를 기록했어요. 예상 용량과 실제 여유 공간 변화는 서로 다를 수 있어요."
        case .error:
            "작업을 마치지 못했어요. 파일은 보호했고, 원인을 아래에서 확인할 수 있어요."
        case .resting:
            if !folderStore.selectedFolders.isEmpty, lastAnalysisAt == nil {
                "등록한 개발 폴더가 준비됐어요. 분석을 시작하면 공간을 쓰는 항목과 영향을 함께 보여드릴게요."
            } else if !folderStore.folders.isEmpty, folderStore.selectedFolders.isEmpty {
                "분석할 개발 폴더를 하나 이상 선택해 주세요. 등록은 유지한 채 분석 대상만 바꿀 수 있어요."
            } else {
                "지금 보여드릴 정리 후보가 없어요. 다른 개발 폴더를 등록하거나 추천 영역을 살펴볼까요?"
            }
        }
    }

    func chooseAndRegisterFolders(startScan: Bool = true) {
        let panel = NSOpenPanel()
        panel.title = "비우가 살펴볼 개발 폴더를 선택하세요"
        panel.message = "선택한 폴더를 등록하고 읽기만 합니다. 여러 폴더를 한 번에 선택할 수 있어요."
        panel.prompt = "폴더 등록"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.showsHiddenFiles = true

        guard panel.runModal() == .OK else { return }
        do {
            for url in panel.urls { try folderStore.add(url) }
            if startScan { requestRegisteredFolderScan() }
        } catch {
            errorMessage = "폴더 권한을 저장하지 못했습니다: \(error.localizedDescription)"
        }
    }

    func requestRegisteredFolderScan() {
        let availableFolders = folderStore.selectedFolders.filter { !$0.isStale }
        guard !availableFolders.isEmpty else {
            errorMessage = folderStore.selectedFolders.isEmpty
                ? "분석할 등록 폴더를 하나 이상 선택해 주세요."
                : "선택한 폴더를 찾을 수 없습니다. 설정에서 제거한 뒤 다시 등록해 주세요."
            return
        }
        if hasBroadRegisteredFolder {
            showBroadFolderWarning = true
        } else {
            scanRegisteredFolders()
        }
    }

    func scanRegisteredFolders() {
        let folders = folderStore.selectedFolders.filter { !$0.isStale }
        guard !folders.isEmpty else {
            errorMessage = "분석할 수 있는 선택 폴더가 없습니다."
            return
        }
        let tokens = folders.map(folderStore.beginAccessing)
        let staleIssues = folderStore.selectedFolders.filter(\.isStale).map {
            ScanIssue(path: $0.url.path, message: "폴더를 찾을 수 없어 건너뛰었습니다.")
        }
        scan(folders: folders.map(\.url), accessTokens: tokens, initialIssues: staleIssues)
    }

    func removeRegisteredFolder(_ folder: RegisteredFolder) {
        folderStore.remove(folder)
        let removedPath = folder.url.standardizedFileURL.path
        guard scannedFolders.contains(where: { $0.standardizedFileURL.path == removedPath }) else { return }
        scannedFolders.removeAll { $0.standardizedFileURL.path == removedPath }
        items.removeAll { item in
            item.path == removedPath || item.path.hasPrefix(removedPath + "/")
        }
        selectedIDs.formIntersection(items.map(\.id))
        persistSnapshot()
    }

    func scanRecommendedAreas() {
        cancelScan()
        captureScanBackup()
        let generation = UUID()
        scanGeneration = generation
        let locations = detectors.recommendedLocations()
        guard !locations.isEmpty else {
            errorMessage = "현재 Mac에서 지원하는 개발 도구 캐시 위치를 찾지 못했습니다."
            return
        }
        items = []
        selectedIDs = []
        scanIssues = []
        scannedFolders = locations.map(\.url)
        lastAnalysisAt = nil
        errorMessage = nil
        isScanning = true
        didCompleteCleanupThisSession = false
        didFailCleanupThisSession = false
        scanProgress = ScanProgress(
            completedTopLevelEntries: 0, totalTopLevelEntries: locations.count,
            visitedFileCount: 0, currentPath: nil
        )

        scanTask = Task { [scanner, detectors] in
            var found: [CleanupItem] = []
            do {
                for (index, location) in locations.enumerated() {
                    try Task.checkCancellation()
                    guard scanGeneration == generation else { throw CancellationError() }
                    scanProgress = ScanProgress(
                        completedTopLevelEntries: index,
                        totalTopLevelEntries: locations.count,
                        visitedFileCount: index,
                        currentPath: location.url.path
                    )
                    let measurement = Task.detached(priority: .userInitiated) {
                        try scanner.measure(at: location.url)
                    }
                    let entry = try await withTaskCancellationHandler {
                        try await measurement.value
                    } onCancel: {
                        measurement.cancel()
                    }
                    try Task.checkCancellation()
                    guard scanGeneration == generation else { throw CancellationError() }
                    found.append(detectors.item(for: entry))
                    items = found.sorted { $0.size > $1.size }
                }
                scanProgress = ScanProgress(
                    completedTopLevelEntries: locations.count,
                    totalTopLevelEntries: locations.count,
                    visitedFileCount: locations.count,
                    currentPath: nil
                )
                guard scanGeneration == generation else { return }
                persistSnapshot()
                scanBackup = nil
            } catch is CancellationError {
                if scanGeneration == generation { restoreScanBackup() }
            } catch {
                if scanGeneration == generation {
                    restoreScanBackup()
                    errorMessage = "추천 영역을 분석하지 못했습니다: \(error.localizedDescription)"
                }
            }
            if scanGeneration == generation {
                isScanning = false
                scanTask = nil
            }
        }
    }

    func scan(folder: URL) {
        scan(folders: [folder], accessTokens: [])
    }

    func requestWholeDiskScan() {
        showWholeDiskWarning = true
    }

    func confirmWholeDiskScan() {
        showWholeDiskWarning = false
        scan(folders: [URL(fileURLWithPath: "/", isDirectory: true)], accessTokens: [])
    }

    func cancelScan() {
        guard isScanning else { return }
        scanGeneration = UUID()
        scanTask?.cancel()
        scanTask = nil
        isScanning = false
        restoreScanBackup()
    }

    func toggleSelection(of item: CleanupItem) {
        guard item.assessment.risk != .avoid else {
            errorMessage = "\(item.name)은(는) 보호 대상이라 정리 바구니에 담을 수 없습니다."
            return
        }
        if selectedIDs.contains(item.id) {
            selectedIDs.remove(item.id)
            explorerBasketItems.removeValue(forKey: item.id)
        } else {
            if selectedItems.contains(where: { selected in
                item.path.hasPrefix(selected.path + "/")
            }) {
                return
            }
            let descendants = selectedItems.filter { selected in
                selected.path.hasPrefix(item.path + "/")
            }
            selectedIDs.subtract(descendants.map(\.id))
            for descendant in descendants {
                explorerBasketItems.removeValue(forKey: descendant.id)
            }
            selectedIDs.insert(item.id)
        }
    }

    func toggleExplorerSelection(_ item: CleanupItem, calculationIsComplete: Bool) {
        if selectedIDs.contains(item.id) {
            toggleSelection(of: item)
            return
        }
        guard calculationIsComplete else {
            errorMessage = "크기 계산이 끝난 항목만 정리 바구니에 담을 수 있습니다."
            return
        }
        guard item.candidate.kind != .symbolicLink, item.candidate.kind != .inaccessible else {
            errorMessage = "심볼릭 링크와 접근 불가 항목은 정리 바구니에 담을 수 없습니다."
            return
        }
        explorerBasketItems[item.id] = item
        toggleSelection(of: item)
        if !selectedIDs.contains(item.id) {
            explorerBasketItems.removeValue(forKey: item.id)
        }
    }

    func isInBasket(path: String) -> Bool {
        selectedIDs.contains(path)
    }

    func inspect(_ itemID: CleanupItem.ID?) {
        inspectedID = itemID
    }

    func revealInFinder(_ item: CleanupItem) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: item.path)])
    }

    func exportReceipts() {
        guard let receiptStore else { return }
        do {
            let panel = NSSavePanel()
            panel.title = "비우 정리 내역 내보내기"
            panel.nameFieldStringValue = "biu-cleanup-history.json"
            panel.allowedContentTypes = [.json]
            guard panel.runModal() == .OK, let url = panel.url else { return }
            try receiptStore.exportData().write(to: url, options: .atomic)
        } catch {
            errorMessage = "정리 내역을 내보내지 못했습니다: \(error.localizedDescription)"
        }
    }

    func deleteAllReceipts() {
        do {
            try receiptStore?.deleteAll()
            receipts = []
        } catch {
            errorMessage = "정리 내역을 삭제하지 못했습니다: \(error.localizedDescription)"
        }
    }

    func prepareSelectedCleanup() {
        let selected = selectedItems
        guard !selected.isEmpty, !isPreparingCleanup, !isCleaning else { return }
        isPreparingCleanup = true
        Task {
            defer { isPreparingCleanup = false }
            do {
                var preparations: [CleanupPreparation] = []
                for item in selected {
                    var action = item.recommendedAction
                    if action == .deleteRegeneratableCache && !allowsImmediateCacheDeletion {
                        action = .moveToTrash
                    }
                    preparations.append(try await cleanupEngine.prepare(item: item, action: action))
                }
                confirmation = CleanupConfirmation(preparations: preparations)
            } catch {
                errorMessage = "실행 전 검증에서 중단했습니다: \(error.localizedDescription)"
            }
        }
    }

    func executeConfirmedCleanup() {
        guard let current = confirmation, !isCleaning else { return }
        confirmation = nil
        isCleaning = true
        didFailCleanupThisSession = false
        Task {
            var newReceipts: [CleanupReceipt] = []
            for preparation in current.preparations {
                let receipt = await cleanupEngine.execute(preparation)
                newReceipts.append(receipt)
                try? receiptStore?.append(receipt)
            }
            receipts.insert(contentsOf: newReceipts, at: 0)
            didCompleteCleanupThisSession = newReceipts.contains(where: \.succeeded)
            didFailCleanupThisSession = newReceipts.contains { !$0.succeeded }
            let succeeded = Set(newReceipts.filter(\.succeeded).map(\.path))
            items.removeAll { succeeded.contains($0.path) }
            for path in succeeded { explorerBasketItems.removeValue(forKey: path) }
            selectedIDs.subtract(succeeded)
            lastSuccessfulCleanupPaths = succeeded.sorted()
            cleanupInvalidationID = UUID()
            persistSnapshot()
            isCleaning = false
            cleanupResult = CleanupResult(receipts: newReceipts)
        }
    }

    private func scan(
        folders: [URL],
        accessTokens: [SecurityScopedAccess],
        initialIssues: [ScanIssue] = []
    ) {
        cancelScan()
        captureScanBackup()
        let generation = UUID()
        scanGeneration = generation
        items = []
        selectedIDs = []
        scanIssues = initialIssues
        scannedFolders = folders
        lastAnalysisAt = nil
        errorMessage = nil
        isScanning = true
        didCompleteCleanupThisSession = false
        didFailCleanupThisSession = false

        scanTask = Task { [scanner, detectors, accessTokens] in
            // 보안 범위 토큰은 작업이 끝날 때까지 캡처되어 유지된다.
            _ = accessTokens
            var entries: [String: CleanupItem] = [:]
            do {
                for folder in folders {
                    try Task.checkCancellation()
                    guard scanGeneration == generation else { throw CancellationError() }
                    for try await event in scanner.events(at: folder) {
                        try Task.checkCancellation()
                        guard scanGeneration == generation else { throw CancellationError() }
                        switch event {
                        case .started(_, let count):
                            scanProgress = ScanProgress(
                                completedTopLevelEntries: 0,
                                totalTopLevelEntries: count,
                                visitedFileCount: 0,
                                currentPath: folder.path
                            )
                        case .entry(let entry):
                            entries[entry.path] = detectors.item(for: entry)
                            items = entries.values.sorted {
                                if $0.size == $1.size { return $0.path < $1.path }
                                return $0.size > $1.size
                            }
                        case .progress(let progress):
                            if progress.totalTopLevelEntries > 0 {
                                scanProgress = progress
                            } else {
                                scanProgress = ScanProgress(
                                    completedTopLevelEntries: max(
                                        scanProgress.completedTopLevelEntries,
                                        progress.completedTopLevelEntries
                                    ),
                                    totalTopLevelEntries: scanProgress.totalTopLevelEntries,
                                    visitedFileCount: progress.visitedFileCount,
                                    currentPath: progress.currentPath
                                )
                            }
                        case .issue(let issue):
                            if scanIssues.count < 200 { scanIssues.append(issue) }
                        case .finished:
                            break
                        }
                    }
                }
                guard scanGeneration == generation else { return }
                persistSnapshot()
                scanBackup = nil
            } catch is CancellationError {
                if scanGeneration == generation { restoreScanBackup() }
            } catch {
                if scanGeneration == generation {
                    restoreScanBackup()
                    errorMessage = "폴더를 분석하지 못했습니다: \(error.localizedDescription)"
                }
            }
            if scanGeneration == generation {
                isScanning = false
                scanTask = nil
            }
        }
    }

    private func persistSnapshot() {
        guard let snapshotStore else { return }
        let snapshot = AnalysisSnapshot(
            scannedFolderPaths: scannedFolders.map(\.standardizedFileURL.path),
            items: items,
            issues: scanIssues
        )
        do {
            try snapshotStore.save(snapshot)
            lastAnalysisAt = snapshot.savedAt
        } catch {
            // 분석 결과 표시와 정리 안전성은 스냅샷 저장 실패와 독립적으로 유지한다.
        }
    }

    private func captureScanBackup() {
        scanBackup = ScanBackup(
            items: items,
            scannedFolders: scannedFolders,
            issues: scanIssues,
            selectedIDs: selectedIDs,
            lastAnalysisAt: lastAnalysisAt
        )
    }

    private func restoreScanBackup() {
        guard let scanBackup else { return }
        items = scanBackup.items
        scannedFolders = scanBackup.scannedFolders
        scanIssues = scanBackup.issues
        selectedIDs = scanBackup.selectedIDs
        lastAnalysisAt = scanBackup.lastAnalysisAt
        self.scanBackup = nil
    }
}
