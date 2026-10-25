import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;

import '../ffi/darwin_notification_bus.dart';
import '../ffi/darwin_posix_ffi.dart';
import '../lifecycle/darwin_lifecycle_observer.dart';
import '../protocol/bridge_exception.dart';
import '../protocol/cas_lease_token.dart';
import '../protocol/hybrid_logical_clock.dart';
import '../protocol/state_envelope.dart';
import 'container_layout.dart';
import 'shared_attachment_manager.dart';

/// {@template extension_bridge.queue_enqueued_receipt}
/// Metadata receipt returned by [SharedQueueStore.enqueue] and
/// [SharedQueueStore.enqueueSync] when an item is atomically committed to
/// `queue/<key>/ready/`.
/// {@endtemplate}
@immutable
final class QueueEnqueuedReceipt<T> {
  /// {@macro extension_bridge.queue_enqueued_receipt}
  const QueueEnqueuedReceipt({
    required this.fileName,
    required this.itemId,
    required this.timestamp,
    required this.envelope,
  });

  /// HLC-ordered Maildir filename (`<17-digit-micros>_<4-hex-counter>_<itemId>.json`).
  final String fileName;

  /// Unique item identifier (`<pid>_<seq>_<nonce>`).
  final String itemId;

  /// Monotonic [HlcTimestamp] assigned to this queue entry.
  final HlcTimestamp timestamp;

  /// Committed [StateEnvelope] written to `ready/`.
  final StateEnvelope<T> envelope;

  @override
  String toString() =>
      'QueueEnqueuedReceipt(fileName: $fileName, gen: ${envelope.generation})';
}

/// {@template extension_bridge.queue_delivery}
/// Transactional handle for an item claimed from `queue/<key>/ready/` into
/// `queue/<key>/inflight/`.
///
/// The envelope file in `inflight/` and any associated `@SharedAttachment`
/// files in `blobs/` remain on disk until [ack] is called. If the consumer
/// process crashes or terminates before calling [ack], the next
/// [SharedQueueStore] startup automatically recovers the item from `inflight/`
/// back into `ready/` with [isRedelivery] set to `true`.
/// {@endtemplate}
final class QueueDelivery<T> {
  QueueDelivery._({
    required this.fileName,
    required this.itemId,
    required this.timestamp,
    required this.envelope,
    required this.value,
    required this.isRedelivery,
    required void Function() onAck,
    required void Function({required bool requeue}) onNack,
  })  : _onAck = onAck,
        _onNack = onNack;

  /// HLC-ordered Maildir filename (`<17-digit-micros>_<4-hex-counter>_<itemId>.json`).
  final String fileName;

  /// Unique identifier for this queue item.
  final String itemId;

  /// Hybrid Logical Clock timestamp parsed from [fileName].
  final HlcTimestamp timestamp;

  /// Decoded wire envelope from `inflight/<fileName>`.
  final StateEnvelope<T> envelope;

  /// Decoded payload model with `@SharedAttachment` paths resolved to absolute
  /// filesystem paths inside the App Group container.
  final T value;

  /// Whether this item was recovered from `inflight/` after a prior unacknowledged
  /// consumer session.
  final bool isRedelivery;

  final void Function() _onAck;
  final void Function({required bool requeue}) _onNack;
  bool _isSettled = false;

  /// Whether [ack] or [nack] has already been called on this delivery.
  bool get isSettled => _isSettled;

  /// Acknowledges successful processing of [value], unlinking
  /// `inflight/<fileName>` and deleting all associated `@SharedAttachment`
  /// files in `blobs/`.
  void ack() {
    if (_isSettled) return;
    _isSettled = true;
    _onAck();
  }

  /// Negatively acknowledges this delivery.
  ///
  /// - When [requeue] is `true` (default), atomically moves
  ///   `inflight/<fileName>` back to `ready/<fileName>` (preserving its HLC
  ///   position and keeping its attachment blobs intact).
  /// - When [requeue] is `false`, discards the item and unlinks its attachment
  ///   blobs.
  void nack({bool requeue = true}) {
    if (_isSettled) return;
    _isSettled = true;
    _onNack(requeue: requeue);
  }
}

