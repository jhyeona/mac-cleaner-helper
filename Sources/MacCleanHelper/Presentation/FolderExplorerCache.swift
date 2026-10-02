import Foundation

struct ExplorerFolderSnapshot: Codable, Hashable, Sendable {
    let folderPath: String
    let entries: [ExplorerEntry]
    let scannedAt: Date
    let folderModifiedAt: Date?
    let volumeIdentifier: String?
    let isComplete: Bool
    var lastAccessedAt: Date
}

struct ExplorerCachedFolder: Sendable {
    let snapshot: ExplorerFolderSnapshot
    let staleReason: String?
}

private struct ExplorerCacheEnvelope: Codable {
    var lastFolderPath: String?
    var snapshots: [ExplorerFolderSnapshot]
}

@MainActor
final class FolderExplorerCacheStore {
    static let directoryName = "folder-explorer-cache-v1"
    static let maximumFolderCount = 100

    private let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? fileManager.temporaryDirectory
            self.fileURL = base
                .appendingPathComponent(FolderBookmarkStore.appDomain, isDirectory: true)
                .appendingPathComponent(Self.directoryName, isDirectory: true)
                .appendingPathComponent("cache.json")
        }
    }

    var count: Int { loadEnvelope().snapshots.count }

    func load(path: String, touch: Bool = true) -> ExplorerCachedFolder? {
        let normalized = normalize(path)
        var envelope = loadEnvelope()
        guard let index = envelope.snapshots.firstIndex(where: { $0.folderPath == normalized }) else {
            return nil
        }
        if touch {
            envelope.snapshots[index].lastAccessedAt = Date()
            envelope.lastFolderPath = normalized
            try? saveEnvelope(envelope)
        }
        return ExplorerCachedFolder(
            snapshot: envelope.snapshots[index],
            staleReason: staleReason(for: envelope.snapshots[index])
        )
    }

    func loadLastAvailable() -> ExplorerCachedFolder? {
        let envelope = loadEnvelope()
        guard let path = envelope.lastFolderPath,
              fileManager.fileExists(atPath: path) else { return nil }
        return load(path: path)
    }

    func save(
        folder: URL,
        entries: [ExplorerEntry],
        scannedAt: Date,
        isComplete: Bool
    ) throws {
        let path = normalize(folder.path)
        var envelope = loadEnvelope()
        envelope.snapshots.removeAll { $0.folderPath == path }
        envelope.snapshots.append(ExplorerFolderSnapshot(
            folderPath: path,
            entries: entries,
            scannedAt: scannedAt,
            folderModifiedAt: modificationDate(at: folder),
            volumeIdentifier: volumeIdentifier(at: folder),
            isComplete: isComplete,
            lastAccessedAt: Date()
        ))
        envelope.snapshots.sort { $0.lastAccessedAt > $1.lastAccessedAt }
        if envelope.snapshots.count > Self.maximumFolderCount {
            envelope.snapshots.removeLast(envelope.snapshots.count - Self.maximumFolderCount)
        }
        envelope.lastFolderPath = path
        try saveEnvelope(envelope)
    }

    func invalidate(targetPaths: [String]) {
        let targets = targetPaths.map(normalize)
        var envelope = loadEnvelope()
        envelope.snapshots.removeAll { snapshot in
            targets.contains { target in
                snapshot.folderPath == "/" || target == snapshot.folderPath || target.hasPrefix(snapshot.folderPath + "/")
            }
        }
        if let last = envelope.lastFolderPath,
           !envelope.snapshots.contains(where: { $0.folderPath == last }) {
            envelope.lastFolderPath = nil
        }
        try? saveEnvelope(envelope)
    }

    func clear() throws {
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try fileManager.removeItem(at: fileURL.deletingLastPathComponent())
    }

    private func staleReason(for snapshot: ExplorerFolderSnapshot) -> String? {
        guard fileManager.fileExists(atPath: snapshot.folderPath) else {
            return "폴더가 없거나 볼륨 연결이 해제되어 저장된 결과만 표시합니다."
        }
        let url = URL(fileURLWithPath: snapshot.folderPath, isDirectory: true)
        if snapshot.volumeIdentifier != volumeIdentifier(at: url) {
            return "볼륨이 바뀌어 저장된 결과가 오래되었을 수 있습니다."
        }
        let savedModificationSecond = snapshot.folderModifiedAt.map { Int64($0.timeIntervalSince1970) }
        let currentModificationSecond = modificationDate(at: url).map { Int64($0.timeIntervalSince1970) }
        if savedModificationSecond != currentModificationSecond {
            return "폴더가 변경되어 저장된 결과가 오래되었을 수 있습니다."
        }
        if !snapshot.isComplete {
            return "이전 계산이 끝나기 전에 중단된 결과입니다."
        }
        return nil
    }

    private func loadEnvelope() -> ExplorerCacheEnvelope {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: fileURL),
              let envelope = try? decoder.decode(ExplorerCacheEnvelope.self, from: data) else {
            return ExplorerCacheEnvelope(lastFolderPath: nil, snapshots: [])
        }
        return envelope
    }

    private func saveEnvelope(_ envelope: ExplorerCacheEnvelope) throws {
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(envelope)
        try data.write(to: fileURL, options: .atomic)
    }

    private func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    private func modificationDate(at url: URL) -> Date? {
        (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
    }

    private func volumeIdentifier(at url: URL) -> String? {
        guard let attributes = try? fileManager.attributesOfFileSystem(forPath: url.path),
              let number = attributes[.systemNumber] as? NSNumber else { return nil }
        return number.stringValue
    }
}
