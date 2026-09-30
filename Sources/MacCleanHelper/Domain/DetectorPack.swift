import Foundation

enum DetectorPathMatch: Hashable, Sendable {
    case homeRelative(String)
    case component(String)
    case suffix(String)

    func matches(path: String, home: String) -> Bool {
        let standardized = (path as NSString).standardizingPath
        switch self {
        case .homeRelative(let relative):
            return standardized == URL(fileURLWithPath: home).appendingPathComponent(relative).standardized.path
        case .component(let component):
            return standardized.split(separator: "/").contains(Substring(component))
        case .suffix(let suffix):
            return standardized == suffix || standardized.hasSuffix("/" + suffix)
        }
    }
}

struct DetectorRule: Hashable, Sendable {
    let id: String
    let match: DetectorPathMatch
    let tool: String
    let category: CleanupCategory
    let reason: String
    let impact: String
    let risk: CleanupRisk
    let recovery: RecoveryKind
    let action: CleanupAction
}

protocol DetectorPack: Sendable {
    var id: String { get }
    var title: String { get }
    var rules: [DetectorRule] { get }
}

struct StandardDetectorPack: DetectorPack, Sendable {
    let id: String
    let title: String
    let rules: [DetectorRule]
}

struct UserPathRule: Hashable, Codable, Sendable {
    let id: UUID
    let pathPattern: String
    let explanation: String
    let category: CleanupCategory

    init(id: UUID = UUID(), pathPattern: String, explanation: String, category: CleanupCategory) throws {
        let trimmed = pathPattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains("\0") else {
            throw UserRuleError.invalidPath
        }
        self.id = id
        self.pathPattern = trimmed
        self.explanation = explanation
        self.category = category
    }

    enum UserRuleError: LocalizedError {
        case invalidPath
        var errorDescription: String? { "경로 패턴을 입력하세요." }
    }
}

struct DetectorRegistry: Sendable {
    let packs: [StandardDetectorPack]

    init(packs: [StandardDetectorPack] = Self.builtInPacks) {
        self.packs = packs
    }

    func item(for entry: ScannedEntry) -> CleanupItem {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let matches = packs.flatMap(\.rules).filter { $0.match.matches(path: entry.path, home: home) }
        let rule = matches.first
        let source: DetectionSource = rule.map { .detectorPack($0.id) } ?? .folderScan
        let category = rule?.category ?? CleanupCategory.infer(from: entry.path)
        let candidate = CleanupCandidate(
            path: entry.path,
            logicalSize: entry.logicalSize,
            allocatedSize: entry.allocatedSize,
            tool: rule?.tool ?? "파일 시스템",
            category: category,
            modifiedAt: entry.modifiedAt,
            detectionReason: rule?.reason ?? "선택한 폴더의 최상위 항목입니다.",
            source: source,
            kind: entry.kind
        )
        let assessment = SafetyClassifier().classify(candidate: candidate, detectorRule: rule)
        let action = rule?.action ?? (assessment.risk == .avoid
            ? .manualInstructions("보호 대상은 해당 앱이나 Finder에서 직접 확인하세요.")
            : .moveToTrash)
        return CleanupItem(candidate: candidate, assessment: assessment, recommendedAction: action)
    }

    /// 등록 없이도 제안할 수 있는 표준 개발 도구 영역. 존재하는 경로만 반환한다.
    func recommendedLocations() -> [(title: String, url: URL)] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var seen = Set<String>()
        return packs.flatMap(\.rules).compactMap { rule in
            guard case .homeRelative(let relative) = rule.match else { return nil }
            let url = URL(fileURLWithPath: home).appendingPathComponent(relative).standardized
            guard FileManager.default.fileExists(atPath: url.path), seen.insert(url.path).inserted else { return nil }
            return (rule.tool, url)
        }
    }
}

