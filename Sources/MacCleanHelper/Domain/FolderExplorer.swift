import Darwin
import Foundation

enum ExplorerCalculationState: String, Codable, Sendable {
    case pending
    case calculating
    case complete
    case failed
    case stale

    var title: String {
        switch self {
        case .pending: "대기"
        case .calculating: "계산 중"
        case .complete: "완료"
        case .failed: "계산 실패"
        case .stale: "오래된 결과"
        }
    }
}

struct ExplorerEntry: Identifiable, Hashable, Codable, Sendable {
    let path: String
    let kind: CandidateKind
    let allocatedSize: Int64
    let logicalSize: Int64
    let modifiedAt: Date?
    let isHidden: Bool
    let volumeIdentifier: String
    let calculationState: ExplorerCalculationState
    let errorMessage: String?

    var id: String { path }
    var name: String {
        let name = URL(fileURLWithPath: path).lastPathComponent
        return name.isEmpty ? path : name
    }
    var canEnter: Bool { kind == .directory || kind == .package }
}

struct ExplorerProgress: Hashable, Codable, Sendable {
    let completedDirectoryCount: Int
    let totalDirectoryCount: Int
    let visitedItemCount: Int
    let currentPath: String?

    var fractionCompleted: Double {
        guard totalDirectoryCount > 0 else { return 1 }
        return Double(completedDirectoryCount) / Double(totalDirectoryCount)
    }
}

enum ExplorerScanEvent: Sendable {
    case childDiscovered(ExplorerEntry)
    case sizeCalculationStarted(path: String)
    case sizeCalculationCompleted(ExplorerEntry)
    case progress(ExplorerProgress)
    case accessError(path: String, message: String)
    case finished(scannedAt: Date)
}

struct FolderExplorerScanner: Sendable {
    private struct Measurement: Sendable {
        let entry: ExplorerEntry
        let issues: [(String, String)]
        let visitedCount: Int
    }

