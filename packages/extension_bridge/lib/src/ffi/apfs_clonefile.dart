import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../protocol/bridge_exception.dart';
import 'darwin_posix_ffi.dart';

/// Strategy used by [ApfsFileCloner] to materialize a blob inside the App Group
/// container.
enum CloneStrategy {
  /// Zero-copy APFS Copy-on-Write inode clone (`clonefile(2)` with
  /// `CLONE_NOOWNERCOPY`).
  apfsClonefile,

  /// Chunked streaming file copy fallback used when `clonefile(2)` returns
  /// `EXDEV` (cross-volume), `ENOTSUP` (non-APFS filesystem), or `ENOSYS`.
  streamingFallback,
}

/// {@template extension_bridge.apfs_clone_result}
/// Telemetry and outcome descriptor returned by [ApfsFileCloner.cloneFile] and
/// [ApfsFileCloner.cloneFileSync].
/// {@endtemplate}
@immutable
final class ApfsCloneResult {
  /// {@macro extension_bridge.apfs_clone_result}
  const ApfsCloneResult({
    required this.sourcePath,
    required this.destinationPath,
    required this.strategy,
    required this.elapsedMicros,
    this.fallbackErrno,
  });

  /// Original source file path.
  final String sourcePath;

  /// Materialized destination path inside `<AppGroup>/extension_bridge/blobs/`.
  final String destinationPath;

  /// Whether the file was cloned via zero-copy APFS `clonefile(2)` or the
  /// chunked streaming copy fallback.
  final CloneStrategy strategy;

  /// Wall-clock execution time in microseconds.
  final int elapsedMicros;

  /// If [strategy] is [CloneStrategy.streamingFallback], the POSIX `errno`
  /// (`EXDEV`, `ENOTSUP`, `ENOSYS`) that triggered the fallback.
  final int? fallbackErrno;

  @override
  String toString() => 'ApfsCloneResult('
      'strategy: ${strategy.name}, '
      'elapsedMicros: $elapsedMicros, '
      'dst: $destinationPath'
      '${fallbackErrno != null ? ', fallbackErrno: $fallbackErrno' : ''})';
}

/// Signature for an injectable `clonefile(2)` syscall used in Tier 2
/// fault-injection tests.
typedef ClonefileSyscallHook = int Function(
  String sourcePath,
  String destinationPath,
  int flags,
);

/// {@template extension_bridge.apfs_file_cloner}
/// Zero-copy APFS `clonefile(2)` media staging engine with atomic `rename(2)`
/// placement and automatic cross-volume streaming fallback.
///
/// ### Why `clonefile(src, dst, CLONE_NOOWNERCOPY)`?
/// iOS Share and Widget Extensions run under a strict **16–30 MB Jetsam RAM
/// ceiling**. Cloning a 200 MB 4K video via Darwin's `clonefile(2)` creates a
/// Copy-on-Write APFS inode sharing the same physical data extents in
/// **~0.3 ms** with **0 bytes of additional disk usage** and **< 50 KB of RAM**.
/// Passing [ClonefileFlags.noOwnerCopy] prevents `EPERM` when cloning across
/// extension temporary directories and the shared App Group container.
/// {@endtemplate}
final class ApfsFileCloner {
  /// {@macro extension_bridge.apfs_file_cloner}
  ApfsFileCloner({
    DarwinPosixFfi? posix,
    ClonefileSyscallHook? clonefileOverride,
    this.chunkSizeBytes = 64 * 1024,
  })  : _posix = posix ?? DarwinPosixFfi.instance,
        _clonefileOverride = clonefileOverride;

  final DarwinPosixFfi _posix;
  final ClonefileSyscallHook? _clonefileOverride;

  /// Buffer size in bytes (`64 KB` by default) used when falling back to a
  /// chunked streaming copy on `EXDEV` / `ENOTSUP`.
  final int chunkSizeBytes;

  static int _stagingCounter = 0;
  static final math.Random _random = math.Random();