extension DetectorRegistry {
    static let builtInPacks: [StandardDetectorPack] = [
        StandardDetectorPack(id: "apple", title: "Apple 개발", rules: [
            cache("xcode-derived-data", .homeRelative("Library/Developer/Xcode/DerivedData"), "Xcode", .buildArtifact, "Xcode 빌드 중간 결과입니다.", "다음 빌드가 느려지지만 소스 코드는 유지됩니다."),
            review("xcode-archives", .homeRelative("Library/Developer/Xcode/Archives"), "Xcode", .archive, "배포·디버깅에 쓰인 앱 아카이브입니다.", "dSYM과 이전 배포본을 잃을 수 있어 Organizer에서 확인해야 합니다."),
            review("xcode-device-support", .homeRelative("Library/Developer/Xcode/iOS DeviceSupport"), "Xcode", .developer, "연결했던 iOS 버전의 디버깅 지원 파일입니다.", "해당 기기를 다시 연결하면 일부 파일을 다시 준비할 수 있습니다."),
            review("core-simulator", .homeRelative("Library/Developer/CoreSimulator"), "Simulator", .simulator, "시뮬레이터 런타임과 기기 데이터가 포함됩니다.", "앱 데이터가 사라질 수 있으므로 Simulator 공식 도구로 관리하세요.", .officialCommand(tool: .xcrun, arguments: ["simctl", "delete", "unavailable"])),
            cache("swiftpm-cache", .homeRelative("Library/Caches/org.swift.swiftpm"), "SwiftPM", .cache, "Swift Package Manager 다운로드 캐시입니다.", "의존성을 다시 내려받아야 할 수 있습니다."),
            cache("cocoapods-cache", .homeRelative("Library/Caches/CocoaPods"), "CocoaPods", .cache, "CocoaPods 다운로드 캐시입니다.", "다음 pod 설치 시 다시 다운로드합니다."),
            cache("swift-build", .component(".build"), "SwiftPM", .buildArtifact, "SwiftPM 프로젝트 빌드 결과입니다.", "다음 빌드가 느려집니다.")
        ]),
        StandardDetectorPack(id: "android-jvm", title: "Android / JVM", rules: [
            cache("gradle-cache", .homeRelative(".gradle/caches"), "Gradle", .cache, "Gradle 의존성·빌드 캐시입니다.", "다음 빌드에서 의존성을 다시 받거나 빌드합니다."),
            cache("maven-cache", .homeRelative(".m2/repository"), "Maven", .cache, "Maven 로컬 의존성 저장소입니다.", "필요한 의존성을 다시 다운로드합니다."),
            review("android-avd", .homeRelative(".android/avd"), "Android Emulator", .virtualMachine, "Android 가상 기기와 사용자 데이터입니다.", "앱 데이터와 스냅샷이 사라질 수 있어 Device Manager에서 확인해야 합니다."),
            cache("android-build", .component("build"), "Android/Gradle", .buildArtifact, "프로젝트의 빌드 출력 후보입니다.", "경로가 소스 폴더인지 한 번 더 확인한 뒤 정리하세요.", risk: .review)
        ]),
        StandardDetectorPack(id: "web", title: "Web / JavaScript", rules: [
            cache("npm-cache", .homeRelative(".npm/_cacache"), "npm", .cache, "npm 패키지 다운로드 캐시입니다.", "패키지를 다시 내려받을 수 있습니다."),
            cache("yarn-cache", .homeRelative("Library/Caches/Yarn"), "Yarn", .cache, "Yarn 패키지 캐시입니다.", "패키지를 다시 내려받을 수 있습니다."),
            cache("pnpm-store", .homeRelative("Library/pnpm/store"), "pnpm", .cache, "pnpm 콘텐츠 주소 저장소입니다.", "사용 중인 패키지가 다시 다운로드될 수 있습니다."),
            cache("bun-cache", .homeRelative(".bun/install/cache"), "Bun", .cache, "Bun 패키지 캐시입니다.", "패키지를 다시 내려받을 수 있습니다."),
            cache("node-modules", .component("node_modules"), "Node.js", .buildArtifact, "패키지 매니저가 설치한 프로젝트 의존성입니다.", "lockfile과 로컬 패치가 있는지 확인한 뒤 다시 설치해야 합니다.", risk: .review),
            cache("next-cache", .suffix(".next/cache"), "Next.js", .cache, "Next.js 빌드 캐시입니다.", "다음 개발 서버나 빌드가 느려집니다."),
            cache("vite-cache", .component(".vite"), "Vite", .cache, "Vite 변환 캐시입니다.", "다음 실행 시 다시 생성됩니다."),
            cache("metro-cache", .component("metro-cache"), "Metro", .cache, "Metro 번들러 변환 캐시입니다.", "다음 번들 생성이 느려집니다.")
        ]),
        StandardDetectorPack(id: "python", title: "Python", rules: [
            cache("pip-cache", .homeRelative("Library/Caches/pip"), "pip", .cache, "pip 다운로드·wheel 캐시입니다.", "패키지를 다시 내려받거나 빌드할 수 있습니다."),
            cache("uv-cache", .homeRelative(".cache/uv"), "uv", .cache, "uv 패키지 캐시입니다.", "패키지를 다시 내려받을 수 있습니다."),
            cache("poetry-cache", .homeRelative("Library/Caches/pypoetry"), "Poetry", .cache, "Poetry 패키지 캐시입니다.", "패키지를 다시 내려받을 수 있습니다."),
            review("python-venv", .component(".venv"), "Python", .buildArtifact, "프로젝트 가상환경입니다.", "의존성 명세가 있어야 안전하게 다시 만들 수 있습니다.")
        ]),
        StandardDetectorPack(id: "systems", title: "Rust / Go / Ruby", rules: [
            cache("cargo-cache", .homeRelative(".cargo/registry/cache"), "Cargo", .cache, "Cargo crate 다운로드 캐시입니다.", "crate를 다시 내려받습니다."),
            cache("cargo-target", .component("target"), "Cargo", .buildArtifact, "Rust 프로젝트 빌드 결과 후보입니다.", "다음 cargo 빌드가 느려집니다.", risk: .review),
            cache("go-build", .homeRelative("Library/Caches/go-build"), "Go", .cache, "Go 빌드 캐시입니다.", "다음 빌드가 느려집니다."),
            cache("bundler-cache", .homeRelative(".bundle/cache"), "Bundler", .cache, "Ruby gem 다운로드 캐시입니다.", "gem을 다시 내려받을 수 있습니다.")
        ]),
        StandardDetectorPack(id: "infra", title: "Container / Infra", rules: [
            review("docker-data", .homeRelative("Library/Containers/com.docker.docker"), "Docker", .container, "Docker 이미지·컨테이너·볼륨 데이터가 함께 있습니다.", "사용하지 않는 항목만 Docker 공식 명령으로 정리하며 볼륨은 포함하지 않습니다.", .officialCommand(tool: .docker, arguments: ["system", "prune", "--force"])),
            review("podman-data", .homeRelative(".local/share/containers"), "Podman", .container, "Podman 이미지·컨테이너·볼륨 데이터가 함께 있습니다.", "사용하지 않는 항목만 Podman 공식 명령으로 정리하며 볼륨은 포함하지 않습니다.", .officialCommand(tool: .podman, arguments: ["system", "prune", "--force"])),
            review("homebrew-cache", .homeRelative("Library/Caches/Homebrew"), "Homebrew", .cache, "Homebrew 다운로드 캐시와 이전 패키지 후보입니다.", "Homebrew 공식 cleanup 명령이 오래된 다운로드와 패키지를 정리합니다.", .officialCommand(tool: .brew, arguments: ["cleanup"]))
        ]),
        StandardDetectorPack(id: "ide", title: "IDE", rules: [
            cache("jetbrains-cache", .homeRelative("Library/Caches/JetBrains"), "JetBrains", .cache, "JetBrains IDE가 만든 캐시입니다.", "인덱스를 다시 만들 수 있습니다."),
            cache("vscode-cache", .homeRelative("Library/Application Support/Code/Cache"), "VS Code", .cache, "VS Code UI 캐시입니다.", "설정과 확장은 유지되며 캐시는 다시 생성됩니다."),
            cache("cursor-cache", .homeRelative("Library/Application Support/Cursor/Cache"), "Cursor", .cache, "Cursor UI 캐시입니다.", "설정과 확장은 유지되며 캐시는 다시 생성됩니다.")
        ])
    ]

    private static func cache(
        _ id: String, _ match: DetectorPathMatch, _ tool: String,
        _ category: CleanupCategory, _ reason: String, _ impact: String,
        risk: CleanupRisk = .safe
    ) -> DetectorRule {
        DetectorRule(
            id: id, match: match, tool: tool, category: category,
            reason: reason, impact: impact, risk: risk,
            recovery: .regenerated,
            action: risk == .safe ? .deleteRegeneratableCache : .moveToTrash
        )
    }

    private static func review(
        _ id: String, _ match: DetectorPathMatch, _ tool: String,
        _ category: CleanupCategory, _ reason: String, _ impact: String,
        _ action: CleanupAction = .moveToTrash
    ) -> DetectorRule {
        DetectorRule(
            id: id, match: match, tool: tool, category: category,
            reason: reason, impact: impact, risk: .review,
            recovery: action == .moveToTrash ? .trash : .unavailable,
            action: action
        )
    }
}
