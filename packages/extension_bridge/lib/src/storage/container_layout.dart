import 'dart:io';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../ffi/objc_runtime_ffi.dart';

/// {@template extension_bridge.container_layout}
/// Canonical on-disk directory and file path layout inside a shared Darwin
/// App Group container (`<AppGroupContainer>/extension_bridge/`).
///
/// ### Directory Layout
/// ```text
/// <AppGroupContainer>/
/// └── extension_bridge/
///     ├── state/
///     │   ├── <key>.v<version>.json          # Immutable snapshot (atomic rename)
///     │   ├── .<key>.v<version>.tmp.<nonce>  # Out-of-band staging file
///     │   └── .<key>.v<version>.cas          # Zero-FD symlink("<pid>:<ts>:<nonce>")
///     ├── queue/
///     │   └── <queue_key>/
///     │       ├── tmp/                       # Producer staging files
///     │       ├── ready/                     # Committed HLC-ordered envelopes
///     │       └── inflight/                  # Claimed by consumer awaiting ack()
///     └── blobs/
///         ├── queue_<item_uuid>_<idx>_<name>
///         └── state_<key>_gen_<gen>_<uuid>_<name>
/// ```
/// {@endtemplate}
@immutable
final class ContainerLayout {
  /// Creates a [ContainerLayout] rooted at [containerRootPath].
  const ContainerLayout(this.containerRootPath);

  /// Resolves the App Group container for [groupId] via
  /// [AppGroupContainerResolver] and returns its [ContainerLayout].
  factory ContainerLayout.forAppGroup(
    String groupId, {
    ObjCRuntimeFfi? objcRuntime,
    Map<String, String>? environment,
  }) =>
      ContainerLayout(
        AppGroupContainerResolver.resolve(
          groupId,
          objcRuntime: objcRuntime,
          environment: environment,
        ),
      );

  /// Root path of the shared App Group container directory.
  final String containerRootPath;

  /// Root `extension_bridge/` namespace directory inside [containerRootPath].
  String get bridgeRootPath => p.join(containerRootPath, 'extension_bridge');

  /// Directory storing `@SharedState` snapshots, `.tmp` staging files, and
  /// `.cas` symlink leases (`<container>/extension_bridge/state`).
  String get stateDirectoryPath => p.join(bridgeRootPath, 'state');

  /// Root directory storing all `@SharedQueue` Maildir queues
  /// (`<container>/extension_bridge/queue`).
  String get queueRootDirectoryPath => p.join(bridgeRootPath, 'queue');

  /// Directory storing zero-copy APFS `clonefile(2)` media attachments
  /// (`<container>/extension_bridge/blobs`).
  String get blobsDirectoryPath => p.join(bridgeRootPath, 'blobs');

  /// Ensures `state/` and `blobs/` directories exist on disk.
  void ensureBaseDirectoriesSync() {
    final stateDir = Directory(stateDirectoryPath);
    if (!stateDir.existsSync()) {
      stateDir.createSync(recursive: true);
    }
    final blobsDir = Directory(blobsDirectoryPath);
    if (!blobsDir.existsSync()) {
      blobsDir.createSync(recursive: true);
    }
  }

  /// Ensures the Maildir subdirectories (`tmp/`, `ready/`, `inflight/`) exist
  /// for [queueKey].
  void ensureQueueDirectoriesSync(String queueKey) {
    ensureBaseDirectoriesSync();
    for (final dirPath in <String>[
      queueTmpDirectoryPath(queueKey),
      queueReadyDirectoryPath(queueKey),
      queueInflightDirectoryPath(queueKey),
    ]) {
      final dir = Directory(dirPath);
      if (!dir.existsSync()) {
        dir.createSync(recursive: true);
      }
    }
  }

  /// Canonical file path for the active `@SharedState` snapshot of [key] at
  /// [schemaVersion] (`state/<key>.v<schemaVersion>.json`).
  String stateSnapshotPath(String key, {int schemaVersion = 1}) =>
      p.join(stateDirectoryPath, '$key.v$schemaVersion.json');