/// {@template extension_bridge.shared_queue_store}
/// Lock-free, multi-producer Maildir queue (`tmp/` → `ready/` → `inflight/`)
/// ordered by a Hybrid Logical Clock ([HybridLogicalClock]) with zero-copy APFS
/// `clonefile(2)` attachments.
///
/// ### Why a Maildir Queue Instead of a JSON Array?
/// iOS Share Extensions and Interactive Widgets operate under a strict
/// **16–30 MB Jetsam RAM ceiling**. Appending to a shared JSON array in
/// `UserDefaults` or a single file causes both write contention and
/// `EXC_RESOURCE (MEMORY)` crashes as the queue grows.
///
/// With [SharedQueueStore]:
/// 1. Each producer writes an independent `<hlc_ts>_<uuid>.json` file into
///    `tmp/` and atomically `rename(2)`s it into `ready/` with **zero locks**
///    and **O(1) memory**.
/// 2. Media attachments are cloned into `blobs/` via `clonefile(src, dst, CLONE_NOOWNERCOPY)`
///    (~0.3 ms, 0 extra disk bytes).
/// 3. The consumer claims items by atomically `rename(2)`ing them from `ready/`
///    to `inflight/`, and only unlinks the envelope + blobs when [QueueDelivery.ack]
///    is invoked.
/// {@endtemplate}
final class SharedQueueStore<T> {
  /// {@macro extension_bridge.shared_queue_store}
  SharedQueueStore({
    required this.queueKey,
    required this.layout,
    required this.codec,
    required this.notificationBus,
    required this.notificationName,
    this.schemaVersion = 1,
    this.maxItems = 256,
    SharedAttachmentManager? attachmentManager,
    HybridLogicalClock? clock,
    DarwinPosixFfi? posix,
    DarwinLifecycleObserver? lifecycleObserver,
    this.stageAttachments,
    this.resolveAttachments,
    this.staleTmpCeilingMicros = kDefaultCasLeaseCeilingMicros,
  })  : assert(schemaVersion >= 1, 'schemaVersion must be >= 1'),
        assert(maxItems >= 1, 'maxItems must be >= 1'),
        _posix = posix ?? DarwinPosixFfi.instance,
        _attachmentManager =
            attachmentManager ?? SharedAttachmentManager(layout: layout),
        _hlc = clock ?? HybridLogicalClock(writerId: notificationBus.writerId),
        _lifecycleObserver = lifecycleObserver {
    _pid = _posix.getpid();
  }

  /// Logical queue directory key (`queue/<queueKey>/`).
  final String queueKey;

  /// On-disk container layout.
  final ContainerLayout layout;

  /// Envelope JSON codec for item type [T].
  final StateEnvelopeCodec<T> codec;

  /// Darwin `<notify.h>` notification bus.
  final DarwinNotificationBus notificationBus;

  /// Full `<notify.h>` notification channel name for this queue.
  final String notificationName;

  /// Schema version integer (`_schema_version`).
  final int schemaVersion;

  /// Maximum number of pending items retained in `ready/` before oldest-item
  /// eviction applies.
  final int maxItems;

  /// Optional callback that stages `@SharedAttachment` fields on [T] before
  /// enqueueing.
  final QueueAttachmentStager<T>? stageAttachments;

  /// Optional callback that resolves container-relative `blobs/...` paths on
  /// [T] when claiming a delivery.
  final AttachmentPathResolver<T>? resolveAttachments;

  /// Maximum age in microseconds before an uncommitted file in `tmp/` from a
  /// live PID is treated as orphaned.
  final int staleTmpCeilingMicros;

  final DarwinPosixFfi _posix;
  final SharedAttachmentManager _attachmentManager;
  final HybridLogicalClock _hlc;
  final DarwinLifecycleObserver? _lifecycleObserver;
  final math.Random _random = math.Random();

