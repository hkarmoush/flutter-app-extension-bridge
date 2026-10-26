import 'dart:async';
import 'dart:io';

import 'package:extension_bridge/extension_bridge.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

final class _InteropNowPlaying {
  const _InteropNowPlaying({
    required this.trackId,
    required this.title,
    required this.playCount,
    required this.isPlaying,
    this.artworkPath,
  });

  final String trackId;
  final String title;
  final int playCount;
  final bool isPlaying;
  final String? artworkPath;

  _InteropNowPlaying copyWith({
    String? trackId,
    String? title,
    int? playCount,
    bool? isPlaying,
    String? artworkPath,
  }) =>
      _InteropNowPlaying(
        trackId: trackId ?? this.trackId,
        title: title ?? this.title,
        playCount: playCount ?? this.playCount,
        isPlaying: isPlaying ?? this.isPlaying,
        artworkPath: artworkPath ?? this.artworkPath,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'trackId': trackId,
        'title': title,
        'playCount': playCount,
        'isPlaying': isPlaying,
        if (artworkPath != null) 'artworkPath': artworkPath,
      };

  static _InteropNowPlaying fromJson(Object? raw) {
    final map = raw! as Map<String, Object?>;
    return _InteropNowPlaying(
      trackId: map['trackId']! as String,
      title: map['title']! as String,
      playCount: (map['playCount']! as num).toInt(),
      isPlaying: map['isPlaying']! as bool,
      artworkPath: map['artworkPath'] as String?,
    );
  }
}

final class _InteropSharedMediaItem {
  const _InteropSharedMediaItem({
    required this.caption,
    required this.index,
    this.mediaPath,
  });

  final String caption;
  final int index;
  final String? mediaPath;

  _InteropSharedMediaItem copyWith({
    String? caption,
    int? index,
    String? mediaPath,
  }) =>
      _InteropSharedMediaItem(
        caption: caption ?? this.caption,
        index: index ?? this.index,
        mediaPath: mediaPath ?? this.mediaPath,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'caption': caption,
        'index': index,
        if (mediaPath != null) 'mediaPath': mediaPath,
      };

  static _InteropSharedMediaItem fromJson(Object? raw) {
    final map = raw! as Map<String, Object?>;
    return _InteropSharedMediaItem(
      caption: map['caption']! as String,
      index: (map['index']! as num).toInt(),
      mediaPath: map['mediaPath'] as String?,
    );
  }
}

String _resolveSwiftPackageDir() {
  final candidates = <String>[
    p.normalize(p.join(Directory.current.path, 'swift', 'ExtensionBridgeCore')),
    p.normalize(
      p.join(Directory.current.path, '..', '..', 'swift', 'ExtensionBridgeCore'),
    ),
  ];
  for (final candidate in candidates) {
    if (File(p.join(candidate, 'Package.swift')).existsSync()) {
      return candidate;
    }
  }
  throw StateError('Could not locate swift/ExtensionBridgeCore/Package.swift');
}

