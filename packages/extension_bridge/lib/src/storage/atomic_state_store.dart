import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import '../ffi/darwin_notification_bus.dart';
import '../ffi/darwin_posix_ffi.dart';
import '../ffi/extension_kit_hooks.dart';
import '../lifecycle/darwin_lifecycle_observer.dart';
import '../protocol/bridge_exception.dart';
import '../protocol/cas_lease_token.dart';
import '../protocol/state_envelope.dart';
import 'container_layout.dart';
import 'shared_attachment_manager.dart';
import 'snapshot_result.dart';

/// Fault-injection hook invoked after `.tmp` staging is flushed to disk, just
/// before attempting to acquire the `.cas` symlink lease.
typedef BeforeCasAcquireHook = void Function(int attempt, String stagingPath);

/// Fault-injection hook invoked immediately after acquiring the `.cas` symlink
/// lease, before verifying `_gen == expectedGen` and committing `rename(2)`.
typedef AfterCasAcquireHook = void Function(
  int attempt,
  CasLeaseToken leaseToken,
  String casPath,
);

/// Fault-injection hook invoked after `_gen == expectedGen` is verified, right
/// before the final ownership check and `rename(2)` commit.
typedef BeforeRenameCommitHook = void Function(
  int attempt,
  CasLeaseToken leaseToken,
  String casPath,
);

/// {@template extension_bridge.atomic_state_store}
/// `0xdead10cc`-proof, lock-free atomic snapshot store and optimistic
/// concurrency control (CAS) engine for `@SharedState`.
///
/// ### Architectural Guarantees
/// 1. **Zero Kernel File Locks (`0xdead10cc`-Proof):**
///    Never invokes `flock(2)`, `fcntl(2)`, SQLite WAL locks, or
///    `NSFileCoordinator`. Readers open and read immutable snapshot files with
///    zero locks; writers serialize to `.tmp` out-of-band and atomically swap
///    the directory entry via POSIX `rename(2)`.
/// 2. **Two-Stage `~299 ns` Shared-Memory Read Fast Path:**
///    - **Stage 1:** Calls `notify_check` (~299 ns `notifyd` process-mapped
///      shared-memory slot, zero Mach IPC). If unchanged, returns the cached
///      model in memory immediately.
///    - **Stage 2:** If `notify_check` reports a post, calls `notify_get_state`
///      (~9.3 µs Mach IPC) and only reads APFS if `reg.generation > localGen`
///      (or if the register is unseeded `0x0` on cold start).
/// 3. **Zero-FD Symlink CAS Loop with Instant `ESRCH` Dead-PID Recovery:**
///    Both [write] and [update] acquire a short-lived POSIX symlink lease
///    (`symlink("<pid>:<ts_us>:<nonce>", ".<key>.v<ver>.cas")`). If a previous
///    extension process was terminated mid-write (`SIGKILL` or Jetsam OOM),
///    contenders probe `kill(holderPid, 0) == ESRCH` and evict the orphaned
///    lease in **< 1 ms**. Every `rename(2)` and `unlink(2)` is guarded by
///    owner-token verification (`readlink(".cas") == myLease`) to prevent
///    split-brain overwrites.
/// {@endtemplate}
final class AtomicStateStore<T> {
  /// {@macro extension_bridge.atomic_state_store}
  AtomicStateStore({
    required this.key,
    required this.layout,
    required this.codec,
    required this.notificationBus,
    required this.notificationName,
    this.schemaVersion = 1,
    SharedAttachmentManager? attachmentManager,
    DarwinPosixFfi? posix,
    DarwinLifecycleObserver? lifecycleObserver,
    ExtensionKitHooks? extensionKitHooks,
    this.reloadWidgets,
    this.reloadControls,
    this.stageAttachments,
    this.resolveAttachments,
    this.maxCasAttempts = 32,
    this.casLeaseCeilingMicros = kDefaultCasLeaseCeilingMicros,
    int Function()? clockMicros,
    this.onBeforeCasAcquire,
    this.onAfterCasAcquire,
    this.onBeforeRenameCommit,
  })  : assert(schemaVersion >= 1, 'schemaVersion must be >= 1'),
        assert(maxCasAttempts >= 1, 'maxCasAttempts must be >= 1'),
        _posix = posix ?? DarwinPosixFfi.instance,
        _attachmentManager =
            attachmentManager ?? SharedAttachmentManager(layout: layout),
        _lifecycleObserver = lifecycleObserver,
        _extensionKitHooks = extensionKitHooks ?? ExtensionKitHooks.instance,
        _clockMicros =
            clockMicros ?? (() => DateTime.now().microsecondsSinceEpoch) {
    _pid = _posix.getpid();
  }