  late final int _pid;
  int _enqueueSeq = 0;
  int _wakeupGeneration = 0;
  bool _hasRunStartupRecovery = false;
  bool _isDisposed = false;

  final Set<String> _recoveredFileNames = <String>{};

  StreamController<QueueDelivery<T>>? _consumeController;
  StreamSubscription<DarwinStateWakeupEvent>? _busSubscription;
  StreamSubscription<String>? _lifecycleSubscription;

  int _enqueuedCount = 0;
  int _acknowledgedCount = 0;
  int _recoveredInflightCount = 0;
  int _evictedBackpressureCount = 0;

  /// Attachment manager used by this queue.
  SharedAttachmentManager get attachmentManager => _attachmentManager;

  /// Hybrid Logical Clock used to order items in this queue.
  HybridLogicalClock get clock => _hlc;

  /// Total number of items enqueued through this store instance.
  int get enqueuedCount => _enqueuedCount;

  /// Total number of deliveries acknowledged via [QueueDelivery.ack].
  int get acknowledgedCount => _acknowledgedCount;

  /// Total number of unacknowledged items recovered from `inflight/` back into
  /// `ready/`.
  int get recoveredInflightCount => _recoveredInflightCount;

  /// Total number of oldest `ready/` items evicted due to [maxItems]
  /// backpressure.
  int get evictedBackpressureCount => _evictedBackpressureCount;

  /// Path to `queue/<queueKey>/tmp`.
  String get tmpDirectoryPath => layout.queueTmpDirectoryPath(queueKey);

  /// Path to `queue/<queueKey>/ready`.
  String get readyDirectoryPath => layout.queueReadyDirectoryPath(queueKey);

  /// Path to `queue/<queueKey>/inflight`.
  String get inflightDirectoryPath =>
      layout.queueInflightDirectoryPath(queueKey);

  /// Returns the number of committed items currently waiting in `ready/`.
  int pendingReadyCountSync() => _listSortedJsonFilesSync(readyDirectoryPath).length;

  /// Returns the number of items currently claimed in `inflight/`.
  int inflightCountSync() =>
      _listSortedJsonFilesSync(inflightDirectoryPath).length;

  /// Synchronously enqueues [item] into `queue/<queueKey>/ready/` using a
  /// monotonic [HlcTimestamp], staging any `@SharedAttachment` blobs via
  /// APFS `clonefile(2)` and broadcasting a `<notify.h>` wakeup.
  QueueEnqueuedReceipt<T> enqueueSync(T item) {
    _checkNotDisposed();
    layout.ensureQueueDirectoriesSync(queueKey);

    final ts = _hlc.now();
    final seq = ++_enqueueSeq;
    final rand = _random.nextInt(0x7FFFFFFF).toRadixString(16);
    final itemId = '${_pid}_${seq}_$rand';
    final fileName = ts.toQueueFileName(itemId);

    final T payloadToEncode;
    final List<String> stagedBlobPaths;
    if (stageAttachments != null) {
      final staged = stageAttachments!(
        value: item,
        itemUuid: itemId,
        manager: _attachmentManager,
      );
      payloadToEncode = staged.stagedValue;
      stagedBlobPaths = staged.relativeBlobPaths;
    } else {
      payloadToEncode = item;
      stagedBlobPaths = const <String>[];
    }

    final envelope = StateEnvelope<T>(
      schemaVersion: schemaVersion,
      generation: seq,
      updatedAtMicros: ts.wallTimeMicros,
      writerId: notificationBus.writerId,
      payload: payloadToEncode,
      attachments: stagedBlobPaths,
    );

    final tmpPath = p.join(tmpDirectoryPath, fileName);
    final readyPath = p.join(readyDirectoryPath, fileName);

    _writeAndFlushEnvelopeSync(tmpPath, codec.encodeToBytes(envelope));

    // Enforce maxItems backpressure on ready/ before committing the new item.
    _enforceMaxItemsBackpressureSync();

    final renameErr = _posix.rename(tmpPath, readyPath);
    if (renameErr != 0) {
      _posix.unlink(tmpPath);
      _attachmentManager.unlinkBlobs(stagedBlobPaths);
      throw StorageIoException(
        'Atomic rename(2) from tmp/ to ready/ failed for queue "$queueKey" '
        '(errno: $renameErr)',
        path: readyPath,
        errno: renameErr,
      );
    }

    _enqueuedCount += 1;
    final wakeupGen = _nextWakeupGeneration();
    notificationBus.publishState(notificationName, generation: wakeupGen);

    return QueueEnqueuedReceipt<T>(
      fileName: fileName,
      itemId: itemId,
      timestamp: ts,
      envelope: envelope,
    );
  }