    func events(at root: URL) -> AsyncThrowingStream<ExplorerScanEvent, Error> {
        AsyncThrowingStream { (continuation: AsyncThrowingStream<ExplorerScanEvent, Error>.Continuation) in
            let task = Task.detached(priority: .userInitiated) {
                do {
                    try await scan(root: root.standardizedFileURL) { event in
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

    private func scan(
        root: URL,
        emit: @escaping @Sendable (sending ExplorerScanEvent) -> Void
    ) async throws {
        try Task.checkCancellation()
        let rootStat = try fileStat(at: root)
        guard isDirectory(rootStat) else { throw CocoaError(.fileReadNoSuchFile) }
        let allowedDevice = UInt64(rootStat.st_dev)

        let keys: [URLResourceKey] = [
            .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
            .isPackageKey, .isHiddenKey, .contentModificationDateKey
        ]
        let discovery = try discoverChildren(
            at: root,
            keys: keys,
            allowedDevice: allowedDevice,
            emit: emit
        )
        let directoryEntries = discovery.directories
        let childCount = discovery.childCount

        var nextIndex = 0
        var completed = 0
        var visited = childCount
        try await withThrowingTaskGroup(of: Measurement.self) { group in
            func enqueueOne() {
                guard nextIndex < directoryEntries.count else { return }
                let entry = directoryEntries[nextIndex]
                nextIndex += 1
                emit(.sizeCalculationStarted(path: entry.path))
                group.addTask {
                    try Task.checkCancellation()
                    return try measure(entry: entry, allowedDevice: allowedDevice)
                }
            }

            enqueueOne()
            enqueueOne()
            while let measurement = try await group.next() {
                try Task.checkCancellation()
                completed += 1
                visited += measurement.visitedCount
                emit(.sizeCalculationCompleted(measurement.entry))
                for issue in measurement.issues {
                    emit(.accessError(path: issue.0, message: issue.1))
                }
                emit(.progress(ExplorerProgress(
                    completedDirectoryCount: completed,
                    totalDirectoryCount: directoryEntries.count,
                    visitedItemCount: visited,
                    currentPath: measurement.entry.path
                )))
                enqueueOne()
            }
        }
        emit(.progress(ExplorerProgress(
            completedDirectoryCount: completed,
            totalDirectoryCount: directoryEntries.count,
            visitedItemCount: visited,
            currentPath: nil
        )))
        emit(.finished(scannedAt: Date()))
    }

    private func discoverChildren(
        at root: URL,
        keys: [URLResourceKey],
        allowedDevice: UInt64,
        emit: @escaping @Sendable (sending ExplorerScanEvent) -> Void
    ) throws -> (directories: [ExplorerEntry], childCount: Int) {
        var directoryEntries: [ExplorerEntry] = []
        var enumerationIssues: [(String, String)] = []
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: keys,
            options: [.skipsSubdirectoryDescendants],
            errorHandler: { url, error in
                enumerationIssues.append((url.path, error.localizedDescription))
                return true
            }
        ) else {
            throw CocoaError(.fileReadNoPermission)
        }
        var childCount = 0
        for case let child as URL in enumerator {
            try Task.checkCancellation()
            childCount += 1
            do {
                let entry = try initialEntry(at: child, allowedDevice: allowedDevice)
                emit(.childDiscovered(entry))
                if entry.kind == .directory || entry.kind == .package {
                    directoryEntries.append(entry)
                }
            } catch {
                let message = error.localizedDescription
                emit(.childDiscovered(ExplorerEntry(
                    path: child.path,
                    kind: .inaccessible,
                    allocatedSize: 0,
                    logicalSize: 0,
                    modifiedAt: nil,
                    isHidden: child.lastPathComponent.hasPrefix("."),
                    volumeIdentifier: String(allowedDevice),
                    calculationState: .failed,
                    errorMessage: message
                )))
                emit(.accessError(path: child.path, message: message))
            }
        }
        for issue in enumerationIssues {
            emit(.accessError(path: issue.0, message: issue.1))
        }
        return (directoryEntries, childCount)
    }

    private func initialEntry(at url: URL, allowedDevice: UInt64) throws -> ExplorerEntry {
        let values = try url.resourceValues(forKeys: [
            .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey,
            .isPackageKey, .isHiddenKey, .contentModificationDateKey
        ])
        let information = try fileStat(at: url)
        let kind: CandidateKind
        if values.isSymbolicLink == true || isSymbolicLink(information) {
            kind = .symbolicLink
        } else if values.isPackage == true {
            kind = .package
        } else if values.isDirectory == true || isDirectory(information) {
            kind = .directory
        } else {
            kind = .regularFile
        }
        let isFolder = kind == .directory || kind == .package
        let isOtherVolume = UInt64(information.st_dev) != allowedDevice
        let error = isOtherVolume && isFolder ? "선택한 볼륨 밖의 항목이라 크기를 계산하지 않았습니다." : nil
        return ExplorerEntry(
            path: url.standardizedFileURL.path,
            kind: kind,
            allocatedSize: isFolder ? 0 : allocatedBytes(information),
            logicalSize: isFolder ? 0 : max(0, Int64(information.st_size)),
            modifiedAt: values.contentModificationDate,
            isHidden: values.isHidden ?? url.lastPathComponent.hasPrefix("."),
            volumeIdentifier: String(UInt64(information.st_dev)),
            calculationState: isFolder ? (isOtherVolume ? .failed : .pending) : .complete,
            errorMessage: error
        )
    }

    private func measure(entry: ExplorerEntry, allowedDevice: UInt64) throws -> Measurement {
        if entry.volumeIdentifier != String(allowedDevice) {
            return Measurement(
                entry: replacing(entry, state: .failed, error: "선택한 볼륨 밖의 항목입니다."),
                issues: [(entry.path, "선택한 볼륨 밖의 항목이라 건너뛰었습니다.")],
                visitedCount: 0
            )
        }

        let root = URL(fileURLWithPath: entry.path, isDirectory: true)
        var logical: Int64 = 0
        var allocated: Int64 = 0
        var issues: [(String, String)] = []
        var visited = 0
        guard let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
            options: [],
            errorHandler: { url, error in
                issues.append((url.path, error.localizedDescription))
                return true
            }
        ) else {
            return Measurement(
                entry: replacing(entry, state: .failed, error: "폴더 내용을 열 수 없습니다."),
                issues: [(entry.path, "폴더 내용을 열 수 없습니다.")],
                visitedCount: 0
            )
        }

        do {
            for case let descendant as URL in enumerator {
                try Task.checkCancellation()
                visited += 1
                do {
                    let information = try fileStat(at: descendant)
                    if UInt64(information.st_dev) != allowedDevice {
                        enumerator.skipDescendants()
                        issues.append((descendant.path, "선택한 볼륨 밖의 항목이라 건너뛰었습니다."))
                        continue
                    }
                    if isSymbolicLink(information) {
                        enumerator.skipDescendants()
                    }
                    logical += max(0, Int64(information.st_size))
                    allocated += allocatedBytes(information)
                } catch {
                    issues.append((descendant.path, error.localizedDescription))
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        }

        let completed = ExplorerEntry(
            path: entry.path,
            kind: entry.kind,
            allocatedSize: allocated,
            logicalSize: logical,
            modifiedAt: entry.modifiedAt,
            isHidden: entry.isHidden,
            volumeIdentifier: entry.volumeIdentifier,
            calculationState: issues.isEmpty ? .complete : .complete,
            errorMessage: issues.isEmpty ? nil : "일부 항목에 접근할 수 없어 크기가 완전하지 않을 수 있습니다."
        )
        return Measurement(entry: completed, issues: issues, visitedCount: visited)
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

    private func fileStat(at url: URL) throws -> stat {
        var information = stat()
        guard lstat(url.path, &information) == 0 else {
            throw CocoaError(CocoaError.Code(rawValue: NSFileReadUnknownError))
        }
        return information
    }

    private func allocatedBytes(_ information: stat) -> Int64 {
        max(0, Int64(information.st_blocks) * 512)
    }

    private func isDirectory(_ information: stat) -> Bool {
        (information.st_mode & S_IFMT) == S_IFDIR
    }

    private func isSymbolicLink(_ information: stat) -> Bool {
        (information.st_mode & S_IFMT) == S_IFLNK
    }
}