  /// Logical `@SharedState` key (e.g., `'now_playing'`).
  final String key;

  /// On-disk container directory layout.
  final ContainerLayout layout;

  /// JSON envelope codec for model type [T].
  final StateEnvelopeCodec<T> codec;

  /// Darwin `<notify.h>` notification bus.
  final DarwinNotificationBus notificationBus;

  /// Full Darwin `<notify.h>` notification name for this state key.
  final String notificationName;

  /// Schema version integer (`_schema_version`).
  final int schemaVersion;

  /// Optional list of `WidgetKit` widget `kind` identifiers to reload on write.
  final List<String>? reloadWidgets;

  /// Optional list of iOS 18 `ControlWidget` `kind` identifiers to reload on
  /// write.
  final List<String>? reloadControls;

  /// Optional callback that stages `@SharedAttachment` files on [T] before
  /// encoding.
  final StateAttachmentStager<T>? stageAttachments;

  /// Optional callback that resolves relative `blobs/...` paths on [T] after
  /// decoding.
  final AttachmentPathResolver<T>? resolveAttachments;

  /// Maximum number of optimistic CAS attempts before throwing
  /// [CasContentionException].
  final int maxCasAttempts;

  /// Maximum age in microseconds (`2,000,000` us = 2,000 ms by default) of a
  /// live `.cas` symlink lease before contenders treat it as expired.
  final int casLeaseCeilingMicros;

  /// Optional Tier 2 fault-injection hook invoked before acquiring `.cas`.
  final BeforeCasAcquireHook? onBeforeCasAcquire;

  /// Optional Tier 2 fault-injection hook invoked after acquiring `.cas`.
  final AfterCasAcquireHook? onAfterCasAcquire;

  /// Optional Tier 2 fault-injection hook invoked just before `rename(2)`.
  final BeforeRenameCommitHook? onBeforeRenameCommit;

  final DarwinPosixFfi _posix;
  final SharedAttachmentManager _attachmentManager;
  final DarwinLifecycleObserver? _lifecycleObserver;
  final ExtensionKitHooks _extensionKitHooks;
  final int Function() _clockMicros;
  final math.Random _random = math.Random();

  late final int _pid;
  int _nonceSeq = 0;

  StateEnvelope<T>? _cachedEnvelope;
  T? _cachedResolvedValue;

  StreamController<T>? _watchController;
  StreamSubscription<DarwinStateWakeupEvent>? _busSubscription;
  StreamSubscription<String>? _lifecycleSubscription;
  int _lastEmittedGeneration = -1;
  bool _isDisposed = false;

  int _memoryCacheHits = 0;
  int _diskSnapshotReads = 0;
  int _casCommitCount = 0;
  int _casRetryCount = 0;
  int _evictedDeadPidLeaseCount = 0;
  int _evictedExpiredLeaseCount = 0;
  int _splitBrainPreventedCount = 0;

  /// Attachment manager associated with this store.
  SharedAttachmentManager get attachmentManager => _attachmentManager;

  /// Number of [read] / [readResult] calls served from memory via the
  /// `<notify.h>` fast path with zero disk I/O.
  int get memoryCacheHits => _memoryCacheHits;

  /// Number of [read] / [readResult] calls that read and decoded the APFS
  /// snapshot file from disk.
  int get diskSnapshotReads => _diskSnapshotReads;

  /// Total number of committed [write] / [update] operations.
  int get casCommitCount => _casCommitCount;

  /// Total number of optimistic CAS retries triggered by concurrent contention.
  int get casRetryCount => _casRetryCount;

  /// Number of orphaned `.cas` symlink leases evicted immediately (< 1 ms) via
  /// `kill(pid, 0) == ESRCH` dead-process detection.
  int get evictedDeadPidLeaseCount => _evictedDeadPidLeaseCount;

