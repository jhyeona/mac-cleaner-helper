import AppKit
import Darwin
import Foundation

struct FileIdentity: Hashable, Sendable {
    let device: UInt64
    let inode: UInt64
}

struct CleanupPreparation: Hashable, Sendable {
    let item: CleanupItem
    let action: CleanupAction
    let identity: FileIdentity?
    let commandPreview: String?
    let blockingApplications: [String]
}

enum CleanupEngineError: LocalizedError, Equatable {
    case targetMissing
    case invalidPath
    case symbolicLink
    case protectedTarget
    case targetChanged
    case unverifiedImmediateDeletion
    case applicationRunning([String])
    case applicationRemovalBlocked(String)
    case commandNotAllowed
    case executableNotInstalled(String)
    case commandFailed(Int32, String)

    var errorDescription: String? {
        switch self {
        case .targetMissing: "대상이 더 이상 존재하지 않습니다."
        case .invalidPath: "정리할 경로가 올바르지 않습니다."
        case .symbolicLink: "심볼릭 링크는 안전하게 정리할 수 없습니다."
        case .protectedTarget: "보호 영역은 정리할 수 없습니다."
        case .targetChanged: "분석 후 대상이 바뀌어 작업을 중단했습니다. 다시 분석하세요."
        case .unverifiedImmediateDeletion: "검증된 재생성 캐시에만 즉시 삭제를 사용할 수 있습니다."
        case .applicationRunning(let apps): "관련 앱을 종료한 뒤 다시 시도하세요: \(apps.joined(separator: ", "))"
        case .applicationRemovalBlocked(let reason): reason
        case .commandNotAllowed: "허용 목록에 없는 명령 또는 인수입니다."
        case .executableNotInstalled(let name): "\(name) 실행 파일을 찾을 수 없습니다."
        case .commandFailed(let status, let output): "명령이 종료 코드 \(status)로 실패했습니다. \(output)"
        }
    }
}

struct OfficialCommandPolicy: Sendable {
    func validate(tool: OfficialTool, arguments: [String]) -> Bool {
        switch (tool, arguments) {
        case (.xcrun, ["simctl", "delete", "unavailable"]),
             (.docker, ["system", "prune", "--force"]),
             (.podman, ["system", "prune", "--force"]),
             (.brew, ["cleanup"]):
            true
        default:
            false
        }
    }

    func executableURL(for tool: OfficialTool) -> URL? {
        let candidates: [String]
        switch tool {
        case .xcrun:
            candidates = ["/usr/bin/xcrun"]
        case .docker:
            candidates = [
                "/usr/local/bin/docker", "/opt/homebrew/bin/docker",
                "/Applications/Docker.app/Contents/Resources/bin/docker"
            ]
        case .podman:
            candidates = ["/usr/local/bin/podman", "/opt/homebrew/bin/podman"]
        case .brew:
            candidates = ["/usr/local/bin/brew", "/opt/homebrew/bin/brew"]
        }
        return candidates.first(where: FileManager.default.isExecutableFile(atPath:)).map(URL.init(fileURLWithPath:))
    }

    func preview(tool: OfficialTool, arguments: [String], executableURL: URL? = nil) throws -> String {
        guard validate(tool: tool, arguments: arguments) else { throw CleanupEngineError.commandNotAllowed }
        let quoted = arguments.map { argument in
            argument.contains(" ") ? "\"\(argument)\"" : argument
        }
        return ([executableURL?.path ?? tool.rawValue] + quoted).joined(separator: " ")
    }
}