  /// Asynchronously enqueues [item] into `queue/<queueKey>/ready/`.
  Future<QueueEnqueuedReceipt<T>> enqueue(T item) async => enqueueSync(item);

  /// Recovers any unacknowledged items left in `queue/<key>/inflight/` from a
  /// prior crashed or terminated consumer session back into `ready/`
  /// (preserving their original HLC filenames and causal order), and sweeps
  /// orphaned staging files in `tmp/`.
  ///
  /// Returns the number of recovered `inflight/` items.
  int recoverInflightItems() {
    _checkNotDisposed();
    layout.ensureQueueDirectoriesSync(queueKey);
    _hasRunStartupRecovery = true;

    final inflightFiles = _listSortedJsonFilesSync(inflightDirectoryPath);
    var recovered = 0;

    for (final file in inflightFiles) {
      final fileName = p.basename(file.path);
      final readyPath = p.join(readyDirectoryPath, fileName);
      if (_posix.rename(file.path, readyPath) == 0) {
        _recoveredFileNames.add(fileName);
        recovered += 1;
        _recoveredInflightCount += 1;
      }
    }

    _sweepOrphanedTmpFilesSync();
    return recovered;
  }

  /// Atomically claims the oldest available item in `ready/`, moving it to
  /// `inflight/` and returning its [QueueDelivery] handle (or `null` if
  /// `ready/` is empty).
  QueueDelivery<T>? claimNextDeliverySync() {
    _checkNotDisposed();
    if (!_hasRunStartupRecovery) {
      recoverInflightItems();
    } else {
      layout.ensureQueueDirectoriesSync(queueKey);
    }

    final readyFiles = _listSortedJsonFilesSync(readyDirectoryPath);
    for (final readyFile in readyFiles) {
      final fileName = p.basename(readyFile.path);
      final inflightPath = p.join(inflightDirectoryPath, fileName);

      final renameErr = _posix.rename(readyFile.path, inflightPath);
      if (renameErr != 0) {
        // Another consumer claimed this item concurrently; try the next one.
        continue;
      }

      final StateEnvelope<T> envelope;
      try {
        final bytes = File(inflightPath).readAsBytesSync();
        envelope = codec.decodeFromBytes(bytes);
      } on ExtensionBridgeException {
        _posix.unlink(inflightPath);
        rethrow;
      } on Object catch (error) {
        _posix.unlink(inflightPath);
        throw StorageIoException(
          'Failed to read claimed queue envelope "$fileName": $error',
          path: inflightPath,
          cause: error,
        );
      }

      final ts = HlcTimestamp.tryParse(fileName) ??
          HlcTimestamp(
            wallTimeMicros: envelope.updatedAtMicros,
            logicalCounter: 0,
            writerId: envelope.writerId,
          );
      _hlc.receive(ts);

      final resolvedValue = _resolvePayload(envelope.payload);
      final itemId = _extractItemId(fileName);
      final wasRecovered = _recoveredFileNames.remove(fileName);

      return QueueDelivery<T>._(
        fileName: fileName,
        itemId: itemId,
        timestamp: ts,
        envelope: envelope,
        value: resolvedValue,
        isRedelivery: wasRecovered,
        onAck: () {
          _posix.unlink(inflightPath);
          _attachmentManager.unlinkBlobs(envelope.attachments);
          _acknowledgedCount += 1;
        },
        onNack: ({required bool requeue}) {
          if (requeue) {
            final targetReadyPath = p.join(readyDirectoryPath, fileName);
            _recoveredFileNames.add(fileName);
            _posix.rename(inflightPath, targetReadyPath);
          } else {
            _posix.unlink(inflightPath);
            _attachmentManager.unlinkBlobs(envelope.attachments);
          }
        },
      );
    }

    return null;
  }