  /// Number of stale `.cas` symlink leases evicted after exceeding
  /// [casLeaseCeilingMicros].
  int get evictedExpiredLeaseCount => _evictedExpiredLeaseCount;

  /// Number of split-brain overwrites prevented by owner-token verification
  /// (`readlink(".cas") == myLease`).
  int get splitBrainPreventedCount => _splitBrainPreventedCount;

  /// Canonical file path of the active immutable snapshot
  /// (`state/<key>.v<schemaVersion>.json`).
  String get snapshotFilePath =>
      layout.stateSnapshotPath(key, schemaVersion: schemaVersion);

  /// Canonical file path of the `.cas` symlink lease
  /// (`state/.<key>.v<schemaVersion>.cas`).
  String get casLeaseFilePath =>
      layout.stateCasLeasePath(key, schemaVersion: schemaVersion);

  /// Atomically reads the latest [T] snapshot, or returns `null` if no state
  /// has been written yet.
  ///
  /// - **Fast Path (Cache Hit):** ~299 ns via `<notify.h>` `notify_check`
  ///   shared-memory slot (zero Mach IPC, zero disk I/O).
  /// - **Slow Path (Cache Miss):** ~9.3 µs `notify_get_state` check + lock-free
  ///   APFS snapshot read.
  T? read() => readResult().valueOrNull;

  /// Atomically reads the latest snapshot as an exhaustive sealed
  /// [SnapshotResult] ([SnapshotHit] or [SnapshotEmpty]).
  SnapshotResult<T> readResult() {
    _checkNotDisposed();
    final cachedEnv = _cachedEnvelope;
    final cachedVal = _cachedResolvedValue;

    if (cachedEnv != null && cachedVal != null) {
      final changed = notificationBus.checkChanged(notificationName);
      if (!changed) {
        _memoryCacheHits += 1;
        return SnapshotHit<T>(
          value: cachedVal,
          envelope: cachedEnv,
          fromMemoryCache: true,
        );
      }

      final reg = notificationBus.getRegister(notificationName);
      if (reg.hasValidMagic &&
          reg.generation <= (cachedEnv.generation & 0xFFFFFFFF)) {
        _memoryCacheHits += 1;
        return SnapshotHit<T>(
          value: cachedVal,
          envelope: cachedEnv,
          fromMemoryCache: true,
        );
      }
    } else {
      // Ensure the check token is registered and its initial sentinel consumed
      // before reading from disk so subsequent fast-path reads work immediately.
      notificationBus.checkChanged(notificationName);
    }

    final diskEnv = _readDiskEnvelope();
    if (diskEnv == null) {
      _cachedEnvelope = null;
      _cachedResolvedValue = null;
      return SnapshotEmpty<T>();
    }

    _diskSnapshotReads += 1;
    final resolved = _resolvePayload(diskEnv.payload);
    _cachedEnvelope = diskEnv;
    _cachedResolvedValue = resolved;

    notificationBus.recordLocalGeneration(
      notificationName,
      diskEnv.generation,
    );
    notificationBus.seedStateIfUnseeded(
      notificationName,
      authoritativeGeneration: diskEnv.generation,
      seedWriterId: diskEnv.writerId,
    );

    return SnapshotHit<T>(
      value: resolved,
      envelope: diskEnv,
      fromMemoryCache: false,
    );
  }

  /// Writes [newValue] atomically using the lock-free CAS protocol.
  ///
  /// Equivalent to calling `update((_) => newValue)`.
  StateEnvelope<T> write(T newValue) => update((_) => newValue);

