import AppKit
import Carbon
import Darwin
import Foundation

/// Delegates only Finder's documented `core/delo` (move to Trash) command.
/// No shell, AppleScript source, root helper, chmod, or permanent deletion.
/// Finder owns the authentication UI; Biu never receives credentials.
struct FinderTrashMover: TrashMoving {
    func moveToTrash(_ url: URL) async throws -> URL {
        // A synchronous Apple-event reply can wait for a human to authenticate.
        // Keep it off the UI actor, with all descriptors confined to this task.
        try await Task.detached(priority: .userInitiated) {
            try Self.perform(url)
        }.value
    }

    private static func perform(_ url: URL) throws -> URL {
        let identity = try validateApplication(url)
        let volume = try url.resourceValues(forKeys: [.volumeURLKey]).volume
        let trashDirectories = [FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".Trash")]
            + (volume.map { [$0.appendingPathComponent(".Trashes/\(getuid())")] } ?? [])
        let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
        guard let address = target.aeDesc else { throw TrashMoveFailure.unconfirmed }
        // Obtain automation consent BEFORE resolving the final target, then
        // recheck identity and running apps after the user has answered.
        let permission = AEDeterminePermissionToAutomateTarget(
            address, AEEventClass(kCoreEventClass), AEEventID(kAEDelete), true
        )
        guard permission == noErr else { throw failure(code: Int(permission)) }
        try Task.checkCancellation()
        guard try validateApplication(url) == identity else { throw CleanupEngineError.targetChanged }
        let request = try deleteEvent(for: url)
        let reply = try send(request)
        let result = try resultDescriptor(from: reply)
        let destination: URL
        if let directURL = result.fileURLValue {
            destination = directURL
        } else {
            // Finder returns an object specifier for the item now in Trash.
            // Resolve that exact result, never search Trash or infer a filename.
            let lookup = event(id: AEEventID(kAEGetData))
            lookup.setParam(result, forKeyword: AEKeyword(keyDirectObject))
            lookup.setParam(NSAppleEventDescriptor(typeCode: DescType(typeAlias)), forKeyword: AEKeyword(keyAERequestedType))
            let resolved = try resultDescriptor(from: send(lookup))
            guard let resolvedURL = resolved.fileURLValue else { throw TrashMoveFailure.unconfirmed }
            destination = resolvedURL
        }
        try validateDestination(destination, original: url, trashDirectories: trashDirectories)
        // Do not treat an inaccessible source as a successful removal.
        var info = stat()
        guard lstat(url.path, &info) != 0, errno == ENOENT else { throw TrashMoveFailure.unconfirmed }
        return destination
    }

    static func validateApplication(_ url: URL) throws -> FileIdentity {
        guard url.isFileURL, url.path.hasPrefix("/"),
              ApplicationRemovalPolicy.isApplication(url) else { throw CleanupEngineError.invalidPath }
        if let reason = ApplicationRemovalPolicy.blockedReason(at: url) {
            throw CleanupEngineError.applicationRemovalBlocked(reason)
        }
        // Do not authorize an indirect target through any symlinked ancestor.
        guard url.standardizedFileURL.path == url.resolvingSymlinksInPath().path else {
            throw CleanupEngineError.symbolicLink
        }
        let values = try url.resourceValues(forKeys: [.volumeIsLocalKey, .volumeIsReadOnlyKey])
        guard values.volumeIsLocal == true, values.volumeIsReadOnly == false else {
            throw CleanupEngineError.applicationRemovalBlocked("Finder 인증 이동은 쓰기 가능한 로컬 볼륨의 앱만 지원합니다.")
        }
        let blockers = ApplicationRemovalPolicy.blockers(for: url.path, running: RunningApplication.current())
        guard blockers.isEmpty else { throw CleanupEngineError.applicationRunning(blockers) }
        var info = stat()
        guard lstat(url.path, &info) == 0 else { throw CleanupEngineError.targetMissing }
        guard (info.st_mode & S_IFMT) == S_IFDIR else { throw CleanupEngineError.invalidPath }
        return FileIdentity(device: UInt64(info.st_dev), inode: UInt64(info.st_ino))
    }

    static func deleteEvent(for url: URL) throws -> NSAppleEventDescriptor {
        // Alias data identifies the selected item. Paths are never interpolated
        // into executable text (quotes, newlines and shell syntax are just names).
        guard let alias = NSAppleEventDescriptor(fileURL: url).coerce(toDescriptorType: DescType(typeAlias)) else {
            throw CleanupEngineError.targetMissing
        }
        let request = event(id: AEEventID(kAEDelete))
        request.setParam(alias, forKeyword: AEKeyword(keyDirectObject))
        return request
    }

    private static func event(id: AEEventID) -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: id,
                              targetDescriptor: NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder"),
                              returnID: AEReturnID(kAutoGenerateReturnID), transactionID: AETransactionID(kAnyTransactionID))
    }

    private static func send(_ request: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        do {
            return try request.sendEvent(options: [.waitForReply, .alwaysInteract, .canSwitchLayer, .dontRecord], timeout: 300)
        } catch { throw TrashMoveFailure.classify(error) }
    }

    static func resultDescriptor(from reply: NSAppleEventDescriptor) throws -> NSAppleEventDescriptor {
        if let error = reply.paramDescriptor(forKeyword: AEKeyword(keyErrorNumber)), error.int32Value != 0 {
            throw failure(code: Int(error.int32Value), message: reply.paramDescriptor(forKeyword: AEKeyword(keyErrorString))?.stringValue)
        }
        guard let result = reply.paramDescriptor(forKeyword: AEKeyword(keyDirectObject)),
              result.descriptorType != DescType(typeNull) else { throw TrashMoveFailure.unconfirmed }
        if result.descriptorType == DescType(typeAEList) {
            guard result.numberOfItems == 1, let single = result.atIndex(1) else { throw TrashMoveFailure.unconfirmed }
            return single
        }
        return result
    }

    static func failure(code: Int, message: String? = nil) -> Error {
        let details = message ?? "Finder 오류 (\(code))"
        // Finder may report afpAccessDenied rather than the POSIX cause.
        if code == -5000 || code == -10004 { return TrashMoveFailure.permissionDenied("\(details)\n오류: NSOSStatusErrorDomain (\(code))") }
        return TrashMoveFailure.classify(NSError(domain: NSOSStatusErrorDomain, code: code,
                                                userInfo: [NSLocalizedDescriptionKey: details]))
    }

    static func validateDestination(_ destination: URL, original: URL, trashDirectories: [URL]) throws {
        guard destination.isFileURL,
              destination.standardizedFileURL.path != original.standardizedFileURL.path,
              trashDirectories.contains(where: {
                  destination.standardizedFileURL.deletingLastPathComponent().path == $0.standardizedFileURL.path
              }) else { throw TrashMoveFailure.unconfirmed }
    }
}
