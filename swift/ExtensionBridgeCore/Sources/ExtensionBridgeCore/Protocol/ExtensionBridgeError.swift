import Foundation

/// Typed runtime errors thrown by `ExtensionBridgeCore` storage, protocol, and
/// `<notify.h>` operations.
///
/// `ExtensionBridgeCore` never invokes `try!` or `fatalError` in runtime paths,
/// ensuring iOS/macOS App Extensions can recover gracefully from transient I/O
/// or schema mismatches without crashing user widgets.
public enum ExtensionBridgeError: Error, Sendable, Equatable, CustomStringConvertible, LocalizedError {
    /// A state or queue JSON envelope on disk is malformed, truncated, or
    /// missing the required `"_eb_magic": "EB01"` wire header.
    case corruptEnvelope(key: String?, message: String)

    /// An envelope's `_schema_version` exceeds the maximum version supported
    /// by the current reader binary.
    case unsupportedSchemaVersion(key: String?, foundVersion: Int, maxSupportedVersion: Int)

    /// An optimistic concurrency control (CAS) mutation exhausted its retry
    /// budget under extreme multi-process contention.
    case casContention(key: String, attempts: Int, lastHolderPid: Int32?)

    /// A POSIX or APFS filesystem operation inside the App Group container
    /// failed unexpectedly.
    case storageIo(path: String?, errno: Int32?, message: String)

    /// Staging a `@SharedAttachment` file into `blobs/` failed in both APFS
    /// `clonefile(2)` and the streaming copy fallback.
    case attachmentCloneFailed(sourcePath: String, destinationPath: String, errno: Int32?, message: String)

    /// A Darwin `<notify.h>` kernel call returned a non-zero status code
    /// (`NOTIFY_STATUS_*`).
    case darwinNotificationFailed(operation: String, notificationName: String, statusCode: UInt32)

    /// The shared App Group container could not be resolved for the given
    /// `groupId` identifier.
    case appGroupContainerUnavailable(groupId: String)

    /// Human-readable diagnostic description of this error.
    public var description: String {
        switch self {
        case let .corruptEnvelope(key, message):
            return "ExtensionBridgeError.corruptEnvelope(key: \(key ?? "<unknown>"), message: \(message))"
        case let .unsupportedSchemaVersion(key, foundVersion, maxSupportedVersion):
            return "ExtensionBridgeError.unsupportedSchemaVersion(key: \(key ?? "<unknown>"), found: \(foundVersion), maxSupported: \(maxSupportedVersion))"
        case let .casContention(key, attempts, lastHolderPid):
            let pidStr = lastHolderPid.map(String.init) ?? "unknown"
            return "ExtensionBridgeError.casContention(key: \"\(key)\", attempts: \(attempts), lastHolderPid: \(pidStr))"
        case let .storageIo(path, errno, message):
            let errnoStr = errno.map { " (errno: \($0))" } ?? ""
            return "ExtensionBridgeError.storageIo(path: \(path ?? "<unknown>")\(errnoStr), message: \(message))"
        case let .attachmentCloneFailed(sourcePath, destinationPath, errno, message):
            let errnoStr = errno.map { " (errno: \($0))" } ?? ""
            return "ExtensionBridgeError.attachmentCloneFailed(src: \"\(sourcePath)\", dst: \"\(destinationPath)\"\(errnoStr), message: \(message))"
        case let .darwinNotificationFailed(operation, notificationName, statusCode):
            return "ExtensionBridgeError.darwinNotificationFailed(op: \(operation), name: \"\(notificationName)\", status: \(statusCode))"
        case let .appGroupContainerUnavailable(groupId):
            return "ExtensionBridgeError.appGroupContainerUnavailable(groupId: \"\(groupId)\")"
        }
    }

    /// Localized error description for `LocalizedError` conformance.
    public var errorDescription: String? {
        description
    }
}