  /// Claims all currently available items in `ready/` in strict HLC causal
  /// order, moving each to `inflight/`.
  List<QueueDelivery<T>> drainAvailableSync() {
    _checkNotDisposed();
    final deliveries = <QueueDelivery<T>>[];
    while (true) {
      final next = claimNextDeliverySync();
      if (next == null) break;
      deliveries.add(next);
    }
    return deliveries;
  }

  /// Processes all currently available items in `ready/` transactionally:
  /// claims each item into `inflight/`, awaits [handler], and calls
  /// [QueueDelivery.ack] only when [handler] completes normally (or
  /// `delivery.nack(requeue: true)` if [handler] throws).
  ///
  /// Returns the number of items successfully acknowledged.
  Future<int> processAvailable(
    FutureOr<void> Function(T item, QueueDelivery<T> delivery) handler,
  ) async {
    _checkNotDisposed();
    var processed = 0;
    while (true) {
      final delivery = claimNextDeliverySync();
      if (delivery == null) break;
      try {
        await handler(delivery.value, delivery);
        if (!delivery.isSettled) {
          delivery.ack();
        }
        processed += 1;
      } on Object {
        if (!delivery.isSettled) {
          delivery.nack(requeue: true);
        }
        rethrow;
      }
    }
    return processed;
  }

  /// Subscribes to a reactive stream of [QueueDelivery] items in strict HLC
  /// causal order.
  ///
  /// Upon subscription:
  /// 1. Runs [recoverInflightItems] to restore any unacknowledged items from a
  ///    prior crashed session.
  /// 2. Drains all items currently waiting in `ready/`.
  /// 3. Automatically drains newly enqueued items whenever a remote `<notify.h>`
  ///    wakeup arrives or the application resumes into the foreground.
  Stream<QueueDelivery<T>> consume() {
    _checkNotDisposed();
    return (_consumeController ??= StreamController<QueueDelivery<T>>.broadcast(
      onListen: _startConsuming,
      onCancel: _stopConsuming,
    ))
        .stream;
  }

