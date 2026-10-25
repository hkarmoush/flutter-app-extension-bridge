import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:extension_bridge/extension_bridge.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String _uniqueNotification(String label) {
  final rand = math.Random().nextInt(0x7FFFFFFF).toRadixString(16);
  final micros = DateTime.now().microsecondsSinceEpoch;
  return 'dev.extension_bridge.test.state.$label.$micros.$rand';
}

final class _TrackModel {
  const _TrackModel({
    required this.title,
    required this.playCount,
    this.artworkPath,
  });

  final String title;
  final int playCount;
  final String? artworkPath;

  _TrackModel copyWith({
    String? title,
    int? playCount,
    String? artworkPath,
  }) =>
      _TrackModel(
        title: title ?? this.title,
        playCount: playCount ?? this.playCount,
        artworkPath: artworkPath ?? this.artworkPath,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'title': title,
        'playCount': playCount,
        if (artworkPath != null) 'artworkPath': artworkPath,
      };

  static _TrackModel fromJson(Object? raw) {
    final map = Map<String, Object?>.from(raw! as Map);
    return _TrackModel(
      title: map['title']! as String,
      playCount: map['playCount']! as int,
      artworkPath: map['artworkPath'] as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _TrackModel &&
          other.title == title &&
          other.playCount == playCount &&
          other.artworkPath == artworkPath;

  @override
  int get hashCode => Object.hash(title, playCount, artworkPath);

  @override
  String toString() =>
      '_TrackModel(title: $title, playCount: $playCount, artwork: $artworkPath)';
}

final _trackCodec = StateEnvelopeCodec<_TrackModel>(
  key: 'now_playing',
  encodePayload: (model) => model.toJson(),
  decodePayload: _TrackModel.fromJson,
);

final _intCodec = StateEnvelopeCodec<int>(
  key: 'counter',
  encodePayload: (v) => v,
  decodePayload: (raw) => raw! as int,
);

void main() {
  group('AtomicStateStore — Fast Path, Cold Seeding & Extension Reloads', () {
    late Directory tempDir;
    late ContainerLayout layout;
    late DarwinNotificationBus busA;
    late DarwinNotificationBus busB;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('eb_state_store_test_');
      layout = ContainerLayout(tempDir.path);
      busA = DarwinNotificationBus(writerId: 0x1001);
      busB = DarwinNotificationBus(writerId: 0x2002);
    });

    tearDown(() async {
      await busA.dispose();
      await busB.dispose();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
        'returns SnapshotEmpty on cold start, hits ~299 ns memory cache, and triggers Widget/Control reloads',
        () {
      final channel = _uniqueNotification('fast_path');
      final reloadedWidgets = <String?>[];
      final reloadedControls = <String?>[];
      final hooks = ExtensionKitHooks(
        onReloadWidgetTimelines: reloadedWidgets.add,
        onReloadControlWidgets: reloadedControls.add,
      );

      final storeA = AtomicStateStore<_TrackModel>(
        key: 'now_playing',
        layout: layout,
        codec: _trackCodec,
        notificationBus: busA,
        notificationName: channel,
        extensionKitHooks: hooks,
        reloadWidgets: const <String>['NowPlayingWidget', '*'],
        reloadControls: const <String>['PlaybackControl'],
      );

      // 1. Cold start with no snapshot file on disk.
      final initial = storeA.readResult();
      expect(initial, isA<SnapshotEmpty<_TrackModel>>());
      expect(initial.valueOrNull, isNull);
      expect(initial.envelopeOrNull, isNull);
      expect(storeA.read(), isNull);

      // 2. Write generation 1.
      const track1 = _TrackModel(title: 'Solar Sailer', playCount: 1);
      final env1 = storeA.write(track1);
      expect(env1.generation, equals(1));
      expect(env1.writerId, equals(0x1001));
      expect(storeA.casCommitCount, equals(1));
      expect(
        reloadedWidgets,
        equals(<String?>['NowPlayingWidget', null]),
      );
      expect(reloadedControls, equals(<String?>['PlaybackControl']));

      // 3. Subsequent reads on storeA hit the ~299 ns shared-memory cache with 0 disk I/O.
      final hit1 = storeA.readResult();
      expect(hit1, isA<SnapshotHit<_TrackModel>>());
      expect((hit1 as SnapshotHit<_TrackModel>).fromMemoryCache, isTrue);
      expect(hit1.value, equals(track1));
      expect(storeA.memoryCacheHits, equals(1));
      expect(storeA.diskSnapshotReads, equals(0));

      for (var i = 0; i < 50; i++) {
        expect(storeA.read(), equals(track1));
      }
      expect(storeA.memoryCacheHits, equals(51));
      expect(storeA.diskSnapshotReads, equals(0));

      // 4. Remote storeB reads from APFS on cold start, then caches in memory.
      final storeB = AtomicStateStore<_TrackModel>(
        key: 'now_playing',
        layout: layout,
        codec: _trackCodec,
        notificationBus: busB,
        notificationName: channel,
      );

      final bRead1 = storeB.readResult();
      expect(bRead1, isA<SnapshotHit<_TrackModel>>());
      expect((bRead1 as SnapshotHit<_TrackModel>).fromMemoryCache, isFalse);
      expect(bRead1.value, equals(track1));
      expect(storeB.diskSnapshotReads, equals(1));

      final bRead2 = storeB.readResult();
      expect((bRead2 as SnapshotHit<_TrackModel>).fromMemoryCache, isTrue);
      expect(storeB.memoryCacheHits, equals(1));
      expect(storeB.diskSnapshotReads, equals(1));

      // 5. storeB updates playCount -> storeA's next read() detects notify_check=1
      //    and reads generation 2 from APFS.
      storeB.update((curr) => curr!.copyWith(playCount: curr.playCount + 1));
      final aAfterRemoteUpdate = storeA.readResult();
      expect(
        (aAfterRemoteUpdate as SnapshotHit<_TrackModel>).fromMemoryCache,
        isFalse,
      );
      expect(aAfterRemoteUpdate.value.playCount, equals(2));
      expect(aAfterRemoteUpdate.envelope.generation, equals(2));
    });
  });

  group('AtomicStateStore — Tier 2 Deterministic POSIX Fault Injection', () {
    late Directory tempDir;
    late ContainerLayout layout;
    late DarwinNotificationBus busA;
    late DarwinNotificationBus busB;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('eb_cas_fault_test_');
      layout = ContainerLayout(tempDir.path);
      layout.ensureBaseDirectoriesSync();
      busA = DarwinNotificationBus(writerId: 0x3001);
      busB = DarwinNotificationBus(writerId: 0x4002);
    });

    tearDown(() async {
      await busA.dispose();
      await busB.dispose();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
        'Fault 1: Instant (< 1 ms) dead-PID .cas symlink eviction (kill(pid, 0) == ESRCH) & orphan .tmp sweep',
        () {
      final channel = _uniqueNotification('dead_pid_evict');
      final store = AtomicStateStore<int>(
        key: 'counter',
        layout: layout,
        codec: _intCodec,
        notificationBus: busA,
        notificationName: channel,
      );

      // Inject an orphaned .tmp staging file and a .cas symlink lease from a
      // dead PID (999998 > PID_MAX, so kill(999998, 0) returns ESRCH).
      const deadPid = 999998;
      final orphanTmpPath = layout.stateStagingPath(
        'counter',
        nonce: '${deadPid}_${DateTime.now().microsecondsSinceEpoch}_1_dead',
      );
      File(orphanTmpPath).writeAsStringSync('{"partial":true');

      final deadLease = CasLeaseToken(
        pid: deadPid,
        acquiredAtMicros: DateTime.now().microsecondsSinceEpoch,
        nonce: 'crashed-extension-lease',
      );
      expect(
        DarwinPosixFfi.instance.symlink(
          target: deadLease.encode(),
          linkPath: store.casLeaseFilePath,
        ),
        equals(0),
      );

      final sw = Stopwatch()..start();
      final committed = store.write(100);
      sw.stop();

      expect(committed.generation, equals(1));
      expect(store.read(), equals(100));
      expect(store.evictedDeadPidLeaseCount, equals(1));
      // Verify dead-PID eviction did NOT wait for the 2,000 ms timeout ceiling.
      expect(sw.elapsedMilliseconds, lessThan(200));

      // Verify zero leftover .tmp or .cas files in state/.
      final stateEntries = Directory(layout.stateDirectoryPath)
          .listSync(followLinks: false)
          .map((e) => p.basename(e.path))
          .toList();
      expect(stateEntries, equals(<String>['counter.v1.json']));
    });

    test('Fault 2: Evicts expired live-PID .cas lease exceeding 2,000 ms ceiling',
        () {
      final channel = _uniqueNotification('expired_lease');
      const fakeClockMicros = 1729800000000000;

      final store = AtomicStateStore<int>(
        key: 'counter',
        layout: layout,
        codec: _intCodec,
        notificationBus: busA,
        notificationName: channel,
        clockMicros: () => fakeClockMicros,
      );

      // Inject a .cas symlink held by our own (live) PID, but acquired 3,000 ms ago.
      final staleLease = CasLeaseToken(
        pid: DarwinPosixFfi.instance.getpid(),
        acquiredAtMicros: fakeClockMicros - 3000000,
        nonce: 'hung-writer-lease',
      );
      expect(
        DarwinPosixFfi.instance.symlink(
          target: staleLease.encode(),
          linkPath: store.casLeaseFilePath,
        ),
        equals(0),
      );

      final env = store.write(55);
      expect(env.generation, equals(1));
      expect(store.evictedExpiredLeaseCount, equals(1));
      expect(store.read(), equals(55));
      expect(
        DarwinPosixFfi.instance.readlink(store.casLeaseFilePath),
        isNull,
      );
    });

    test(
        'Fault 3: Adversarial CAS contention (_gen != expectedGen) retries pure mutator with 0 lost updates',
        () {
      final channel = _uniqueNotification('cas_contention');
      final contenderStore = AtomicStateStore<int>(
        key: 'counter',
        layout: layout,
        codec: _intCodec,
        notificationBus: busB,
        notificationName: channel,
      );

      // Seed counter = 10 (generation 1).
      contenderStore.write(10);

      var injectedContention = 0;
      late final AtomicStateStore<int> writerStore;
      writerStore = AtomicStateStore<int>(
        key: 'counter',
        layout: layout,
        codec: _intCodec,
        notificationBus: busA,
        notificationName: channel,
        onBeforeCasAcquire: (int attempt, String stagingPath) {
          if (attempt <= 2) {
            // Simulate a concurrent process committing an increment right after
            // writerStore read expectedGen and serialized .tmp, before .cas!
            injectedContention += 1;
            contenderStore.update((curr) => (curr ?? 0) + 1);
          }
        },
      );

      var mutatorInvocations = 0;
      final finalEnv = writerStore.update((current) {
        mutatorInvocations += 1;
        return (current ?? 0) + 100;
      });

      // Initial was 10; 2 contender increments (+2) + writerStore (+100) = 112!
      expect(injectedContention, equals(2));
      expect(mutatorInvocations, equals(3));
      expect(writerStore.casRetryCount, equals(2));
      expect(finalEnv.generation, equals(4));
      expect(finalEnv.payload, equals(112));
      expect(writerStore.read(), equals(112));
      expect(contenderStore.read(), equals(112));
    });

    test(
        'Fault 4: Split-brain lease-token verification prevents overwriting or unlinking a stolen .cas lease',
        () {
      final channel = _uniqueNotification('split_brain');
      final posix = DarwinPosixFfi.instance;

      late final AtomicStateStore<int> store;
      store = AtomicStateStore<int>(
        key: 'counter',
        layout: layout,
        codec: _intCodec,
        notificationBus: busA,
        notificationName: channel,
        onBeforeRenameCommit:
            (int attempt, CasLeaseToken leaseToken, String casPath) {
          if (attempt == 1) {
            // Simulate a GC pause > 2,000 ms where another writer evicted our
            // .cas lease and installed its own lease token right before our
            // rename(2) commit!
            posix.unlink(casPath);
            final foreignLease = CasLeaseToken(
              pid: 999998, // dead PID so attempt 2 can evict it cleanly
              acquiredAtMicros: DateTime.now().microsecondsSinceEpoch,
              nonce: 'foreign-owner-token',
            );
            posix.symlink(target: foreignLease.encode(), linkPath: casPath);
          }
        },
      );

      final env = store.write(777);
      expect(env.generation, equals(1));
      expect(store.splitBrainPreventedCount, equals(1));
      expect(store.casRetryCount, equals(1));
      expect(store.read(), equals(777));
    });

    test(
        'Fault 5: Exhausted CAS retry budget throws CasContentionException and cleans up staging files',
        () {
      final channel = _uniqueNotification('cas_exhausted');
      final posix = DarwinPosixFfi.instance;

      final store = AtomicStateStore<int>(
        key: 'counter',
        layout: layout,
        codec: _intCodec,
        notificationBus: busA,
        notificationName: channel,
        maxCasAttempts: 3,
      );

      // Hold an active, non-expired lease under our live PID.
      final activeHolderLease = CasLeaseToken(
        pid: posix.getpid(),
        acquiredAtMicros: DateTime.now().microsecondsSinceEpoch + 60000000,
        nonce: 'locked-by-live-holder',
      );
      posix.symlink(
        target: activeHolderLease.encode(),
        linkPath: store.casLeaseFilePath,
      );

      expect(
        () => store.write(42),
        throwsA(
          isA<CasContentionException>()
              .having((e) => e.key, 'key', 'counter')
              .having((e) => e.attempts, 'attempts', 3)
              .having((e) => e.lastHolderPid, 'lastHolderPid', posix.getpid()),
        ),
      );

      // Clean up the synthetic lease and verify zero .tmp files were leaked.
      posix.unlink(store.casLeaseFilePath);
      final stateFiles = Directory(layout.stateDirectoryPath).listSync();
      expect(stateFiles, isEmpty);
    });

    test(
        'Fault 6: Generation-bounded @SharedState blob GC (< currentGen - 2) retains only recent blobs',
        () {
      final channel = _uniqueNotification('blob_gc');
      final sourceArtFile = File(p.join(tempDir.path, 'cover_source.jpg'))
        ..writeAsStringSync('artwork-binary-payload');

      final store = AtomicStateStore<_TrackModel>(
        key: 'now_playing',
        layout: layout,
        codec: _trackCodec,
        notificationBus: busA,
        notificationName: channel,
        stageAttachments: ({
          required _TrackModel value,
          required int generation,
          required SharedAttachmentManager manager,
        }) {
          final art = value.artworkPath;
          if (art == null) {
            return StagedAttachments<_TrackModel>(
              stagedValue: value,
              relativeBlobPaths: const <String>[],
            );
          }
          final relPath = manager.stageStateAttachment(
            sourcePath: art,
            stateKey: 'now_playing',
            generation: generation,
          );
          return StagedAttachments<_TrackModel>(
            stagedValue: value.copyWith(artworkPath: relPath),
            relativeBlobPaths: <String>[relPath],
          );
        },
        resolveAttachments: (_TrackModel value, SharedAttachmentManager mgr) {
          final art = value.artworkPath;
          if (art == null) return value;
          return value.copyWith(
            artworkPath: mgr.resolveAttachmentPath(art),
          );
        },
      );

      // Commit 6 sequential generations, each with an attachment.
      for (var gen = 1; gen <= 6; gen++) {
        store.write(
          _TrackModel(
            title: 'Track $gen',
            playCount: gen,
            artworkPath: sourceArtFile.path,
          ),
        );
      }

      final latest = store.read()!;
      expect(latest.title, equals('Track 6'));
      expect(p.isAbsolute(latest.artworkPath!), isTrue);
      expect(File(latest.artworkPath!).existsSync(), isTrue);
      expect(
        File(latest.artworkPath!).readAsStringSync(),
        equals('artwork-binary-payload'),
      );

      // At generation 6 with retentionGenerations = 2, generations 1, 2, 3
      // (< 6 - 2 = 4) must be unlinked, while generations 4, 5, 6 remain.
      final remainingBlobs = Directory(layout.blobsDirectoryPath)
          .listSync()
          .map((e) => p.basename(e.path))
          .toList()
        ..sort();

      expect(remainingBlobs, hasLength(3));
      expect(
        remainingBlobs.every(
          (name) =>
              name.startsWith('state_now_playing_gen_4_') ||
              name.startsWith('state_now_playing_gen_5_') ||
              name.startsWith('state_now_playing_gen_6_'),
        ),
        isTrue,
      );
      expect(store.attachmentManager.garbageCollectedBlobCount, equals(3));
    });

    test(
        'watch() streams remote mutations, suppresses self-echoes, and reconciles on foreground resume',
        () async {
      final channel = _uniqueNotification('watch_reconcile');
      final lifecycle = DarwinLifecycleObserver();

      final writerStore = AtomicStateStore<int>(
        key: 'counter',
        layout: layout,
        codec: _intCodec,
        notificationBus: busA,
        notificationName: channel,
      );
      final readerStore = AtomicStateStore<int>(
        key: 'counter',
        layout: layout,
        codec: _intCodec,
        notificationBus: busB,
        notificationName: channel,
        lifecycleObserver: lifecycle,
      );

      final writerEvents = <int>[];
      final readerEvents = <int>[];
      final firstReaderWakeup = Completer<int>();

      final writerSub = writerStore.watch().listen(writerEvents.add);
      final readerSub = readerStore.watch().listen((value) {
        readerEvents.add(value);
        if (!firstReaderWakeup.isCompleted) {
          firstReaderWakeup.complete(value);
        }
      });

      writerStore.write(42);
      final delivered = await firstReaderWakeup.future.timeout(
        const Duration(seconds: 2),
      );
      expect(delivered, equals(42));

      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(writerEvents, isEmpty);
      expect(readerEvents, equals(<int>[42]));

      // Verify watch(emitInitial: true) emits the existing snapshot immediately.
      final initialValues = <int>[];
      final initSub =
          readerStore.watch(emitInitial: true).listen(initialValues.add);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(initialValues, equals(<int>[42]));

      // Simulate foreground resume reconciliation when a snapshot was written
      // while suspended.
      final env2 = StateEnvelope<int>(
        schemaVersion: 1,
        generation: 2,
        updatedAtMicros: DateTime.now().microsecondsSinceEpoch,
        writerId: 0x9999,
        payload: 99,
      );
      File(readerStore.snapshotFilePath).writeAsBytesSync(
        _intCodec.encodeToBytes(env2),
        flush: true,
      );
      DarwinPosixFfi.instance.notifyPost(channel);

      lifecycle.simulateDidBecomeActive();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(readerEvents, contains(99));

      await initSub.cancel();
      await writerSub.cancel();
      await readerSub.cancel();
      await writerStore.dispose();
      await readerStore.dispose();
      await lifecycle.dispose();
    });
  });
}