  /// Executes a lock-free optimistic concurrency control (CAS) transaction that
  /// reads the current snapshot (`T?`), applies the pure [mutator] closure, and
  /// atomically commits `expectedGen + 1`.
  ///
  /// If another process or isolate commits a new generation while [mutator] or
  /// `.tmp` serialization is in flight, [update] automatically rolls back its
  /// staging artifacts and re-evaluates [mutator] against the newer snapshot.
  StateEnvelope<T> update(T Function(T? current) mutator) {
    _checkNotDisposed();
    layout.ensureBaseDirectoriesSync();

    // Ensure check token is initialized before writing.
    notificationBus.checkChanged(notificationName);

    int? lastObservedHolderPid;

    for (var attempt = 1; attempt <= maxCasAttempts; attempt++) {
      // Step 1: Read the current authoritative snapshot from APFS.
      final diskEnv = _readDiskEnvelope();
      final expectedGen = diskEnv?.generation ?? 0;
      final currentResolved =
          diskEnv == null ? null : _resolvePayload(diskEnv.payload);

      // Step 2: Run the pure mutator closure out-of-band.
      final nextResolvedValue = mutator(currentResolved);
      final nextGen = expectedGen + 1;

      // Step 3: Stage any @SharedAttachment blobs & serialize .tmp out-of-band
      // BEFORE acquiring the .cas symlink lease.
      final T payloadToEncode;
      final List<String> stagedBlobPaths;
      if (stageAttachments != null) {
        final staged = stageAttachments!(
          value: nextResolvedValue,
          generation: nextGen,
          manager: _attachmentManager,
        );
        payloadToEncode = staged.stagedValue;
        stagedBlobPaths = staged.relativeBlobPaths;
      } else {
        payloadToEncode = nextResolvedValue;
        stagedBlobPaths = const <String>[];
      }

      final nowMicros = _clockMicros();
      final envelope = StateEnvelope<T>(
        schemaVersion: schemaVersion,
        generation: nextGen,
        updatedAtMicros: nowMicros,
        writerId: notificationBus.writerId,
        payload: payloadToEncode,
        attachments: stagedBlobPaths,
      );

      final nonce = _nextAttemptNonce(nowMicros);
      final stagingPath = layout.stateStagingPath(
        key,
        schemaVersion: schemaVersion,
        nonce: nonce,
      );

      _writeAndFlushStagingSync(stagingPath, codec.encodeToBytes(envelope));

      try {
        onBeforeCasAcquire?.call(attempt, stagingPath);
      } on Object {
        _posix.unlink(stagingPath);
        _attachmentManager.unlinkBlobs(stagedBlobPaths);
        rethrow;
      }

      // Step 4: Acquire zero-FD atomic .cas symlink lease.
      final myLease = CasLeaseToken(
        pid: _pid,
        acquiredAtMicros: _clockMicros(),
        nonce: nonce,
      );
      final casPath = casLeaseFilePath;
      final leaseOutcome = _tryAcquireCasLease(casPath, myLease);
      if (!leaseOutcome.acquired) {
        lastObservedHolderPid = leaseOutcome.holderPid;
        _posix.unlink(stagingPath);
        _attachmentManager.unlinkBlobs(stagedBlobPaths);
        _casRetryCount += 1;
        continue;
      }

      try {
        onAfterCasAcquire?.call(attempt, myLease, casPath);
      } on Object {
        _releaseCasLeaseIfOwned(casPath, myLease);
        _posix.unlink(stagingPath);
        _attachmentManager.unlinkBlobs(stagedBlobPaths);
        rethrow;
      }

      // Step 5: Verify _gen == expectedGen while holding .cas.
      final currentDiskGen = _readDiskGeneration();
      if (currentDiskGen != expectedGen) {
        _releaseCasLeaseIfOwned(casPath, myLease);
        _posix.unlink(stagingPath);
        _attachmentManager.unlinkBlobs(stagedBlobPaths);
        _casRetryCount += 1;
        continue;
      }

      // Step 6: Split-Brain Immunity — verify we still own the .cas symlink.
      if (!_ownsCasLease(casPath, myLease)) {
        _posix.unlink(stagingPath);
        _attachmentManager.unlinkBlobs(stagedBlobPaths);
        _splitBrainPreventedCount += 1;
        _casRetryCount += 1;
        continue;
      }

      if (onBeforeRenameCommit != null) {
        try {
          onBeforeRenameCommit!(attempt, myLease, casPath);
        } on Object {
          _releaseCasLeaseIfOwned(casPath, myLease);
          _posix.unlink(stagingPath);
          _attachmentManager.unlinkBlobs(stagedBlobPaths);
          rethrow;
        }
        if (!_ownsCasLease(casPath, myLease)) {
          _posix.unlink(stagingPath);
          _attachmentManager.unlinkBlobs(stagedBlobPaths);
          _splitBrainPreventedCount += 1;
          _casRetryCount += 1;
          continue;
        }
      }

      // Step 7: Atomic POSIX rename(2) over the active snapshot & lease release.
      final renameErr = _posix.rename(stagingPath, snapshotFilePath);
      _releaseCasLeaseIfOwned(casPath, myLease);

      if (renameErr != 0) {
        _posix.unlink(stagingPath);
        _attachmentManager.unlinkBlobs(stagedBlobPaths);
        throw StorageIoException(
          'Atomic rename(2) failed while committing state "$key" '
          '(errno: $renameErr)',
          path: snapshotFilePath,
          errno: renameErr,
        );
      }

      // Step 8: Update local memory cache, broadcast <notify.h> state register,
      // consume our own shm check bit, GC stale blobs/staging files, and
      // trigger WidgetKit/ControlCenter reloads.
      final resolvedFinal = _resolvePayload(envelope.payload);
      _cachedEnvelope = envelope;
      _cachedResolvedValue = resolvedFinal;
      _lastEmittedGeneration = nextGen;
      _casCommitCount += 1;

      notificationBus.publishState(notificationName, generation: nextGen);
      // Consume the shm check bit caused by our own notify_post so the next
      // local read() hits the ~299 ns fast path.
      notificationBus.checkChanged(notificationName);

      _attachmentManager.gcStaleStateBlobs(
        stateKey: key,
        currentGeneration: nextGen,
      );
      sweepOrphanedStagingFiles();

      _triggerExtensionReloads();

      return envelope;
    }

    throw CasContentionException(
      key: key,
      attempts: maxCasAttempts,
      lastHolderPid: lastObservedHolderPid,
    );
  }

