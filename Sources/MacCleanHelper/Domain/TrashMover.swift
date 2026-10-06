import AppKit
import Darwin
import Foundation

protocol TrashMoving: Sendable {
    func moveToTrash(_ url: URL) async throws -> URL
}

/// This operation still runs with the caller's file-system permissions.
/// In particular, it does not authenticate to move root-owned applications.
struct SystemTrashMover: TrashMoving {
    @MainActor
    func moveToTrash(_ url: URL) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            NSWorkspace.shared.recycle([url]) { destinations, error in
                do {
                    continuation.resume(returning: try Self.confirmedDestination(
                        for: url, destinations: destinations, error: error
                    ))
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    static func confirmedDestination(for url: URL, destinations: [URL: URL], error: Error?) throws -> URL {
        if let error { throw TrashMoveFailure.classify(error) }
        guard let destination = destinations[url] else { throw TrashMoveFailure.unconfirmed }
        return destination
    }
}

enum TrashMoveFailure: LocalizedError, Equatable {
    case cancelled
    case permissionDenied(String)
    case automationDenied
    case timedOut
    case unconfirmed

    var errorDescription: String? {
        switch self {
        case .cancelled:
            "macOS 휴지통 이동 또는 인증이 취소되었습니다. 대상은 바구니에 남아 있으며 다시 시도할 수 있습니다."
        case .permissionDenied(let details):
            "휴지통 이동에 필요한 권한이 없습니다. 앱 관리 권한과 파일 소유권·잠금·볼륨 권한은 서로 다른 조건입니다. 앱 관리가 이미 켜져 있다면 같은 설정을 반복할 필요는 없습니다.\n\(details)"
        case .automationDenied:
            "Finder에 휴지통 이동을 요청할 권한이 없습니다. 시스템 설정 > 개인정보 보호 및 보안 > 자동화 > 비우에서 Finder를 허용한 뒤 다시 시도하세요. 앱 관리 또는 전체 디스크 접근 권한과는 다릅니다."
        case .timedOut:
            "Finder의 응답 시간이 초과되었습니다. 작업이 진행 중이거나 이미 이동됐을 수 있습니다. Finder의 인증 창과 원래 앱 위치를 확인한 뒤 새로고침하세요. 자동 재시도하지 않았습니다."
        case .unconfirmed:
            "macOS에서 휴지통 이동 완료를 확인하지 못했습니다. 이미 이동됐을 수 있으므로 원래 위치와 휴지통을 확인한 뒤 새로고침하세요. 성공으로 처리하거나 자동 재시도하지 않았습니다."
        }
    }

    static func classify(_ error: Error) -> Error {
        var current: NSError? = error as NSError
        // NSError chains are not guaranteed to be acyclic.
        for _ in 0..<8 {
            guard let value = current else { break }
            if (value.domain == NSCocoaErrorDomain && value.code == NSUserCancelledError)
                || (value.domain == NSOSStatusErrorDomain && value.code == -128)
                || (value.domain == NSPOSIXErrorDomain && value.code == Int(ECANCELED)) {
                return Self.cancelled
            }
            if value.domain == NSOSStatusErrorDomain && value.code == -1743 { return Self.automationDenied }
            if value.domain == NSOSStatusErrorDomain && value.code == -1712 { return Self.timedOut }
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        current = error as NSError
        for _ in 0..<8 {
            guard let value = current else { break }
            if (value.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(value.code))
                || (value.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(value.code))
                || (value.domain == NSOSStatusErrorDomain && value.code == -54) {
                return Self.permissionDenied("\(error.localizedDescription)\n오류: \(value.domain) (\(value.code))")
            }
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return error
    }
}
