import 'dart:io';
import 'dart:math' as math;

import 'package:extension_bridge_annotation/extension_bridge_annotation.dart';
import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../ffi/apfs_clonefile.dart';
import '../ffi/darwin_posix_ffi.dart';
import 'container_layout.dart';

/// Default number of historical `@SharedState` generations whose attachment
/// blobs are retained on disk before lazy garbage collection (`currentGen - 2`).
///
/// Retaining `currentGen - 1` and `currentGen - 2` guarantees that a concurrent
/// reader that opened a snapshot just before a new `rename(2)` commit can still
/// read its referenced attachment blobs without racing deletion.
const int kDefaultStateBlobRetentionGenerations = 2;

/// {@template extension_bridge.staged_attachment_result}
/// Result of staging a model's `@SharedAttachment` files into
/// `<AppGroup>/extension_bridge/blobs/`.
/// {@endtemplate}
@immutable
final class StagedAttachments<T> {
  /// {@macro extension_bridge.staged_attachment_result}
  const StagedAttachments({
    required this.stagedValue,
    required this.relativeBlobPaths,
  });

  /// Copy of the model where `@SharedAttachment` fields have been rewritten to
  /// container-relative `blobs/...` paths for JSON serialization.
  final T stagedValue;

  /// List of container-relative `blobs/...` paths created during this staging
  /// pass.
  final List<String> relativeBlobPaths;
}

/// Callback that stages any `@SharedAttachment` file paths on [value] for a
/// `@SharedState` write at [generation].
typedef StateAttachmentStager<T> = StagedAttachments<T> Function({
  required T value,
  required int generation,
  required SharedAttachmentManager manager,
});

/// Callback that stages any `@SharedAttachment` file paths on [value] for a
/// `@SharedQueue` enqueue with [itemUuid].
typedef QueueAttachmentStager<T> = StagedAttachments<T> Function({
  required T value,
  required String itemUuid,
  required SharedAttachmentManager manager,
});

/// Callback that resolves container-relative `blobs/...` paths on [value] back
/// to absolute filesystem paths inside the current process's App Group mount.
typedef AttachmentPathResolver<T> = T Function(
  T value,
  SharedAttachmentManager manager,
);

/// {@template extension_bridge.shared_attachment_manager}
/// Manages zero-copy APFS `clonefile(2)` staging, path resolution, and
/// generation-bounded garbage collection for `@SharedAttachment` blobs inside
/// `<AppGroupContainer>/extension_bridge/blobs/`.
/// {@endtemplate}
final class SharedAttachmentManager {
  /// {@macro extension_bridge.shared_attachment_manager}
  SharedAttachmentManager({
    required this.layout,
    ApfsFileCloner? fileCloner,
    DarwinPosixFfi? posix,
  })  : _cloner = fileCloner ?? ApfsFileCloner(posix: posix),
        _posix = posix ?? DarwinPosixFfi.instance;

  /// Container directory layout.
  final ContainerLayout layout;

  final ApfsFileCloner _cloner;
  final DarwinPosixFfi _posix;
  final math.Random _random = math.Random();
  int _nonceCounter = 0;

  int _clonedBlobCount = 0;
  int _streamFallbackBlobCount = 0;
  int _garbageCollectedBlobCount = 0;

  /// Total number of blobs materialized via zero-copy APFS `clonefile(2)`.
  int get clonedBlobCount => _clonedBlobCount;

  /// Total number of blobs materialized via the chunked streaming fallback.
  int get streamFallbackBlobCount => _streamFallbackBlobCount;

  /// Total number of stale or acknowledged blobs unlinked from `blobs/`.
  int get garbageCollectedBlobCount => _garbageCollectedBlobCount;

  /// Stages a single `@SharedState` attachment file from [sourcePath] into
  /// `blobs/state_<stateKey>_gen_<generation>_<nonce>_<name>` and returns its
  /// container-relative path (`blobs/...`).
  String stageStateAttachment({
    required String sourcePath,
    required String stateKey,
    required int generation,
    AttachmentCopyMode copyMode = AttachmentCopyMode.cloneOrStream,
  }) {
    final resolvedSource = layout.resolveBlobPath(sourcePath);
    final relativeDst = layout.stateBlobRelativePath(
      stateKey: stateKey,
      generation: generation,
      nonce: _nextShortNonce(),
      originalFileName: p.basename(resolvedSource),
    );
    final absoluteDst = layout.resolveBlobPath(relativeDst);

    final result = _cloner.cloneFileSync(
      sourcePath: resolvedSource,
      destinationPath: absoluteDst,
      copyMode: copyMode,
    );
    if (result.strategy == CloneStrategy.apfsClonefile) {
      _clonedBlobCount += 1;
    } else {
      _streamFallbackBlobCount += 1;
    }
    return relativeDst;
  }