void main() {
  group('Dart <-> Swift 6 (ExtensionBridgeCore) Cross-Language Interop', () {
    late Directory tempDir;
    late ContainerLayout layout;
    late DarwinNotificationBus bus;
    late String helperBinPath;

    setUpAll(() async {
      final swiftPkgDir = _resolveSwiftPackageDir();
      final buildResult = await Process.run(
        'swift',
        <String>[
          'build',
          '--package-path',
          swiftPkgDir,
          '--product',
          'eb-swift-interop-helper',
        ],
      );
      if (buildResult.exitCode != 0) {
        fail(
          'Failed to build eb-swift-interop-helper:\n'
          'stdout: ${buildResult.stdout}\n'
          'stderr: ${buildResult.stderr}',
        );
      }

      final binPathResult = await Process.run(
        'swift',
        <String>[
          'build',
          '--package-path',
          swiftPkgDir,
          '--show-bin-path',
        ],
      );
      expect(binPathResult.exitCode, equals(0));
      final binDir = (binPathResult.stdout as String).trim();
      helperBinPath = p.join(binDir, 'eb-swift-interop-helper');
      expect(File(helperBinPath).existsSync(), isTrue);
    });

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('eb_dart_swift_interop_');
      layout = ContainerLayout(tempDir.path);
      bus = DarwinNotificationBus();
    });

    tearDown(() async {
      await bus.dispose();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
      'Dart writes @SharedState -> Swift reads & updates via CAS -> Dart watch stream wakes up',
      () async {
        final channel =
            'com.example.eb.interop.state.${DateTime.now().microsecondsSinceEpoch}';
        final store = AtomicStateStore<_InteropNowPlaying>(
          key: 'now_playing',
          layout: layout,
          codec: const StateEnvelopeCodec<_InteropNowPlaying>(
            encodePayload: _encodeNowPlaying,
            decodePayload: _InteropNowPlaying.fromJson,
            key: 'now_playing',
          ),
          notificationBus: bus,
          notificationName: channel,
          stageAttachments: ({
            required value,
            required generation,
            required manager,
          }) {
            final art = value.artworkPath;
            if (art == null || art.isEmpty) {
              return StagedAttachments(
                stagedValue: value,
                relativeBlobPaths: const <String>[],
              );
            }
            final rel = manager.stageStateAttachment(
              sourcePath: art,
              stateKey: 'now_playing',
              generation: generation,
            );
            return StagedAttachments(
              stagedValue: value.copyWith(artworkPath: rel),
              relativeBlobPaths: <String>[rel],
            );
          },
          resolveAttachments: (value, manager) {
            final art = value.artworkPath;
            if (art == null || art.isEmpty) return value;
            return value.copyWith(
              artworkPath: manager.resolveAttachmentPath(art),
            );
          },
        );
        addTearDown(store.dispose);

        final dartCover = File(p.join(tempDir.path, 'dart_cover.jpg'))
          ..writeAsStringSync('dart-artwork-v1');
        final swiftCover = File(p.join(tempDir.path, 'swift_cover.jpg'))
          ..writeAsStringSync('swift-artwork-v2');

        // 1. Dart writes generation 1
        final env1 = store.write(
          _InteropNowPlaying(
            trackId: 'spotify:1',
            title: 'Written by Dart',
            playCount: 10,
            isPlaying: false,
            artworkPath: dartCover.path,
          ),
        );
        expect(env1.generation, equals(1));

        // 2. Subscribe to Dart watch() stream before launching Swift process
        final wakeupCompleter = Completer<_InteropNowPlaying>();
        final sub = store.watch().listen((state) {
          if (!wakeupCompleter.isCompleted) {
            wakeupCompleter.complete(state);
          }
        });
        addTearDown(sub.cancel);

        // 3. Swift process reads generation 1, increments playCount by 5 via CAS,
        // stages swiftCover via clonefile(2), commits generation 2, and posts <notify.h>
        final res = await Process.run(
          helperBinPath,
          <String>[
            'cas-update-state',
            tempDir.path,
            'now_playing',
            channel,
            '5',
            'Updated by Swift 6',
            swiftCover.path,
          ],
        );
        expect(res.exitCode, equals(0), reason: 'stderr: ${res.stderr}');
        expect(res.stdout as String, contains('OK gen=2'));

        // 4. Verify Dart stream wakes up with Swift's committed state and attachment
        final updated = await wakeupCompleter.future.timeout(
          const Duration(seconds: 2),
        );
        expect(updated.title, equals('Updated by Swift 6'));
        expect(updated.playCount, equals(15));
        expect(updated.isPlaying, isTrue);
        expect(updated.artworkPath, isNotNull);
        expect(
          File(updated.artworkPath!).readAsStringSync(),
          equals('swift-artwork-v2'),
        );
      },
    );

    test(
      'Swift enqueues @SharedQueue items with clonefile attachments -> Dart consumes & acks (and vice versa)',
      () async {
        final channel =
            'com.example.eb.interop.queue.${DateTime.now().microsecondsSinceEpoch}';
        final queue = SharedQueueStore<_InteropSharedMediaItem>(
          queueKey: 'shared_inbox',
          layout: layout,
          codec: const StateEnvelopeCodec<_InteropSharedMediaItem>(
            encodePayload: _encodeMediaItem,
            decodePayload: _InteropSharedMediaItem.fromJson,
            key: 'shared_inbox',
          ),
          notificationBus: bus,
          notificationName: channel,
          stageAttachments: ({
            required value,
            required itemUuid,
            required manager,
          }) {
            final media = value.mediaPath;
            if (media == null || media.isEmpty) {
              return StagedAttachments(
                stagedValue: value,
                relativeBlobPaths: const <String>[],
              );
            }
            final rel = manager.stageQueueAttachment(
              sourcePath: media,
              itemUuid: itemUuid,
              attachmentIndex: 0,
            );
            return StagedAttachments(
              stagedValue: value.copyWith(mediaPath: rel),
              relativeBlobPaths: <String>[rel],
            );
          },
          resolveAttachments: (value, manager) {
            final media = value.mediaPath;
            if (media == null || media.isEmpty) return value;
            return value.copyWith(
              mediaPath: manager.resolveAttachmentPath(media),
            );
          },
        );
        addTearDown(queue.dispose);

        final mediaFile = File(p.join(tempDir.path, 'video_4k.mov'))
          ..writeAsStringSync('4k-video-stream-bytes');

        final deliveryCompleter = Completer<QueueDelivery<_InteropSharedMediaItem>>();
        final sub = queue.consume().listen((delivery) {
          if (!deliveryCompleter.isCompleted) {
            deliveryCompleter.complete(delivery);
          }
        });
        addTearDown(sub.cancel);

        // 1. Swift enqueues item with APFS clonefile attachment
        final res = await Process.run(
          helperBinPath,
          <String>[
            'enqueue-media',
            tempDir.path,
            'shared_inbox',
            channel,
            'Shared from iOS Share Extension',
            '42',
            mediaFile.path,
          ],
        );
        expect(res.exitCode, equals(0), reason: 'stderr: ${res.stderr}');

        final delivery = await deliveryCompleter.future.timeout(
          const Duration(seconds: 2),
        );
        expect(delivery.value.caption, equals('Shared from iOS Share Extension'));
        expect(delivery.value.index, equals(42));
        final clonedBlobPath = delivery.value.mediaPath!;
        expect(
          File(clonedBlobPath).readAsStringSync(),
          equals('4k-video-stream-bytes'),
        );

        delivery.ack();
        expect(File(clonedBlobPath).existsSync(), isFalse);

        // 2. Reverse direction: Dart enqueues -> Swift drains & acks
        await sub.cancel();
        queue.enqueueSync(
          _InteropSharedMediaItem(
            caption: 'Queued by Dart',
            index: 99,
            mediaPath: mediaFile.path,
          ),
        );
        expect(queue.pendingReadyCountSync(), equals(1));

        final drainRes = await Process.run(
          helperBinPath,
          <String>[
            'drain-and-ack',
            tempDir.path,
            'shared_inbox',
            channel,
          ],
        );
        expect(drainRes.exitCode, equals(0), reason: 'stderr: ${drainRes.stderr}');
        expect(drainRes.stdout as String, contains('OK drained=1'));
        expect(queue.pendingReadyCountSync(), equals(0));
      },
    );

    test(
      'Swift posts 32-bit @DarwinSignal in kernel register -> Dart receives signal in real time',
      () async {
        final signalName =
            'com.example.eb.interop.sig.${DateTime.now().microsecondsSinceEpoch}';
        final sigCompleter = Completer<DarwinSignalEvent>();
        final sub = bus.watchSignal(signalName).listen((event) {
          if (!sigCompleter.isCompleted) {
            sigCompleter.complete(event);
          }
        });
        addTearDown(sub.cancel);

        final res = await Process.run(
          helperBinPath,
          <String>['post-signal', signalName, '-777'],
        );
        expect(res.exitCode, equals(0), reason: 'stderr: ${res.stderr}');

        final event = await sigCompleter.future.timeout(
          const Duration(seconds: 2),
        );
        expect(event.payload, equals(-777));
        expect(event.register.hasValidMagic, isTrue);
      },
    );
  });
}

Object? _encodeNowPlaying(_InteropNowPlaying v) => v.toJson();
Object? _encodeMediaItem(_InteropSharedMediaItem v) => v.toJson();