  /// Closes active [consume] streams and detaches notification/lifecycle
  /// listeners.
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    await _stopConsuming();
    await _consumeController?.close();
    _consumeController = null;
  }

  void _startConsuming() {
    if (_isDisposed || _busSubscription != null) return;

    _busSubscription =
        notificationBus.watchState(notificationName).listen((_) {
      _drainToStream();
    });

    final lifecycle = _lifecycleObserver;
    if (lifecycle != null) {
      _lifecycleSubscription = lifecycle.onDidBecomeActive.listen((_) {
        _drainToStream();
      });
    }

    // Drain any items already waiting in ready/ (or recovered from inflight/)
    // on a microtask so the caller's stream listener is attached first.
    scheduleMicrotask(_drainToStream);
  }

  Future<void> _stopConsuming() async {
    await _busSubscription?.cancel();
    _busSubscription = null;
    await _lifecycleSubscription?.cancel();
    _lifecycleSubscription = null;
  }

  void _drainToStream() {
    if (_isDisposed) return;
    final controller = _consumeController;
    if (controller == null || !controller.hasListener) return;

    while (controller.hasListener && !_isDisposed) {
      final delivery = claimNextDeliverySync();
      if (delivery == null) break;
      controller.add(delivery);
    }
  }

  void _enforceMaxItemsBackpressureSync() {
    final readyFiles = _listSortedJsonFilesSync(readyDirectoryPath);
    if (readyFiles.length < maxItems) return;

    final toEvictCount = readyFiles.length - maxItems + 1;
    for (var i = 0; i < toEvictCount; i++) {
      final victim = readyFiles[i];
      try {
        final bytes = victim.readAsBytesSync();
        final header = StateEnvelopeHeader.fromBytes(bytes, key: queueKey);
        if (_posix.unlink(victim.path) == 0) {
          _attachmentManager.unlinkBlobs(header.attachments);
          _evictedBackpressureCount += 1;
        }
      } on Object {
        if (_posix.unlink(victim.path) == 0) {
          _evictedBackpressureCount += 1;
        }
      }
    }
  }

  void _sweepOrphanedTmpFilesSync() {
    final tmpDir = Directory(tmpDirectoryPath);
    if (!tmpDir.existsSync()) return;

    final nowMicros = DateTime.now().microsecondsSinceEpoch;
    List<FileSystemEntity> entries;
    try {
      entries = tmpDir.listSync(followLinks: false);
    } on FileSystemException {
      return;
    }

    for (final entry in entries) {
      final fileName = p.basename(entry.path);
      final ts = HlcTimestamp.tryParse(fileName);
      final itemId = _extractItemId(fileName);
      final pidEnd = itemId.indexOf('_');
      final pid =
          pidEnd > 0 ? int.tryParse(itemId.substring(0, pidEnd), radix: 10) : null;

      final isDeadPid = pid == null || !_posix.isProcessAlive(pid);
      final isExpired =
          ts == null || (nowMicros - ts.wallTimeMicros > staleTmpCeilingMicros);

      if (isDeadPid || isExpired) {
        _posix.unlink(entry.path);
      }
    }
  }

  List<File> _listSortedJsonFilesSync(String dirPath) {
    final dir = Directory(dirPath);
    if (!dir.existsSync()) return const <File>[];

    List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } on FileSystemException {
      return const <File>[];
    }

    final files = <File>[];
    for (final entry in entries) {
      if (entry is File && entry.path.endsWith('.json')) {
        files.add(entry);
      }
    }
    files.sort((a, b) => p.basename(a.path).compareTo(p.basename(b.path)));
    return files;
  }

  void _writeAndFlushEnvelopeSync(String tmpPath, List<int> bytes) {
    RandomAccessFile? raf;
    try {
      raf = File(tmpPath).openSync(mode: FileMode.writeOnly);
      raf.writeFromSync(bytes);
      raf.flushSync();
      raf.closeSync();
      raf = null;
    } on Object catch (error) {
      raf?.closeSync();
      _posix.unlink(tmpPath);
      throw StorageIoException(
        'Failed to write queue staging file in "$queueKey": $error',
        path: tmpPath,
        cause: error,
      );
    }
  }

  T _resolvePayload(T rawPayload) {
    final resolver = resolveAttachments;
    if (resolver == null) return rawPayload;
    return resolver(rawPayload, _attachmentManager);
  }

  int _nextWakeupGeneration() {
    try {
      final reg = notificationBus.getRegister(notificationName);
      if (reg.hasValidMagic && reg.generation > _wakeupGeneration) {
        _wakeupGeneration = reg.generation;
      }
    } on DarwinNotificationException {
      // Fallback to local monotonic counter.
    }
    _wakeupGeneration = (_wakeupGeneration + 1) & 0xFFFFFFFF;
    if (_wakeupGeneration == 0) _wakeupGeneration = 1;
    return _wakeupGeneration;
  }

  static String _extractItemId(String fileName) {
    final withoutExt = fileName.endsWith('.json')
        ? fileName.substring(0, fileName.length - 5)
        : fileName;
    if (withoutExt.length > 23 && withoutExt.codeUnitAt(22) == 0x5F /* '_' */) {
      return withoutExt.substring(23);
    }
    return withoutExt;
  }

  void _checkNotDisposed() {
    if (_isDisposed) {
      throw StateError(
        'SharedQueueStore("$queueKey") has already been disposed.',
      );
    }
  }
}
