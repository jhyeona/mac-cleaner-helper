import AppKit
import Darwin
import Foundation

protocol TrashMoving: Sendable {
    func moveToTrash(_ url: URL) async throws -> URL
}

/// Use the system's Finder-style operation, which can present its own UI,
/// rather than FileManager's noninteractive, caller-permission-only move.
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
    case unconfirmed

    var errorDescription: String? {
        switch self {
        case .cancelled:
            "macOS 휴지통 이동 또는 인증이 취소되었습니다. 대상은 바구니에 남아 있으며 다시 시도할 수 있습니다."
        case .permissionDenied(let details):
            "macOS가 휴지통 이동 권한을 허용하지 않았습니다. 앱을 지우는 경우 시스템 설정 > 개인정보 보호 및 보안 > 앱 관리에서 비우를 허용한 후 바구니에서 다시 시도하세요. 파일 잠금이나 읽기 전용 디스크도 확인이 필요합니다.\n\(details)"
        case .unconfirmed:
            "macOS에서 휴지통 이동 완료를 확인하지 못했습니다. 성공으로 처리하지 않았습니다."
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
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        current = error as NSError
        for _ in 0..<8 {
            guard let value = current else { break }
            if (value.domain == NSCocoaErrorDomain && [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(value.code))
                || (value.domain == NSPOSIXErrorDomain && [Int(EACCES), Int(EPERM)].contains(value.code))
                || (value.domain == NSOSStatusErrorDomain && value.code == -54) {
                return Self.permissionDenied(error.localizedDescription)
            }
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return error
    }
}
