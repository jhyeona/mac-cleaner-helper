import Foundation

struct ScannedEntry: Hashable, Sendable {
    let path: String
    let logicalSize: Int64
    let allocatedSize: Int64
    let modifiedAt: Date?
    let kind: CandidateKind
    let isHidden: Bool
    let isOnExternalVolume: Bool
    let isComplete: Bool

    /// 이전 API와의 호환용이며 정렬과 예상 확보량에는 실제 할당 크기를 쓴다.
    var size: Int64 { allocatedSize }
}

struct ScanIssue: Hashable, Codable, Sendable {
    let path: String
    let message: String
}

struct ScanProgress: Hashable, Sendable {
    let completedTopLevelEntries: Int
    let totalTopLevelEntries: Int
    let visitedFileCount: Int
    let currentPath: String?

    var fractionCompleted: Double {
        guard totalTopLevelEntries > 0 else { return 1 }
        return Double(completedTopLevelEntries) / Double(totalTopLevelEntries)
    }
}

enum ScanEvent: Sendable {
    case started(root: String, topLevelEntryCount: Int)
    case entry(ScannedEntry)
    case progress(ScanProgress)
    case issue(ScanIssue)
    case finished
}

struct ScanOptions: Hashable, Sendable {
    var includeHiddenFiles = true
    var includePackageContents = true
    var stayOnSelectedVolume = true
}

struct DirectoryScanner: Sendable {
    private var resourceKeys: Set<URLResourceKey> {
        [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
            .isPackageKey, .isHiddenKey, .contentModificationDateKey,
            .fileSizeKey, .fileAllocatedSizeKey,
            .totalFileSizeKey, .totalFileAllocatedSizeKey,
            .volumeURLKey
        ]
    }

