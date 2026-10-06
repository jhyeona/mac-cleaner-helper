import Darwin
import Foundation

enum FinderTrashDiagnostic {
    /// A native integration check initiated from Settings, never on app launch.
    /// Only a freshly created, empty UUID-named fixture can reach the mover.
    static func run(mover: any TrashMoving = FinderTrashMover()) async -> String {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("biu-finder-check-\(UUID())").resolvingSymlinksInPath()
        let fixture = root.appendingPathComponent("Biu-휴지통연결테스트-\(UUID()).app")
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            // rmdir only removes this test-created parent if it is empty.
            // No recursive removal and no automatic emptying of Trash.
            defer { _ = rmdir(root.path) }
            try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: false)
            let destination = try await mover.moveToTrash(fixture)
            return "Finder 연결 확인 성공. 빈 테스트 항목만 휴지통으로 옮겼습니다. 설치된 앱은 변경하지 않았습니다. 관리자 소유 앱의 인증 성공 여부는 별도 확인이 필요합니다.\n\(destination.path)"
        } catch {
            return "Finder 연결 확인 실패: \(error.localizedDescription)\n설치된 앱은 변경하지 않았습니다. 테스트 항목: \(fixture.path)"
        }
    }
}
