import Foundation

struct SafetyClassifier: Sendable {
    func classify(path rawPath: String) -> SafetyAssessment {
        classifyNormalized(
            path: normalize(rawPath),
            category: CleanupCategory.infer(from: rawPath),
            kind: nil,
            detectorRule: nil
        )
    }

    func classify(candidate: CleanupCandidate, detectorRule: DetectorRule? = nil) -> SafetyAssessment {
        classifyNormalized(
            path: normalize(candidate.path),
            category: candidate.category,
            kind: candidate.kind,
            detectorRule: detectorRule
        )
    }

    func isProtected(path rawPath: String) -> Bool {
        classify(path: rawPath).risk == .avoid
    }

    private func classifyNormalized(
        path: String,
        category: CleanupCategory,
        kind: CandidateKind?,
        detectorRule: DetectorRule?
    ) -> SafetyAssessment {
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        if detectorRule == nil,
           path != "/",
           path.split(separator: "/").count == 1 {
            return protected(
                "시동 디스크의 최상위 항목입니다.",
                "사용자 파일처럼 보여도 시스템·앱·다른 계정이 사용하는 영역일 수 있어 비우가 정리하지 않습니다."
            )
        }

        if kind == .symbolicLink {
            return protected(
                "심볼릭 링크는 실제 대상이 선택 범위 밖에 있을 수 있습니다.",
                "링크와 원본을 혼동하지 않도록 자동 정리 대상에서 제외합니다."
            )
        }
        if kind == .inaccessible {
            return protected(
                "권한 때문에 내용을 확인하지 못했습니다.",
                "내용과 크기를 검증할 수 없으므로 정리하지 않습니다."
            )
        }

        let systemRoots = [
            "/System", "/bin", "/sbin", "/usr", "/Library",
            "/private/var/db", "/private/var/root", "/private/etc"
        ]
        if isInside(path, anyOf: systemRoots) {
            return protected(
                "macOS 또는 모든 사용자에게 필요한 영역입니다.",
                "삭제하면 앱이나 시스템 기능이 손상될 수 있어 자동 정리 대상에서 제외합니다."
            )
        }

        if path == home || path == "\(home)/Library" {
            return protected(
                "사용자 계정의 핵심 데이터 영역입니다.",
                "이 폴더 전체를 정리하면 개인 파일과 앱 설정이 함께 손상될 수 있습니다."
            )
        }

        let personalRootFolders = [
            "\(home)/Desktop", "\(home)/Documents", "\(home)/Pictures",
            "\(home)/Movies", "\(home)/Music"
        ]
        if personalRootFolders.contains(path) {
            return protected(
                "개인 원본이 모이는 기본 폴더입니다.",
                "폴더 전체가 아닌 내부 항목을 확인하고 필요한 파일만 직접 정리해야 합니다."
            )
        }

        let importantUserData = [
            "\(home)/.ssh", "\(home)/.gnupg", "\(home)/.aws", "\(home)/.kube",
            "\(home)/Library/Mail", "\(home)/Library/Messages",
            "\(home)/Library/Photos", "\(home)/Library/Keychains",
            "\(home)/Library/Accounts", "\(home)/Library/Preferences",
            "\(home)/Library/Safari",
            "\(home)/Pictures/Photos Library.photoslibrary",
            "\(home)/Library/Application Support/MobileSync/Backup"
        ]
        if isInside(path, anyOf: importantUserData) || category == .personal {
            return protected(
                "개인 원본, 인증 정보 또는 유일한 백업이 포함될 수 있습니다.",
                "해당 앱 안에서 정리하거나 별도 백업을 만든 뒤 직접 확인해야 합니다."
            )
        }

        let lowercased = path.lowercased()
        if [".sqlite", ".sqlite3", ".db", ".keychain-db"].contains(where: lowercased.hasSuffix) {
            return protected(
                "데이터베이스나 인증 저장소로 보이는 파일입니다.",
                "일부만 삭제해도 데이터가 손상될 수 있어 정리하지 않습니다."
            )
        }

        if [.container, .virtualMachine, .simulator].contains(category) {
            return SafetyAssessment(
                risk: .review,
                reason: detectorRule?.reason ?? "앱, 가상 기기 또는 볼륨의 원본 데이터가 포함될 수 있습니다.",
                impact: detectorRule?.impact ?? "관련 도구의 공식 관리 화면이나 명령으로 내용을 확인해야 합니다.",
                recovery: .backupOnly,
                canAutoSelect: false
            )
        }

        if let detectorRule {
            return SafetyAssessment(
                risk: detectorRule.risk,
                reason: detectorRule.reason,
                impact: detectorRule.impact,
                recovery: detectorRule.recovery,
                canAutoSelect: detectorRule.risk == .safe
            )
        }

        if isInside(path, anyOf: ["\(home)/Library/Caches"]) {
            return SafetyAssessment(
                risk: .safe,
                reason: "앱이 필요할 때 다시 만드는 임시 데이터입니다.",
                impact: "처음 실행이 잠시 느려지거나 일부 콘텐츠를 다시 내려받을 수 있습니다.",
                recovery: .regenerated
            )
        }

        if isInside(path, anyOf: ["\(home)/Library/Developer/Xcode/DerivedData"]) {
            return SafetyAssessment(
                risk: .safe,
                reason: "Xcode가 빌드하면서 생성한 중간 결과물입니다.",
                impact: "다음 빌드 시간이 길어질 수 있지만 소스 코드는 삭제되지 않습니다.",
                recovery: .regenerated
            )
        }

        if isInside(path, anyOf: ["\(home)/Downloads", "\(home)/.Trash"]) {
            return SafetyAssessment(
                risk: .review,
                reason: "사용자가 저장했거나 이미 버리기로 한 파일이 섞여 있습니다.",
                impact: "필요한 파일이 없는지 목록을 직접 확인한 뒤 정리해야 합니다.",
                recovery: .trash,
                canAutoSelect: false
            )
        }

        if isInside(path, anyOf: ["\(home)/Library/Containers", "\(home)/Library/Application Support"]) {
            return SafetyAssessment(
                risk: .review,
                reason: "앱 설정과 사용자 데이터가 함께 있을 수 있습니다.",
                impact: "관련 앱이 초기화되거나 저장된 작업이 사라질 수 있습니다.",
                recovery: .backupOnly,
                canAutoSelect: false
            )
        }

        return SafetyAssessment(
            risk: .review,
            reason: "파일의 용도를 경로만으로 확정할 수 없습니다.",
            impact: "Finder에서 내용을 확인하고 백업 여부를 점검한 뒤 정리하세요.",
            recovery: .trash,
            canAutoSelect: false
        )
    }

    private func protected(_ reason: String, _ impact: String) -> SafetyAssessment {
        SafetyAssessment(
            risk: .avoid, reason: reason, impact: impact,
            recovery: .unavailable, canAutoSelect: false
        )
    }

    private func normalize(_ path: String) -> String {
        (path as NSString).standardizingPath
    }

    private func isInside(_ path: String, anyOf roots: [String]) -> Bool {
        roots.contains { root in path == root || path.hasPrefix(root + "/") }
    }
}