    /// 각 최상위 항목을 발견 즉시 내보낸 뒤 계산 완료본으로 갱신한다.
    /// 무거운 파일 시스템 순회는 호출자의 executor를 막지 않도록 detached task에서 수행한다.
    func events(
        at root: URL,
        options: ScanOptions = ScanOptions()
    ) -> AsyncThrowingStream<ScanEvent, Error> {
        AsyncThrowingStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try scan(root: root, options: options) { event in
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    /// 테스트와 작은 폴더를 위한 동기 API. UI에서는 `events(at:)`를 사용한다.
    func scanTopLevel(at root: URL, options: ScanOptions = ScanOptions()) throws -> [ScannedEntry] {
        var finalEntries: [String: ScannedEntry] = [:]
        try scan(root: root, options: options) { event in
            guard case .entry(let entry) = event, entry.isComplete else { return }
            finalEntries[entry.path] = entry
        }
        return finalEntries.values.sorted(by: entrySort)
    }

    /// 탐지 팩이 지목한 단일 경로의 크기를 잰다.
    func measure(at url: URL, options: ScanOptions = ScanOptions()) throws -> ScannedEntry {
        let values = try url.resourceValues(forKeys: resourceKeys)
        let entryKind = kind(from: values)
        var logical = Int64(values.totalFileSize ?? values.fileSize ?? 0)
        var allocated = Int64(
            values.totalFileAllocatedSize
                ?? values.fileAllocatedSize
                ?? values.totalFileSize
                ?? values.fileSize
                ?? 0
        )
        if entryKind == .directory || entryKind == .package {
            var visited = 0
            let sizes = try recursiveSizes(
                of: url,
                includePackageContents: options.includePackageContents,
                allowedVolumePath: volumePath(for: url),
                stayOnSelectedVolume: options.stayOnSelectedVolume,
                visitedFileCount: &visited,
                emit: { _ in }
            )
            logical = sizes.logical
            allocated = sizes.allocated
        }
        return ScannedEntry(
            path: url.path, logicalSize: logical, allocatedSize: allocated,
            modifiedAt: values.contentModificationDate, kind: entryKind,
            isHidden: values.isHidden ?? url.lastPathComponent.hasPrefix("."),
            isOnExternalVolume: false, isComplete: true
        )
    }

    private func scan(
        root: URL,
        options: ScanOptions,
        emit: (ScanEvent) -> Void
    ) throws {
        let fileManager = FileManager.default
        var directoryOptions: FileManager.DirectoryEnumerationOptions = []
        if !options.includeHiddenFiles { directoryOptions.insert(.skipsHiddenFiles) }

        guard try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw CocoaError(.fileReadNoSuchFile)
        }
        directoryOptions.insert(.skipsSubdirectoryDescendants)
        var rootIssues: [ScanIssue] = []
        guard let topLevelEnumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: Array(resourceKeys),
            options: directoryOptions,
            errorHandler: { url, error in
                rootIssues.append(ScanIssue(path: url.path, message: error.localizedDescription))
                return true
            }
        ) else {
            throw CocoaError(.fileReadNoPermission)
        }
        // 전체 목록을 먼저 적재하지 않아 대용량 폴더에서도 첫 항목을 즉시 전달한다.
        emit(.started(root: root.path, topLevelEntryCount: 0))

        let rootVolume = volumePath(for: root)
        var visitedFileCount = 0

        var completedTopLevelEntries = 0
        for case let child as URL in topLevelEnumerator {
            try Task.checkCancellation()
            completedTopLevelEntries += 1
            let values: URLResourceValues
            do {
                values = try child.resourceValues(forKeys: resourceKeys)
            } catch {
                emit(.issue(ScanIssue(path: child.path, message: error.localizedDescription)))
                emit(.entry(ScannedEntry(
                    path: child.path, logicalSize: 0, allocatedSize: 0,
                    modifiedAt: nil, kind: .inaccessible,
                    isHidden: child.lastPathComponent.hasPrefix("."),
                    isOnExternalVolume: false, isComplete: true
                )))
                emit(.progress(ScanProgress(
                    completedTopLevelEntries: completedTopLevelEntries,
                    totalTopLevelEntries: 0,
                    visitedFileCount: visitedFileCount,
                    currentPath: child.path
                )))
                continue
            }

            let kind = kind(from: values)
            let external = rootVolume != volumePath(for: child)
            let initial = ScannedEntry(
                path: child.path,
                logicalSize: values.totalFileSize.map(Int64.init) ?? values.fileSize.map(Int64.init) ?? 0,
                allocatedSize: values.totalFileAllocatedSize.map(Int64.init) ?? values.fileAllocatedSize.map(Int64.init) ?? 0,
                modifiedAt: values.contentModificationDate,
                kind: kind,
                isHidden: values.isHidden ?? child.lastPathComponent.hasPrefix("."),
                isOnExternalVolume: external,
                isComplete: kind == .regularFile || kind == .symbolicLink
            )
            emit(.entry(initial))

            var completed = initial
            if kind == .directory || kind == .package {
                if external && options.stayOnSelectedVolume {
                    emit(.issue(ScanIssue(path: child.path, message: "선택한 볼륨 밖의 항목이라 건너뛰었습니다.")))
                    completed = replacingSizes(in: initial, logical: 0, allocated: 0, isComplete: true)
                } else {
                    let sizes = try recursiveSizes(
                        of: child,
                        includePackageContents: options.includePackageContents,
                        allowedVolumePath: rootVolume,
                        stayOnSelectedVolume: options.stayOnSelectedVolume,
                        visitedFileCount: &visitedFileCount,
                        emit: emit
                    )
                    completed = replacingSizes(
                        in: initial,
                        logical: sizes.logical,
                        allocated: sizes.allocated,
                        isComplete: true
                    )
                    for issue in sizes.issues { emit(.issue(issue)) }
                }
                emit(.entry(completed))
            }

            emit(.progress(ScanProgress(
                completedTopLevelEntries: completedTopLevelEntries,
                totalTopLevelEntries: 0,
                visitedFileCount: visitedFileCount,
                currentPath: child.path
            )))
        }
        for issue in rootIssues { emit(.issue(issue)) }
        emit(.progress(ScanProgress(
            completedTopLevelEntries: completedTopLevelEntries,
            totalTopLevelEntries: completedTopLevelEntries,
            visitedFileCount: visitedFileCount,
            currentPath: nil
        )))
        emit(.finished)
    }