  /// Subscribes to cross-process mutations on [key], emitting the decoded [T]
  /// whenever a remote process (or another bridge instance with a distinct
  /// `writerId`) commits a newer generation, or when the application resumes to
  /// the foreground and [reconcile] detects an update.
  ///
  /// If [emitInitial] is `true` and a snapshot already exists on disk, the
  /// current value is emitted asynchronously to the returned stream upon
  /// subscription.
  Stream<T> watch({bool emitInitial = false}) {
    _checkNotDisposed();
    _watchController ??= StreamController<T>.broadcast(
      onListen: _startWatching,
      onCancel: _stopWatching,
    );
    final broadcastStream = _watchController!.stream;

    if (!emitInitial) {
      return broadcastStream;
    }

    return Stream<T>.multi((multi) {
      final current = read();
      if (current != null && !multi.isClosed) {
        multi.addSync(current);
      }
      final sub = broadcastStream.listen(
        multi.addSync,
        onError: multi.addErrorSync,
        onDone: multi.closeSync,
      );
      multi.onCancel = sub.cancel;
    });
  }

  /// Runs a foreground-resume reconciliation check against the authoritative
  /// APFS snapshot, updating the in-memory cache and emitting to [watch]
  /// listeners if a newer generation was committed while the process was
  /// suspended.
  ///
  /// Returns the updated [T] if a newer generation was reconciled, or `null`
  /// if the cached generation was already up to date.
  T? reconcile() {
    _checkNotDisposed();
    final previousGen = _cachedEnvelope?.generation ?? _lastEmittedGeneration;
    final diskEnv = _readDiskEnvelope();
    if (diskEnv == null) return null;

    if (diskEnv.generation > previousGen) {
      _diskSnapshotReads += 1;
      final resolved = _resolvePayload(diskEnv.payload);
      _cachedEnvelope = diskEnv;
      _cachedResolvedValue = resolved;
      _lastEmittedGeneration = diskEnv.generation;

      notificationBus.recordLocalGeneration(
        notificationName,
        diskEnv.generation,
      );
      notificationBus.seedStateIfUnseeded(
        notificationName,
        authoritativeGeneration: diskEnv.generation,
        seedWriterId: diskEnv.writerId,
      );
      notificationBus.checkChanged(notificationName);

      if (_watchController != null && _watchController!.hasListener) {
        _watchController!.add(resolved);
      }
      return resolved;
    }
    return null;
  }

