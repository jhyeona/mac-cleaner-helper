import Foundation

struct RegisteredFolder: Identifiable, Hashable {
    let url: URL
    let bookmarkData: Data?
    let isStale: Bool

    var id: String { url.standardizedFileURL.path }
}

struct RegisteredFolderRecord: Codable, Hashable {
    let path: String
    let bookmarkData: Data?
}

@MainActor
final class FolderBookmarkStore: ObservableObject {
    static let appDomain = "io.biu.mac-clean-helper"
    static let storageKey = "Biu.registeredFolders.v2"
    static let legacyStorageKey = "Biu.registeredFolderBookmarks.v1"
    static let selectionKey = "Biu.selectedRegisteredFolderPaths.v1"

    @Published private(set) var folders: [RegisteredFolder] = []
    @Published private(set) var selectedFolderPaths: Set<String> = []

    private let defaults: UserDefaults

    init(defaults: UserDefaults? = nil) {
        self.defaults = defaults
            ?? UserDefaults(suiteName: Self.appDomain)
            ?? .standard
        migrateLegacyBookmarksIfNeeded()
        reload()
        restoreSelection()
    }

    var selectedFolders: [RegisteredFolder] {
        folders.filter { selectedFolderPaths.contains($0.url.standardizedFileURL.path) }
    }

    func isSelected(_ folder: RegisteredFolder) -> Bool {
        selectedFolderPaths.contains(folder.url.standardizedFileURL.path)
    }

    func setSelected(_ selected: Bool, for folder: RegisteredFolder) {
        let path = folder.url.standardizedFileURL.path
        if selected {
            selectedFolderPaths.insert(path)
        } else {
            selectedFolderPaths.remove(path)
        }
        persistSelection()
    }

    func add(_ url: URL) throws {
        let normalizedURL = url.standardizedFileURL
        var records = storedRecords()
        let bookmarkData = try? normalizedURL.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let newRecord = RegisteredFolderRecord(
            path: normalizedURL.path,
            bookmarkData: bookmarkData
        )

        if let index = records.firstIndex(where: { normalizedPath($0.path) == normalizedURL.path }) {
            records[index] = newRecord
        } else {
            records.append(newRecord)
        }
        try save(records)
        reload()
        selectedFolderPaths.insert(normalizedURL.path)
        persistSelection()
    }

    func remove(_ folder: RegisteredFolder) {
        selectedFolderPaths.remove(folder.url.standardizedFileURL.path)
        persistSelection()
        let retained = storedRecords().filter {
            normalizedPath($0.path) != folder.url.standardizedFileURL.path
        }
        try? save(retained)
        reload()
    }

    /// 반환된 토큰이 살아 있는 동안 보안 범위 접근 권한을 유지한다.
    /// 직접 배포 빌드는 경로 접근이 가능하므로 북마크가 없는 폴더도 안전하게 처리한다.
    func beginAccessing(_ folder: RegisteredFolder) -> SecurityScopedAccess {
        SecurityScopedAccess(url: folder.url)
    }

    private func reload() {
        folders = storedRecords().compactMap { record in
            if let bookmarkData = record.bookmarkData,
               let resolved = resolve(bookmarkData) {
                return RegisteredFolder(
                    url: resolved.url,
                    bookmarkData: bookmarkData,
                    isStale: resolved.isStale || !pathExists(resolved.url.path)
                )
            }

            guard !record.path.isEmpty else { return nil }
            let fallbackURL = URL(fileURLWithPath: record.path, isDirectory: true).standardizedFileURL
            return RegisteredFolder(
                url: fallbackURL,
                bookmarkData: record.bookmarkData,
                isStale: !pathExists(fallbackURL.path)
            )
        }
        .uniqued(by: { $0.url.standardizedFileURL.path })
        .sorted {
            $0.url.lastPathComponent.localizedStandardCompare($1.url.lastPathComponent) == .orderedAscending
        }
    }

    private func migrateLegacyBookmarksIfNeeded() {
        guard defaults.data(forKey: Self.storageKey) == nil,
              let legacyBookmarks = defaults.array(forKey: Self.legacyStorageKey) as? [Data],
              !legacyBookmarks.isEmpty else { return }

        let records = legacyBookmarks.compactMap { bookmarkData -> RegisteredFolderRecord? in
            guard let resolved = resolve(bookmarkData) else { return nil }
            return RegisteredFolderRecord(
                path: resolved.url.standardizedFileURL.path,
                bookmarkData: bookmarkData
            )
        }
        guard !records.isEmpty else { return }
        try? save(records)
    }

    private func resolve(_ data: Data) -> (url: URL, isStale: Bool)? {
        let resolutionOptions: [URL.BookmarkResolutionOptions] = [
            .withSecurityScope,
            [.withoutUI, .withoutMounting],
            []
        ]
        for options in resolutionOptions {
            var stale = false
            if let url = try? URL(
                resolvingBookmarkData: data,
                options: options,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                return (url.standardizedFileURL, stale)
            }
        }
        return nil
    }

    private func storedRecords() -> [RegisteredFolderRecord] {
        guard let data = defaults.data(forKey: Self.storageKey) else { return [] }
        return (try? JSONDecoder().decode([RegisteredFolderRecord].self, from: data)) ?? []
    }

    private func save(_ records: [RegisteredFolderRecord]) throws {
        let data = try JSONEncoder().encode(records)
        defaults.set(data, forKey: Self.storageKey)
    }

    private func restoreSelection() {
        let availablePaths = Set(folders.map { $0.url.standardizedFileURL.path })
        if defaults.object(forKey: Self.selectionKey) == nil {
            selectedFolderPaths = availablePaths
        } else {
            let stored = Set(defaults.stringArray(forKey: Self.selectionKey) ?? [])
            selectedFolderPaths = stored.intersection(availablePaths)
        }
        persistSelection()
    }

    private func persistSelection() {
        defaults.set(selectedFolderPaths.sorted(), forKey: Self.selectionKey)
    }

    private func normalizedPath(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }

    private func pathExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
}

final class SecurityScopedAccess {
    private let url: URL
    private let didStart: Bool

    init(url: URL) {
        self.url = url
        didStart = url.startAccessingSecurityScopedResource()
    }

    deinit {
        if didStart { url.stopAccessingSecurityScopedResource() }
    }
}

private extension Array {
    func uniqued<Key: Hashable>(by key: (Element) -> Key) -> [Element] {
        var seen: Set<Key> = []
        return filter { seen.insert(key($0)).inserted }
    }
}