    private func recursiveSizes(
        of root: URL,
        includePackageContents: Bool,
        allowedVolumePath: String?,
        stayOnSelectedVolume: Bool,
        visitedFileCount: inout Int,
        emit: (ScanEvent) -> Void
    ) throws -> (logical: Int64, allocated: Int64, issues: [ScanIssue]) {
        var logical: Int64 = 0
        var allocated: Int64 = 0
        var issues: [ScanIssue] = []
        var enumerationOptions: FileManager.DirectoryEnumerationOptions = []
        if !includePackageContents { enumerationOptions.insert(.skipsPackageDescendants) }

        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: Array(resourceKeys),
            options: enumerationOptions,
            errorHandler: { url, error in
                issues.append(ScanIssue(path: url.path, message: error.localizedDescription))
                return true
            }
        ) else {
            return (0, 0, [ScanIssue(path: root.path, message: "폴더 내용을 열 수 없습니다.")])
        }

        for case let descendant as URL in enumerator {
            try Task.checkCancellation()
            guard let values = try? descendant.resourceValues(forKeys: resourceKeys) else {
                issues.append(ScanIssue(path: descendant.path, message: "파일 정보를 읽을 수 없습니다."))
                continue
            }
            if values.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            if stayOnSelectedVolume,
               let allowedVolumePath,
               volumePath(for: descendant) != allowedVolumePath {
                enumerator.skipDescendants()
                issues.append(ScanIssue(
                    path: descendant.path,
                    message: "선택한 볼륨 밖의 항목이라 건너뛰었습니다."
                ))
                continue
            }
            guard values.isRegularFile == true else { continue }
            logical += Int64(values.totalFileSize ?? values.fileSize ?? 0)
            allocated += Int64(
                values.totalFileAllocatedSize
                    ?? values.fileAllocatedSize
                    ?? values.totalFileSize
                    ?? values.fileSize
                    ?? 0
            )
            visitedFileCount += 1
            if visitedFileCount.isMultiple(of: 256) {
                emit(.progress(ScanProgress(
                    completedTopLevelEntries: 0,
                    totalTopLevelEntries: 0,
                    visitedFileCount: visitedFileCount,
                    currentPath: descendant.path
                )))
            }
        }
        return (logical, allocated, issues)
    }

    private func kind(from values: URLResourceValues) -> CandidateKind {
        if values.isSymbolicLink == true { return .symbolicLink }
        if values.isPackage == true { return .package }
        if values.isDirectory == true { return .directory }
        return .regularFile
    }

    private func volumePath(for url: URL) -> String? {
        (try? url.resourceValues(forKeys: [.volumeURLKey]))?.volume?.path
    }

    private func replacingSizes(
        in entry: ScannedEntry,
        logical: Int64,
        allocated: Int64,
        isComplete: Bool
    ) -> ScannedEntry {
        ScannedEntry(
            path: entry.path, logicalSize: logical, allocatedSize: allocated,
            modifiedAt: entry.modifiedAt, kind: entry.kind,
            isHidden: entry.isHidden, isOnExternalVolume: entry.isOnExternalVolume,
            isComplete: isComplete
        )
    }

    private func entrySort(_ lhs: ScannedEntry, _ rhs: ScannedEntry) -> Bool {
        if lhs.allocatedSize == rhs.allocatedSize { return lhs.path < rhs.path }
        return lhs.allocatedSize > rhs.allocatedSize
    }
}
