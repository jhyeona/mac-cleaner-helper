import Foundation

/// 화면에는 오해하기 쉬운 "안전" 대신 재생성 가능 여부를 명확히 표시한다.
enum CleanupRisk: String, CaseIterable, Codable, Sendable {
    case safe
    case review
    case avoid

    var title: String {
        switch self {
        case .safe: "재생성 가능"
        case .review: "확인 필요"
        case .avoid: "보호 대상"
        }
    }

    var symbol: String {
        switch self {
        case .safe: "arrow.triangle.2.circlepath.circle.fill"
        case .review: "exclamationmark.triangle.fill"
        case .avoid: "hand.raised.fill"
        }
    }
}

enum CleanupCategory: String, CaseIterable, Codable, Sendable {
    case cache, buildArtifact, downloads, developer, simulator, container
    case archive, virtualMachine, application, personal, system, other

    var title: String {
        switch self {
        case .cache: "캐시"
        case .buildArtifact: "빌드 결과"
        case .downloads: "다운로드"
        case .developer: "개발 도구"
        case .simulator: "시뮬레이터"
        case .container: "컨테이너"
        case .archive: "아카이브"
        case .virtualMachine: "가상 머신"
        case .application: "앱 데이터"
        case .personal: "개인 원본"
        case .system: "시스템"
        case .other: "기타"
        }
    }

    var symbol: String {
        switch self {
        case .cache: "bolt.horizontal.circle"
        case .buildArtifact: "shippingbox.circle"
        case .downloads: "arrow.down.circle"
        case .developer: "hammer.circle"
        case .simulator: "iphone.gen3.circle"
        case .container: "shippingbox"
        case .archive: "archivebox.circle"
        case .virtualMachine: "desktopcomputer"
        case .application: "app.badge"
        case .personal: "person.crop.circle"
        case .system: "gearshape.2"
        case .other: "doc.circle"
        }
    }
}

enum CandidateKind: String, Codable, Sendable {
    case regularFile, directory, symbolicLink, package, inaccessible
}

enum DetectionSource: Hashable, Codable, Sendable {
    case detectorPack(String)
    case userRule(String)
    case folderScan

    var isRuleVerified: Bool {
        if case .detectorPack = self { return true }
        return false
    }
}

struct CleanupCandidate: Identifiable, Hashable, Codable, Sendable {
    let path: String
    let logicalSize: Int64
    let allocatedSize: Int64
    let tool: String
    let category: CleanupCategory
    let modifiedAt: Date?
    let detectionReason: String
    let source: DetectionSource
    let kind: CandidateKind

    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: allocatedSize, countStyle: .file)
    }
    var formattedLogicalSize: String {
        ByteCountFormatter.string(fromByteCount: logicalSize, countStyle: .file)
    }
}

enum RecoveryKind: String, Codable, Sendable {
    case trash, regenerated, backupOnly, unavailable

    var title: String {
        switch self {
        case .trash: "휴지통에서 복구 가능"
        case .regenerated: "도구가 다시 생성"
        case .backupOnly: "백업에서만 복구 가능"
        case .unavailable: "복구 불가"
        }
    }
}

struct SafetyAssessment: Hashable, Codable, Sendable {
    let risk: CleanupRisk
    let reason: String
    let impact: String
    let recovery: RecoveryKind
    let canAutoSelect: Bool

    init(
        risk: CleanupRisk,
        reason: String,
        impact: String,
        recovery: RecoveryKind = .trash,
        canAutoSelect: Bool? = nil
    ) {
        self.risk = risk
        self.reason = reason
        self.impact = impact
        self.recovery = recovery
        self.canAutoSelect = canAutoSelect ?? (risk == .safe)
    }
}

enum OfficialTool: String, Hashable, Codable, Sendable {
    case xcrun, docker, podman, brew
}

enum CleanupAction: Hashable, Codable, Sendable {
    case moveToTrash
    case deleteRegeneratableCache
    case officialCommand(tool: OfficialTool, arguments: [String])
    case manualInstructions(String)

    var title: String {
        switch self {
        case .moveToTrash: "휴지통으로 이동"
        case .deleteRegeneratableCache: "캐시 즉시 삭제"
        case .officialCommand(let tool, _): "\(tool.rawValue) 공식 명령 실행"
        case .manualInstructions: "직접 확인"
        }
    }
}

struct CleanupItem: Identifiable, Hashable, Codable, Sendable {
    let candidate: CleanupCandidate
    let assessment: SafetyAssessment
    let recommendedAction: CleanupAction

    var id: String { candidate.id }
    var path: String { candidate.path }
    var size: Int64 { candidate.allocatedSize }
    var category: CleanupCategory { candidate.category }
    var name: String { candidate.name }
    var formattedSize: String { candidate.formattedSize }

    init(candidate: CleanupCandidate, assessment: SafetyAssessment, recommendedAction: CleanupAction) {
        self.candidate = candidate
        self.assessment = assessment
        self.recommendedAction = recommendedAction
    }

    init(path: String, size: Int64, category: CleanupCategory, assessment: SafetyAssessment) {
        self.init(
            candidate: CleanupCandidate(
                path: path, logicalSize: size, allocatedSize: size,
                tool: "파일 시스템", category: category, modifiedAt: nil,
                detectionReason: "선택한 폴더에서 발견됨", source: .folderScan,
                kind: .directory
            ),
            assessment: assessment,
            recommendedAction: assessment.risk == .avoid
                ? .manualInstructions("Finder에서 직접 확인하세요.")
                : .moveToTrash
        )
    }
}

struct CleanupReceipt: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    let path: String
    let action: CleanupAction
    let sizeBefore: Int64
    let sizeAfter: Int64
    let estimatedBytes: Int64
    let availableCapacityChange: Int64?
    let succeeded: Bool
    let failureReason: String?
    let executedAt: Date

    init(
        id: UUID = UUID(), path: String, action: CleanupAction,
        sizeBefore: Int64, sizeAfter: Int64, estimatedBytes: Int64,
        availableCapacityChange: Int64?, succeeded: Bool,
        failureReason: String?, executedAt: Date = Date()
    ) {
        self.id = id
        self.path = path
        self.action = action
        self.sizeBefore = sizeBefore
        self.sizeAfter = sizeAfter
        self.estimatedBytes = estimatedBytes
        self.availableCapacityChange = availableCapacityChange
        self.succeeded = succeeded
        self.failureReason = failureReason
        self.executedAt = executedAt
    }
}

extension CleanupCategory {
    static func infer(from path: String) -> CleanupCategory {
        let lowercased = path.lowercased()
        if lowercased.contains("/library/caches/") || lowercased.hasSuffix("/library/caches") { return .cache }
        if lowercased.contains("/downloads/") || lowercased.hasSuffix("/downloads") { return .downloads }
        if lowercased.contains("/library/developer/") || lowercased.contains("/.gradle/") { return .developer }
        if lowercased.contains(".photoslibrary") { return .personal }
        if [".zip", ".tar", ".dmg"].contains(where: lowercased.hasSuffix) { return .archive }
        if path.contains("/Applications/") || path.contains("/Library/Application Support/") { return .application }
        if path == "/System" || path.hasPrefix("/System/") || path.hasPrefix("/Library/") { return .system }
        return .other
    }
}