  /// Hidden staging file path written and flushed before entering the `.cas`
  /// critical section (`state/.<key>.v<schemaVersion>.tmp.<nonce>`).
  String stateStagingPath(
    String key, {
    required String nonce,
    int schemaVersion = 1,
  }) =>
      p.join(stateDirectoryPath, '.$key.v$schemaVersion.tmp.$nonce');

  /// Filename prefix for any `.tmp.` staging file belonging to [key] at
  /// [schemaVersion].
  String stateStagingPrefix(String key, {int schemaVersion = 1}) =>
      '.$key.v$schemaVersion.tmp.';

  /// Atomic POSIX symlink lease path for [key] at [schemaVersion]
  /// (`state/.<key>.v<schemaVersion>.cas`).
  String stateCasLeasePath(String key, {int schemaVersion = 1}) =>
      p.join(stateDirectoryPath, '.$key.v$schemaVersion.cas');

  /// Root directory for a specific `@SharedQueue` [queueKey]
  /// (`queue/<queueKey>`).
  String queueDirectoryPath(String queueKey) =>
      p.join(queueRootDirectoryPath, queueKey);

  /// Producer staging directory for [queueKey] (`queue/<queueKey>/tmp`).
  String queueTmpDirectoryPath(String queueKey) =>
      p.join(queueDirectoryPath(queueKey), 'tmp');

  /// Committed items directory for [queueKey] (`queue/<queueKey>/ready`).
  String queueReadyDirectoryPath(String queueKey) =>
      p.join(queueDirectoryPath(queueKey), 'ready');

  /// Consumer in-flight directory for [queueKey] (`queue/<queueKey>/inflight`).
  String queueInflightDirectoryPath(String queueKey) =>
      p.join(queueDirectoryPath(queueKey), 'inflight');

  /// Container-relative path (`blobs/state_<stateKey>_gen_<generation>_<nonce>_<name>`)
  /// for a `@SharedState` attachment blob.
  String stateBlobRelativePath({
    required String stateKey,
    required int generation,
    required String nonce,
    required String originalFileName,
  }) {
    final safeName = _sanitizeFileName(originalFileName);
    return p.posix.join(
      'blobs',
      'state_${stateKey}_gen_${generation}_${nonce}_$safeName',
    );
  }

  /// Container-relative path (`blobs/queue_<itemUuid>_<index>_<name>`) for a
  /// `@SharedQueue` attachment blob.
  String queueBlobRelativePath({
    required String itemUuid,
    required int attachmentIndex,
    required String originalFileName,
  }) {
    final safeName = _sanitizeFileName(originalFileName);
    return p.posix.join(
      'blobs',
      'queue_${itemUuid}_${attachmentIndex}_$safeName',
    );
  }

  /// Converts a container-relative blob path (`blobs/...`) into an absolute
  /// filesystem path inside [bridgeRootPath].
  ///
  /// If [relativeOrAbsolutePath] is already an absolute path, returns it
  /// unchanged.
  String resolveBlobPath(String relativeOrAbsolutePath) {
    if (p.isAbsolute(relativeOrAbsolutePath)) {
      return relativeOrAbsolutePath;
    }
    final normalized = p.normalize(
      relativeOrAbsolutePath.replaceAll('/', p.separator),
    );
    return p.join(bridgeRootPath, normalized);
  }

  static String _sanitizeFileName(String rawName) {
    final base = p.basename(rawName).trim();
    if (base.isEmpty) return 'blob.bin';
    return base.replaceAll(RegExp('[^a-zA-Z0-9._-]'), '_');
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ContainerLayout &&
          other.containerRootPath == containerRootPath;

  @override
  int get hashCode => containerRootPath.hashCode;

  @override
  String toString() => 'ContainerLayout($containerRootPath)';
}
