import Foundation
import SwiftData

@Model
final class CleanupReceiptRecord {
    @Attribute(.unique) var id: UUID
    var path: String
    var actionData: Data
    var sizeBefore: Int64
    var sizeAfter: Int64
    var estimatedBytes: Int64
    var availableCapacityChange: Int64?
    var succeeded: Bool
    var failureReason: String?
    var executedAt: Date

    init(receipt: CleanupReceipt) throws {
        id = receipt.id
        path = receipt.path
        actionData = try JSONEncoder().encode(receipt.action)
        sizeBefore = receipt.sizeBefore
        sizeAfter = receipt.sizeAfter
        estimatedBytes = receipt.estimatedBytes
        availableCapacityChange = receipt.availableCapacityChange
        succeeded = receipt.succeeded
        failureReason = receipt.failureReason
        executedAt = receipt.executedAt
    }

    var receipt: CleanupReceipt? {
        guard let action = try? JSONDecoder().decode(CleanupAction.self, from: actionData) else { return nil }
        return CleanupReceipt(
            id: id, path: path, action: action,
            sizeBefore: sizeBefore, sizeAfter: sizeAfter,
            estimatedBytes: estimatedBytes,
            availableCapacityChange: availableCapacityChange,
            succeeded: succeeded, failureReason: failureReason,
            executedAt: executedAt
        )
    }
}

@MainActor
final class CleanupReceiptStore {
    private let container: ModelContainer
    private let context: ModelContext

    init(inMemory: Bool = false) throws {
        let configuration = ModelConfiguration(isStoredInMemoryOnly: inMemory)
        container = try ModelContainer(for: CleanupReceiptRecord.self, configurations: configuration)
        context = container.mainContext
    }

    func append(_ receipt: CleanupReceipt) throws {
        context.insert(try CleanupReceiptRecord(receipt: receipt))
        try context.save()
    }

    func all() throws -> [CleanupReceipt] {
        var descriptor = FetchDescriptor<CleanupReceiptRecord>()
        descriptor.sortBy = [SortDescriptor(\.executedAt, order: .reverse)]
        return try context.fetch(descriptor).compactMap(\.receipt)
    }

    func exportData() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(all())
    }

    func deleteAll() throws {
        try context.delete(model: CleanupReceiptRecord.self)
        try context.save()
    }
}