  /// Synchronously clones [sourcePath] to [destinationPath] using APFS
  /// `clonefile(2)` (`CLONE_NOOWNERCOPY`), falling back to a chunked streaming
  /// copy if `clonefile(2)` returns `EXDEV`, `ENOTSUP`, or `ENOSYS`.
  ///
  /// The file is staged to a hidden sibling `.tmp` path and committed via
  /// atomic POSIX `rename(2)` so readers of [destinationPath] never observe a
  /// partially written file.
  ApfsCloneResult cloneFileSync({
    required String sourcePath,
    required String destinationPath,
    int flags = ClonefileFlags.noOwnerCopy,
  }) {
    final stopwatch = Stopwatch()..start();
    final sourceFile = File(sourcePath);
    if (!sourceFile.existsSync()) {
      throw AttachmentCloneException(
        'Source attachment file does not exist: "$sourcePath"',
        sourcePath: sourcePath,
        destinationPath: destinationPath,
        errno: DarwinErrno.enoent,
      );
    }

    final parentDir = Directory(p.dirname(destinationPath));
    if (!parentDir.existsSync()) {
      parentDir.createSync(recursive: true);
    }

    final stagingPath = _buildStagingPath(destinationPath);
    final syscall = _clonefileOverride ??
        (String src, String dst, int f) => _posix.clonefile(src, dst, flags: f);

    final errno = syscall(sourcePath, stagingPath, flags);
    if (errno == 0) {
      final renameErr = _posix.rename(stagingPath, destinationPath);
      if (renameErr != 0) {
        _posix.unlink(stagingPath);
        throw AttachmentCloneException(
          'Atomic rename after clonefile(2) failed with errno $renameErr',
          sourcePath: sourcePath,
          destinationPath: destinationPath,
          errno: renameErr,
        );
      }
      stopwatch.stop();
      return ApfsCloneResult(
        sourcePath: sourcePath,
        destinationPath: destinationPath,
        strategy: CloneStrategy.apfsClonefile,
        elapsedMicros: stopwatch.elapsedMicroseconds,
      );
    }

    // Ensure any partial staging artifact is removed before fallback.
    _posix.unlink(stagingPath);

    if (!_shouldFallbackToStreaming(errno)) {
      throw AttachmentCloneException(
        'APFS clonefile(2) failed with unrecoverable errno $errno',
        sourcePath: sourcePath,
        destinationPath: destinationPath,
        errno: errno,
      );
    }

    _streamCopySync(
      sourceFile: sourceFile,
      stagingPath: stagingPath,
      destinationPath: destinationPath,
    );
    stopwatch.stop();
    return ApfsCloneResult(
      sourcePath: sourcePath,
      destinationPath: destinationPath,
      strategy: CloneStrategy.streamingFallback,
      elapsedMicros: stopwatch.elapsedMicroseconds,
      fallbackErrno: errno,
    );
  }

  /// Asynchronously clones [sourcePath] to [destinationPath] using APFS
  /// `clonefile(2)` (`CLONE_NOOWNERCOPY`), or a chunked streaming fallback on
  /// cross-volume `EXDEV` / `ENOTSUP`.
  Future<ApfsCloneResult> cloneFile({
    required String sourcePath,
    required String destinationPath,
    int flags = ClonefileFlags.noOwnerCopy,
  }) async =>
      cloneFileSync(
        sourcePath: sourcePath,
        destinationPath: destinationPath,
        flags: flags,
      );

  static bool _shouldFallbackToStreaming(int errno) =>
      errno == DarwinErrno.exdev ||
      errno == DarwinErrno.enotsup ||
      errno == DarwinErrno.enosys;

  String _buildStagingPath(String destinationPath) {
    final dir = p.dirname(destinationPath);
    final base = p.basename(destinationPath);
    final seq = ++_stagingCounter;
    final nonce = _random.nextInt(0x7FFFFFFF).toRadixString(16);
    return p.join(dir, '.$base.tmp.$seq.$nonce');
  }

  void _streamCopySync({
    required File sourceFile,
    required String stagingPath,
    required String destinationPath,
  }) {
    RandomAccessFile? reader;
    RandomAccessFile? writer;
    try {
      reader = sourceFile.openSync();
      writer = File(stagingPath).openSync(mode: FileMode.writeOnly);
      final buffer = Uint8List(chunkSizeBytes);
      while (true) {
        final bytesRead = reader.readIntoSync(buffer);
        if (bytesRead <= 0) break;
        writer.writeFromSync(buffer, 0, bytesRead);
      }
      writer.flushSync();
      writer.closeSync();
      writer = null;
      reader.closeSync();
      reader = null;

      final renameErr = _posix.rename(stagingPath, destinationPath);
      if (renameErr != 0) {
        _posix.unlink(stagingPath);
        throw AttachmentCloneException(
          'Atomic rename after streaming fallback failed with errno $renameErr',
          sourcePath: sourceFile.path,
          destinationPath: destinationPath,
          errno: renameErr,
        );
      }
    } on AttachmentCloneException {
      rethrow;
    } on Object catch (error) {
      writer?.closeSync();
      reader?.closeSync();
      _posix.unlink(stagingPath);
      throw AttachmentCloneException(
        'Streaming copy fallback failed: $error',
        sourcePath: sourceFile.path,
        destinationPath: destinationPath,
      );
    }
  }
}