  /// Stages a single `@SharedQueue` attachment file from [sourcePath] into
  /// `blobs/queue_<itemUuid>_<attachmentIndex>_<name>` and returns its
  /// container-relative path (`blobs/...`).
  String stageQueueAttachment({
    required String sourcePath,
    required String itemUuid,
    required int attachmentIndex,
    AttachmentCopyMode copyMode = AttachmentCopyMode.cloneOrStream,
  }) {
    final resolvedSource = layout.resolveBlobPath(sourcePath);
    final relativeDst = layout.queueBlobRelativePath(
      itemUuid: itemUuid,
      attachmentIndex: attachmentIndex,
      originalFileName: p.basename(resolvedSource),
    );
    final absoluteDst = layout.resolveBlobPath(relativeDst);

    final result = _cloner.cloneFileSync(
      sourcePath: resolvedSource,
      destinationPath: absoluteDst,
      copyMode: copyMode,
    );
    if (result.strategy == CloneStrategy.apfsClonefile) {
      _clonedBlobCount += 1;
    } else {
      _streamFallbackBlobCount += 1;
    }
    return relativeDst;
  }

  /// Resolves a container-relative blob path (`blobs/...`) to an absolute path
  /// inside the App Group container.
  String resolveAttachmentPath(String relativeOrAbsolutePath) =>
      layout.resolveBlobPath(relativeOrAbsolutePath);

  /// Unlinks the given [relativeOrAbsolutePaths] from `blobs/`.
  ///
  /// Used when a `@SharedQueue` item is acknowledged (`ack()`), when an aborted
  /// CAS attempt rolls back its staged blobs, or when oldest-item queue
  /// backpressure evicts an envelope.
  int unlinkBlobs(Iterable<String> relativeOrAbsolutePaths) {
    var removed = 0;
    for (final rawPath in relativeOrAbsolutePaths) {
      final absPath = layout.resolveBlobPath(rawPath);
      if (_posix.unlink(absPath) == 0) {
        removed += 1;
        _garbageCollectedBlobCount += 1;
      }
    }
    return removed;
  }

  /// Garbage-collects `@SharedState` blobs belonging to [stateKey] whose
  /// generation is strictly older than
  /// `currentGeneration - retentionGenerations` (`< currentGen - 2`), as well
  /// as any leftover `.tmp.` staging artifacts inside `blobs/`.
  ///
  /// Returns the number of unlinked blob files.
  int gcStaleStateBlobs({
    required String stateKey,
    required int currentGeneration,
    int retentionGenerations = kDefaultStateBlobRetentionGenerations,
  }) {
    final blobsDir = Directory(layout.blobsDirectoryPath);
    if (!blobsDir.existsSync()) return 0;

    final minRetainedGen = currentGeneration - retentionGenerations;
    final prefix = 'state_${stateKey}_gen_';
    var removed = 0;

    List<FileSystemEntity> entries;
    try {
      entries = blobsDir.listSync(followLinks: false);
    } on FileSystemException {
      return 0;
    }

    for (final entry in entries) {
      final name = p.basename(entry.path);
      if (name.startsWith('.') && name.contains('.tmp.')) {
        if (_posix.unlink(entry.path) == 0) {
          removed += 1;
          _garbageCollectedBlobCount += 1;
        }
        continue;
      }

      if (!name.startsWith(prefix)) continue;
      final rest = name.substring(prefix.length);
      final underscoreIdx = rest.indexOf('_');
      if (underscoreIdx <= 0) continue;

      final blobGen = int.tryParse(rest.substring(0, underscoreIdx), radix: 10);
      if (blobGen == null) continue;

      if (blobGen < minRetainedGen) {
        if (_posix.unlink(entry.path) == 0) {
          removed += 1;
          _garbageCollectedBlobCount += 1;
        }
      }
    }

    return removed;
  }

  String _nextShortNonce() {
    final seq = (++_nonceCounter) & 0xFFFF;
    final rand = _random.nextInt(0xFFFFFF);
    return '${seq.toRadixString(16)}${rand.toRadixString(16).padLeft(6, '0')}';
  }
}
