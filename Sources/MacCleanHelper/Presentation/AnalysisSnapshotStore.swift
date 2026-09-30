import Foundation

struct AnalysisSnapshot: Codable, Equatable, Sendable {
    static let currentSchemaVersion = 1

    let schemaVersion: Int
    let savedAt: Date
    let scannedFolderPaths: [String]
    let items: [CleanupItem]
    let issues: [ScanIssue]

    init(
        savedAt: Date = Date(),
        scannedFolderPaths: [String],
        items: [CleanupItem],
        issues: [ScanIssue]
    ) {
        schemaVersion = Self.currentSchemaVersion
        self.savedAt = savedAt
        self.scannedFolderPaths = scannedFolderPaths
        self.items = items
        self.issues = issues
    }
}

struct AnalysisSnapshotStore: Sendable {
    let fileURL: URL

    init(baseDirectory: URL? = nil) throws {
        let root: URL
        if let baseDirectory {
            root = baseDirectory
        } else {
            root = try FileManager.default.url(
                for: .applicationSupportDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            .appendingPathComponent("Biu", isDirectory: true)
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        fileURL = root.appendingPathComponent("analysis-snapshot-v1.json", isDirectory: false)
    }

    func load() throws -> AnalysisSnapshot? {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
        let data = try Data(contentsOf: fileURL)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let snapshot = try decoder.decode(AnalysisSnapshot.self, from: data)
        guard snapshot.schemaVersion == AnalysisSnapshot.currentSchemaVersion else { return nil }
        return snapshot
    }

    func save(_ snapshot: AnalysisSnapshot) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
    }

    func delete() throws {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }
}