  /// Sweeps orphaned `.tmp` staging files for [key] left behind by processes
  /// that were terminated (`SIGKILL` / Jetsam OOM) or exceeded
  /// [casLeaseCeilingMicros].
  ///
  /// Returns the number of unlinked `.tmp` files.
  int sweepOrphanedStagingFiles() {
    final stateDir = Directory(layout.stateDirectoryPath);
    if (!stateDir.existsSync()) return 0;

    final prefix = layout.stateStagingPrefix(key, schemaVersion: schemaVersion);
    final nowMicros = _clockMicros();
    var swept = 0;

    List<FileSystemEntity> entries;
    try {
      entries = stateDir.listSync(followLinks: false);
    } on FileSystemException {
      return 0;
    }

    for (final entry in entries) {
      final name = entry.uri.pathSegments.isEmpty
          ? ''
          : entry.uri.pathSegments.lastWhere(
              (s) => s.isNotEmpty,
              orElse: () => '',
            );
      if (!name.startsWith(prefix)) continue;

      final suffix = name.substring(prefix.length);
      final shouldEvict = _isStagingNonceOrphaned(suffix, nowMicros: nowMicros);
      if (shouldEvict && _posix.unlink(entry.path) == 0) {
        swept += 1;
      }
    }
    return swept;
  }

