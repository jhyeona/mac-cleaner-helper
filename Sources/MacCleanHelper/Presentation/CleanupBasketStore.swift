import Foundation

/// Remembers selections, never a prepared or authorized cleanup operation.
struct CleanupBasketStore: Sendable {
    private struct Snapshot: Codable {
        let version: Int
        let items: [CleanupItem]
    }

    let fileURL: URL

    init(baseDirectory: URL? = nil) throws {
        let root: URL
        if let baseDirectory {
            root = baseDirectory
        } else {
            root = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                               appropriateFor: nil, create: true)
                .appendingPathComponent("Biu", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fileURL = root.appendingPathComponent("cleanup-basket-v1.json")
    }

    func load() throws -> [CleanupItem] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: fileURL))
        guard snapshot.version == 1 else {
            throw CocoaError(.coderReadCorrupt)
        }
        return snapshot.items
    }

    func save(_ items: [CleanupItem]) throws {
        let data = try JSONEncoder().encode(Snapshot(version: 1, items: items))
        try data.write(to: fileURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
    }
}
