/// Base sealed class for all typed runtime exceptions thrown by
/// `extension_bridge`.
sealed class ExtensionBridgeException implements Exception {
  /// Creates an [ExtensionBridgeException] with a human-readable [message].
  const ExtensionBridgeException(this.message);

  /// Human-readable description of the failure.
  final String message;

  @override
  String toString() => '$runtimeType: $message';
}

/// Thrown when a state or queue envelope on disk is malformed, truncated, or
/// missing the required `"_eb_magic": "EB01"` wire header.
final class CorruptEnvelopeException extends ExtensionBridgeException {
  /// Creates a [CorruptEnvelopeException].
  const CorruptEnvelopeException(
    super.message, {
    this.key,
    this.rawContent,
    this.cause,
  });

  /// Optional logical state or queue key where the corrupt envelope was found.
  final String? key;

  /// Optional raw JSON string that failed validation.
  final String? rawContent;

  /// Optional underlying parser error.
  final Object? cause;

  @override
  String toString() => 'CorruptEnvelopeException('
      'key: ${key ?? '<unknown>'}, '
      'message: $message'
      '${cause != null ? ', cause: $cause' : ''})';
}

/// Thrown when an envelope's `_schema_version` exceeds the maximum version
/// supported by the current binary and cannot be decoded safely.
final class UnsupportedSchemaVersionException extends ExtensionBridgeException {
  /// Creates an [UnsupportedSchemaVersionException].
  const UnsupportedSchemaVersionException({
    required this.foundVersion,
    required this.maxSupportedVersion,
    this.key,
  }) : super(
          'Unsupported envelope _schema_version $foundVersion '
          '(max supported: $maxSupportedVersion)',
        );

  /// Logical state or queue key.
  final String? key;

  /// The `_schema_version` integer encountered in the envelope.
  final int foundVersion;

  /// The maximum schema version supported by the reader.
  final int maxSupportedVersion;
}

/// Thrown when an optimistic concurrency control (CAS) mutation exhausts its
/// retry budget under extreme multi-process contention.
final class CasContentionException extends ExtensionBridgeException {
  /// Creates a [CasContentionException].
  const CasContentionException({
    required this.key,
    required this.attempts,
    this.lastHolderPid,
  }) : super(
          'CAS mutation on "$key" exhausted $attempts attempts '
          '(last lease holder PID: ${lastHolderPid ?? 'unknown'})',
        );

  /// The state key that experienced CAS contention.
  final String key;

  /// Total number of CAS attempts performed before aborting.
  final int attempts;

  /// Optional PID of the last observed `.cas` symlink lease holder.
  final int? lastHolderPid;
}

/// Thrown when a POSIX or APFS file system operation inside the App Group
/// container fails unexpectedly.
final class StorageIoException extends ExtensionBridgeException {
  /// Creates a [StorageIoException].
  const StorageIoException(
    super.message, {
    this.path,
    this.errno,
    this.cause,
  });

  /// File system path associated with the failed operation.
  final String? path;

  /// Optional POSIX `errno` code.
  final int? errno;

  /// Optional underlying error object.
  final Object? cause;
}

/// Thrown when staging a `@SharedAttachment` file into `blobs/` fails in both
/// `clonefile(2)` and the streaming copy fallback.
final class AttachmentCloneException extends ExtensionBridgeException {
  /// Creates an [AttachmentCloneException].
  const AttachmentCloneException(
    super.message, {
    required this.sourcePath,
    required this.destinationPath,
    this.errno,
  });

  /// Source file path outside or inside the container.
  final String sourcePath;

  /// Target blob path inside `<AppGroup>/extension_bridge/blobs/`.
  final String destinationPath;

  /// Optional POSIX `errno` code returned by `clonefile(2)` or file I/O.
  final int? errno;
}

/// Thrown when a Darwin `<notify.h>` kernel call returns a non-zero status
/// code (`NOTIFY_STATUS_*`).
final class DarwinNotificationException extends ExtensionBridgeException {
  /// Creates a [DarwinNotificationException].
  const DarwinNotificationException({
    required this.operation,
    required this.notificationName,
    required this.statusCode,
  }) : super(
          '<notify.h> $operation failed for "$notificationName" '
          'with status code $statusCode',
        );

  /// Name of the `<notify.h>` C function (e.g., `'notify_register_dispatch'`).
  final String operation;

  /// Darwin notification name.
  final String notificationName;

  /// Numeric `NOTIFY_STATUS_*` code returned by `libsystem_notify.dylib`.
  final int statusCode;
}