actor CleanupEngine {
    private let fileManager: FileManager
    private let classifier = SafetyClassifier()
    private let commandPolicy = OfficialCommandPolicy()
    private let runningApplicationProvider: @Sendable () -> [RunningApplication]

    init(fileManager: FileManager = .default,
         runningApplicationProvider: @escaping @Sendable () -> [RunningApplication] = { RunningApplication.current() }) {
        self.fileManager = fileManager
        self.runningApplicationProvider = runningApplicationProvider
    }

    func prepare(item: CleanupItem, action requestedAction: CleanupAction? = nil) throws -> CleanupPreparation {
        let action = requestedAction ?? item.recommendedAction
        let commandPreview: String?
        let identity: FileIdentity?

        if case .officialCommand(let tool, let arguments) = action {
            guard let executableURL = commandPolicy.executableURL(for: tool) else {
                throw CleanupEngineError.executableNotInstalled(tool.rawValue)
            }
            commandPreview = try commandPolicy.preview(
                tool: tool,
                arguments: arguments,
                executableURL: executableURL
            )
            identity = nil
        } else if case .manualInstructions = action {
            commandPreview = nil
            identity = nil
        } else {
            commandPreview = nil
            identity = try validateTarget(item: item, action: action)
        }

        let blockers: [String]
        switch action {
        case .moveToTrash, .deleteRegeneratableCache:
            blockers = blockingApplications(for: item)
        case .officialCommand, .manualInstructions:
            blockers = []
        }
        return CleanupPreparation(
            item: item,
            action: action,
            identity: identity,
            commandPreview: commandPreview,
            blockingApplications: blockers
        )
    }

    func execute(_ preparation: CleanupPreparation) -> CleanupReceipt {
        let beforeCapacity = availableCapacity(for: preparation.item.path)
        let beforeSize = preparation.item.candidate.allocatedSize

        do {
            if !preparation.blockingApplications.isEmpty {
                throw CleanupEngineError.applicationRunning(preparation.blockingApplications)
            }

            switch preparation.action {
            case .moveToTrash:
                try ensureApplicationsStopped(for: preparation.item)
                let current = try validateTarget(item: preparation.item, action: .moveToTrash)
                guard current == preparation.identity else { throw CleanupEngineError.targetChanged }
                try fileManager.trashItem(at: URL(fileURLWithPath: preparation.item.path), resultingItemURL: nil)

            case .deleteRegeneratableCache:
                try ensureApplicationsStopped(for: preparation.item)
                let current = try validateTarget(item: preparation.item, action: .deleteRegeneratableCache)
                guard current == preparation.identity else { throw CleanupEngineError.targetChanged }
                try fileManager.removeItem(at: URL(fileURLWithPath: preparation.item.path))

            case .officialCommand(let tool, let arguments):
                try executeOfficialCommand(tool: tool, arguments: arguments)

            case .manualInstructions:
                throw CleanupEngineError.commandNotAllowed
            }

            let afterCapacity = availableCapacity(for: preparation.item.path)
            let afterSize = allocatedSizeIfPresent(at: preparation.item.path)
            return receipt(
                preparation, beforeSize: beforeSize, afterSize: afterSize,
                beforeCapacity: beforeCapacity, afterCapacity: afterCapacity,
                succeeded: true, error: nil
            )
        } catch {
            let afterCapacity = availableCapacity(for: preparation.item.path)
            let afterSize = allocatedSizeIfPresent(at: preparation.item.path)
            return receipt(
                preparation, beforeSize: beforeSize, afterSize: afterSize,
                beforeCapacity: beforeCapacity, afterCapacity: afterCapacity,
                succeeded: false, error: error.localizedDescription
            )
        }
    }

    private func validateTarget(item: CleanupItem, action: CleanupAction) throws -> FileIdentity {
        let rawPath = item.path
        guard rawPath.hasPrefix("/"), rawPath != "/" else { throw CleanupEngineError.invalidPath }
        let standardized = (rawPath as NSString).standardizingPath
        guard standardized == rawPath || standardized == URL(fileURLWithPath: rawPath).standardized.path else {
            throw CleanupEngineError.invalidPath
        }
        guard fileManager.fileExists(atPath: standardized) else { throw CleanupEngineError.targetMissing }

        let values = try URL(fileURLWithPath: standardized).resourceValues(forKeys: [.isSymbolicLinkKey])
        guard values.isSymbolicLink != true else { throw CleanupEngineError.symbolicLink }
        guard !classifier.isProtected(path: standardized), item.assessment.risk != .avoid else {
            throw CleanupEngineError.protectedTarget
        }
        let url = URL(fileURLWithPath: standardized)
        guard !classifier.isProtected(path: url.resolvingSymlinksInPath().path) else {
            throw CleanupEngineError.protectedTarget
        }
        if ApplicationRemovalPolicy.isApplication(url) {
            guard action == .moveToTrash else { throw CleanupEngineError.unverifiedImmediateDeletion }
            if let reason = ApplicationRemovalPolicy.blockedReason(at: url) {
                throw CleanupEngineError.applicationRemovalBlocked(reason)
            }
        }

        if action == .deleteRegeneratableCache {
            let allowedCategories: Set<CleanupCategory> = [.cache, .buildArtifact, .developer]
            guard item.assessment.risk == .safe,
                  item.candidate.source.isRuleVerified,
                  allowedCategories.contains(item.category) else {
                throw CleanupEngineError.unverifiedImmediateDeletion
            }
        }
        return try fileIdentity(at: standardized)
    }

    private func fileIdentity(at path: String) throws -> FileIdentity {
        var information = stat()
        guard lstat(path, &information) == 0 else { throw CleanupEngineError.targetMissing }
        return FileIdentity(device: UInt64(information.st_dev), inode: UInt64(information.st_ino))
    }

    private func executeOfficialCommand(tool: OfficialTool, arguments: [String]) throws {
        guard commandPolicy.validate(tool: tool, arguments: arguments) else {
            throw CleanupEngineError.commandNotAllowed
        }
        guard let executable = commandPolicy.executableURL(for: tool) else {
            throw CleanupEngineError.executableNotInstalled(tool.rawValue)
        }

        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let message = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            throw CleanupEngineError.commandFailed(process.terminationStatus, message)
        }
    }

    private func ensureApplicationsStopped(for item: CleanupItem) throws {
        let blockers = blockingApplications(for: item)
        guard blockers.isEmpty else { throw CleanupEngineError.applicationRunning(blockers) }
    }

    private func blockingApplications(for item: CleanupItem) -> [String] {
        let running = runningApplicationProvider()
        return Array(Set(ApplicationRemovalPolicy.blockers(for: item.path, running: running)
            + runningApplications(for: item.candidate.tool, running: running))).sorted()
    }

    private func runningApplications(for tool: String, running: [RunningApplication]) -> [String] {
        let applications: [(bundleIdentifier: String, displayName: String)]
        switch tool.lowercased() {
        case let name where name.contains("xcode") || name.contains("simulator"):
            applications = [("com.apple.dt.Xcode", "Xcode"), ("com.apple.iphonesimulator", "Simulator")]
        case let name where name.contains("docker"):
            applications = [("com.docker.docker", "Docker Desktop")]
        case let name where name.contains("jetbrains"):
            applications = [("com.jetbrains.intellij", "IntelliJ IDEA"), ("com.jetbrains.AppCode", "AppCode")]
        case let name where name.contains("code"):
            applications = [("com.microsoft.VSCode", "Visual Studio Code")]
        case let name where name.contains("cursor"):
            applications = [("com.todesktop.230313mzl4w4u92", "Cursor")]
        default:
            applications = []
        }
        let identifiers = Set(running.compactMap(\.bundleIdentifier))
        return applications.compactMap { identifiers.contains($0.bundleIdentifier) ? $0.displayName : nil }
    }

    private func availableCapacity(for path: String) -> Int64? {
        let url = URL(fileURLWithPath: path).deletingLastPathComponent()
        let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private func allocatedSizeIfPresent(at path: String) -> Int64 {
        guard fileManager.fileExists(atPath: path),
              let values = try? URL(fileURLWithPath: path).resourceValues(forKeys: [
                .totalFileAllocatedSizeKey, .fileAllocatedSizeKey
              ]) else { return 0 }
        return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
    }

    private func receipt(
        _ preparation: CleanupPreparation,
        beforeSize: Int64,
        afterSize: Int64,
        beforeCapacity: Int64?,
        afterCapacity: Int64?,
        succeeded: Bool,
        error: String?
    ) -> CleanupReceipt {
        CleanupReceipt(
            path: preparation.item.path,
            action: preparation.action,
            sizeBefore: beforeSize,
            sizeAfter: afterSize,
            estimatedBytes: preparation.item.candidate.allocatedSize,
            availableCapacityChange: beforeCapacity.flatMap { before in afterCapacity.map { $0 - before } },
            succeeded: succeeded,
            failureReason: error
        )
    }
}