  /// Closes active [watch] streams and detaches lifecycle subscriptions.
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    await _stopWatching();
    await _watchController?.close();
    _watchController = null;
  }

  void _startWatching() {
    if (_isDisposed || _busSubscription != null) return;

    // Seed _lastEmittedGeneration from current cache if available.
    if (_cachedEnvelope != null && _lastEmittedGeneration < 0) {
      _lastEmittedGeneration = _cachedEnvelope!.generation;
    }

    _busSubscription =
        notificationBus.watchState(notificationName).listen((_) {
      _onRemoteWakeup();
    });

    final lifecycle = _lifecycleObserver;
    if (lifecycle != null) {
      _lifecycleSubscription = lifecycle.onDidBecomeActive.listen((_) {
        reconcile();
      });
    }
  }

  Future<void> _stopWatching() async {
    await _busSubscription?.cancel();
    _busSubscription = null;
    await _lifecycleSubscription?.cancel();
    _lifecycleSubscription = null;
  }

  void _onRemoteWakeup() {
    if (_isDisposed) return;
    final diskEnv = _readDiskEnvelope();
    if (diskEnv == null) return;

    if (diskEnv.generation <= _lastEmittedGeneration) {
      return;
    }

    _diskSnapshotReads += 1;
    final resolved = _resolvePayload(diskEnv.payload);
    _cachedEnvelope = diskEnv;
    _cachedResolvedValue = resolved;
    _lastEmittedGeneration = diskEnv.generation;

    notificationBus.recordLocalGeneration(
      notificationName,
      diskEnv.generation,
    );
    // Clear the check token's pending bit since we just read the latest state.
    notificationBus.checkChanged(notificationName);

    if (_watchController != null && _watchController!.hasListener) {
      _watchController!.add(resolved);
    }
  }

  StateEnvelope<T>? _readDiskEnvelope() {
    final file = File(snapshotFilePath);
    try {
      final bytes = file.readAsBytesSync();
      return codec.decodeFromBytes(bytes);
    } on PathNotFoundException {
      return null;
    } on FileSystemException catch (error) {
      if (!file.existsSync()) return null;
      throw StorageIoException(
        'Failed to read state snapshot "$key": $error',
        path: snapshotFilePath,
        cause: error,
      );
    }
  }

  int _readDiskGeneration() {
    final file = File(snapshotFilePath);
    try {
      final bytes = file.readAsBytesSync();
      return StateEnvelopeHeader.fromBytes(
        bytes,
        key: key,
        maxSupportedSchemaVersion: codec.maxSupportedSchemaVersion,
      ).generation;
    } on PathNotFoundException {
      return 0;
    } on FileSystemException catch (error) {
      if (!file.existsSync()) return 0;
      throw StorageIoException(
        'Failed to read state header "$key": $error',
        path: snapshotFilePath,
        cause: error,
      );
    }
  }

  T _resolvePayload(T rawPayload) {
    final resolver = resolveAttachments;
    if (resolver == null) return rawPayload;
    return resolver(rawPayload, _attachmentManager);
  }

  void _writeAndFlushStagingSync(String stagingPath, List<int> bytes) {
    RandomAccessFile? raf;
    try {
      raf = File(stagingPath).openSync(mode: FileMode.writeOnly);
      raf.writeFromSync(bytes);
      raf.flushSync();
      raf.closeSync();
      raf = null;
    } on Object catch (error) {
      raf?.closeSync();
      _posix.unlink(stagingPath);
      throw StorageIoException(
        'Failed to write and flush staging file for "$key": $error',
        path: stagingPath,
        cause: error,
      );
    }
  }

  ({bool acquired, int? holderPid}) _tryAcquireCasLease(
    String casPath,
    CasLeaseToken myLease,
  ) {
    final encoded = myLease.encode();
    final err = _posix.symlink(target: encoded, linkPath: casPath);
    if (err == 0) {
      return (acquired: true, holderPid: null);
    }
    if (err != DarwinErrno.eexist) {
      throw StorageIoException(
        'Failed to create .cas symlink lease for "$key" (errno: $err)',
        path: casPath,
        errno: err,
      );
    }

    // Contention detected: inspect the current lease holder.
    final holderRaw = _posix.readlink(casPath);
    if (holderRaw == null) {
      // The holder released the lease just after our symlink() returned EEXIST.
      final retryErr = _posix.symlink(target: encoded, linkPath: casPath);
      return (acquired: retryErr == 0, holderPid: null);
    }

    final holder = CasLeaseToken.tryParse(holderRaw);
    final nowMicros = _clockMicros();
    final isDeadProcess = holder == null || !_posix.isProcessAlive(holder.pid);
    final isExpired = !isDeadProcess &&
        holder.isExpired(
          nowMicros: nowMicros,
          ceilingMicros: casLeaseCeilingMicros,
        );

    if (isDeadProcess || isExpired) {
      // Owner-verified eviction: ensure the symlink still points to holderRaw
      // before unlinking so we never unlink a newly acquired third-party lease.
      if (_posix.readlink(casPath) == holderRaw) {
        if (_posix.unlink(casPath) == 0) {
          if (isDeadProcess) {
            _evictedDeadPidLeaseCount += 1;
          } else {
            _evictedExpiredLeaseCount += 1;
          }
        }
      }
      final retryErr = _posix.symlink(target: encoded, linkPath: casPath);
      if (retryErr == 0) {
        return (acquired: true, holderPid: null);
      }
    }

    return (acquired: false, holderPid: holder?.pid);
  }

  bool _ownsCasLease(String casPath, CasLeaseToken myLease) =>
      _posix.readlink(casPath) == myLease.encode();

  void _releaseCasLeaseIfOwned(String casPath, CasLeaseToken myLease) {
    if (_ownsCasLease(casPath, myLease)) {
      _posix.unlink(casPath);
    }
  }

  String _nextAttemptNonce(int nowMicros) {
    final seq = ++_nonceSeq;
    final rand = _random.nextInt(0x7FFFFFFF).toRadixString(16);
    return '${_pid}_${nowMicros}_${seq}_$rand';
  }

  bool _isStagingNonceOrphaned(String suffix, {required int nowMicros}) {
    final firstUnderscore = suffix.indexOf('_');
    if (firstUnderscore <= 0) return true;
    final secondUnderscore = suffix.indexOf('_', firstUnderscore + 1);
    if (secondUnderscore <= firstUnderscore + 1) return true;

    final pid = int.tryParse(suffix.substring(0, firstUnderscore), radix: 10);
    final ts = int.tryParse(
      suffix.substring(firstUnderscore + 1, secondUnderscore),
      radix: 10,
    );
    if (pid == null || ts == null) return true;

    if (!_posix.isProcessAlive(pid)) {
      return true;
    }
    return nowMicros - ts > casLeaseCeilingMicros;
  }

  void _triggerExtensionReloads() {
    final widgets = reloadWidgets;
    if (widgets != null && widgets.isNotEmpty) {
      for (final kind in widgets) {
        _extensionKitHooks.reloadWidgetTimelines(
          kind: kind == '*' ? null : kind,
        );
      }
    }

    final controls = reloadControls;
    if (controls != null && controls.isNotEmpty) {
      for (final kind in controls) {
        _extensionKitHooks.reloadControlWidgets(
          kind: kind == '*' ? null : kind,
        );
      }
    }
  }

  void _checkNotDisposed() {
    if (_isDisposed) {
      throw StateError('AtomicStateStore("$key") has already been disposed.');
    }
  }
}
