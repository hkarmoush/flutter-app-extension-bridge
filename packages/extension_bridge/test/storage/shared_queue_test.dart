import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:extension_bridge/extension_bridge.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

String _uniqueQueueNotification(String label) {
  final rand = math.Random().nextInt(0x7FFFFFFF).toRadixString(16);
  final micros = DateTime.now().microsecondsSinceEpoch;
  return 'dev.extension_bridge.test.queue.$label.$micros.$rand';
}

final class _ShareItem {
  const _ShareItem({
    required this.id,
    required this.caption,
    this.mediaPath,
  });

  final String id;
  final String caption;
  final String? mediaPath;

  _ShareItem copyWith({
    String? id,
    String? caption,
    String? mediaPath,
  }) =>
      _ShareItem(
        id: id ?? this.id,
        caption: caption ?? this.caption,
        mediaPath: mediaPath ?? this.mediaPath,
      );

  Map<String, Object?> toJson() => <String, Object?>{
        'id': id,
        'caption': caption,
        if (mediaPath != null) 'mediaPath': mediaPath,
      };

  static _ShareItem fromJson(Object? raw) {
    final map = Map<String, Object?>.from(raw! as Map);
    return _ShareItem(
      id: map['id']! as String,
      caption: map['caption']! as String,
      mediaPath: map['mediaPath'] as String?,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is _ShareItem &&
          other.id == id &&
          other.caption == caption &&
          other.mediaPath == mediaPath;

  @override
  int get hashCode => Object.hash(id, caption, mediaPath);
}

final _shareItemCodec = StateEnvelopeCodec<_ShareItem>(
  key: 'share_inbox',
  encodePayload: (item) => item.toJson(),
  decodePayload: _ShareItem.fromJson,
);

SharedQueueStore<_ShareItem> _createShareQueue({
  required ContainerLayout layout,
  required DarwinNotificationBus bus,
  required String notificationName,
  int maxItems = 256,
  HybridLogicalClock? clock,
}) =>
    SharedQueueStore<_ShareItem>(
      queueKey: 'share_inbox',
      layout: layout,
      codec: _shareItemCodec,
      notificationBus: bus,
      notificationName: notificationName,
      maxItems: maxItems,
      clock: clock,
      stageAttachments: ({
        required _ShareItem value,
        required String itemUuid,
        required SharedAttachmentManager manager,
      }) {
        final media = value.mediaPath;
        if (media == null) {
          return StagedAttachments<_ShareItem>(
            stagedValue: value,
            relativeBlobPaths: const <String>[],
          );
        }
        final relPath = manager.stageQueueAttachment(
          sourcePath: media,
          itemUuid: itemUuid,
          attachmentIndex: 0,
        );
        return StagedAttachments<_ShareItem>(
          stagedValue: value.copyWith(mediaPath: relPath),
          relativeBlobPaths: <String>[relPath],
        );
      },
      resolveAttachments: (_ShareItem value, SharedAttachmentManager manager) {
        final media = value.mediaPath;
        if (media == null) return value;
        return value.copyWith(
          mediaPath: manager.resolveAttachmentPath(media),
        );
      },
    );

void main() {
  group('SharedQueueStore — Maildir HLC Ordering, Attachments & Crash Recovery',
      () {
    late Directory tempDir;
    late ContainerLayout layout;
    late DarwinNotificationBus producerBus;
    late DarwinNotificationBus consumerBus;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('eb_queue_store_test_');
      layout = ContainerLayout(tempDir.path);
      producerBus = DarwinNotificationBus(writerId: 0x5001);
      consumerBus = DarwinNotificationBus(writerId: 0x6002);
    });

    tearDown(() async {
      await producerBus.dispose();
      await consumerBus.dispose();
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
        'enqueues items with zero-copy @SharedAttachment blobs, drains in HLC order, and unlinks blobs on ack()',
        () {
      final channel = _uniqueQueueNotification('hlc_and_blobs');
      var simulatedMicros = 1729800000000;
      final producerClock = HybridLogicalClock(
        writerId: 0x5001,
        wallClockMicros: () => simulatedMicros,
      );

      final producer = _createShareQueue(
        layout: layout,
        bus: producerBus,
        notificationName: channel,
        clock: producerClock,
      );
      final consumer = _createShareQueue(
        layout: layout,
        bus: consumerBus,
        notificationName: channel,
      );

      final sourcePhoto = File(p.join(tempDir.path, 'photo_4k.heic'))
        ..writeAsStringSync('heic-image-bytes-payload');

      // Enqueue 5 items, including a simulated NTP backward clock jump on item 3.
      for (var i = 1; i <= 5; i++) {
        if (i == 3) {
          simulatedMicros -= 100000; // backward jump!
        } else {
          simulatedMicros += 10;
        }
        final receipt = producer.enqueueSync(
          _ShareItem(
            id: 'item-$i',
            caption: 'Photo #$i',
            mediaPath: sourcePhoto.path,
          ),
        );
        expect(receipt.fileName, endsWith('.json'));
        expect(receipt.toString(), contains(receipt.fileName));
      }

      expect(producer.enqueuedCount, equals(5));
      expect(producer.pendingReadyCountSync(), equals(5));
      expect(Directory(layout.blobsDirectoryPath).listSync(), hasLength(5));

      final deliveries = consumer.drainAvailableSync();
      expect(deliveries, hasLength(5));
      expect(
        deliveries.map((d) => d.value.id).toList(),
        equals(<String>['item-1', 'item-2', 'item-3', 'item-4', 'item-5']),
      );
      expect(consumer.pendingReadyCountSync(), equals(0));
      expect(consumer.inflightCountSync(), equals(5));

      // Before ack(), all 5 blobs exist and are readable via resolved absolute paths.
      for (final d in deliveries) {
        expect(d.isRedelivery, isFalse);
        expect(p.isAbsolute(d.value.mediaPath!), isTrue);
        expect(
          File(d.value.mediaPath!).readAsStringSync(),
          equals('heic-image-bytes-payload'),
        );
      }

      // Acknowledge all 5 deliveries -> inflight/ and blobs/ become completely empty!
      for (final d in deliveries) {
        d.ack();
        expect(d.isSettled, isTrue);
      }

      expect(consumer.acknowledgedCount, equals(5));
      expect(consumer.inflightCountSync(), equals(0));
      expect(Directory(layout.blobsDirectoryPath).listSync(), isEmpty);
    });

    test(
        'Tier 2 Fault Injection: recovers unacknowledged inflight/ items on startup & handles nack(requeue: true)',
        () async {
      final channel = _uniqueQueueNotification('inflight_recovery');
      final producer = _createShareQueue(
        layout: layout,
        bus: producerBus,
        notificationName: channel,
      );
      final crashedConsumer = _createShareQueue(
        layout: layout,
        bus: consumerBus,
        notificationName: channel,
      );

      final srcVideo = File(p.join(tempDir.path, 'clip.mov'))
        ..writeAsStringSync('video-clip-bytes');

      for (var i = 1; i <= 3; i++) {
        producer.enqueueSync(
          _ShareItem(
            id: 'msg-$i',
            caption: 'Clip $i',
            mediaPath: srcVideo.path,
          ),
        );
      }

      // Inject an orphaned file from a dead PID (999998) inside queue/tmp/.
      final orphanTmp = File(
        p.join(
          producer.tmpDirectoryPath,
          '00001729800000000_0000_999998_1_dead.json',
        ),
      )..writeAsStringSync('{truncated');
      expect(orphanTmp.existsSync(), isTrue);

      // Consumer 1 claims the first 2 items into inflight/, then crashes before ack()!
      final claimed1 = crashedConsumer.claimNextDeliverySync()!;
      final claimed2 = crashedConsumer.claimNextDeliverySync()!;
      expect(claimed1.value.id, equals('msg-1'));
      expect(claimed2.value.id, equals('msg-2'));
      expect(crashedConsumer.inflightCountSync(), equals(2));
      expect(crashedConsumer.pendingReadyCountSync(), equals(1));
      await crashedConsumer.dispose();

      // Consumer 2 starts up after the crash and runs processAvailable().
      final restartedBus = DarwinNotificationBus(writerId: 0x7003);
      final restartedConsumer = _createShareQueue(
        layout: layout,
        bus: restartedBus,
        notificationName: channel,
      );

      // Simulate transient failure on the first attempt of msg-2 to verify nack(requeue: true).
      var failedOnceOnMsg2 = false;
      final processedIds = <String>[];
      final redeliveryFlags = <String, bool>{};

      await expectLater(
        () => restartedConsumer.processAvailable((item, delivery) {
          if (item.id == 'msg-2' && !failedOnceOnMsg2) {
            failedOnceOnMsg2 = true;
            throw StateError('Simulated transient consumer error on msg-2');
          }
          processedIds.add(item.id);
          redeliveryFlags[item.id] = delivery.isRedelivery;
        }),
        throwsStateError,
      );

      // msg-1 was acked; msg-2 was nacked(requeue: true) back to ready/; msg-3 is still in ready/.
      expect(restartedConsumer.recoveredInflightCount, equals(2));
      expect(orphanTmp.existsSync(), isFalse);
      expect(processedIds, equals(<String>['msg-1']));
      expect(redeliveryFlags['msg-1'], isTrue);
      expect(restartedConsumer.pendingReadyCountSync(), equals(2));

      // Second pass processes msg-2 and msg-3 cleanly and unlinks all remaining blobs.
      final countPass2 =
          await restartedConsumer.processAvailable((item, delivery) {
        processedIds.add(item.id);
        redeliveryFlags[item.id] = delivery.isRedelivery;
      });
      expect(countPass2, equals(2));
      expect(processedIds, equals(<String>['msg-1', 'msg-2', 'msg-3']));
      expect(redeliveryFlags['msg-2'], isTrue);
      expect(redeliveryFlags['msg-3'], isFalse);
      expect(restartedConsumer.pendingReadyCountSync(), equals(0));
      expect(restartedConsumer.inflightCountSync(), equals(0));
      expect(Directory(layout.blobsDirectoryPath).listSync(), isEmpty);

      await restartedConsumer.dispose();
      await restartedBus.dispose();
    });

    test(
        'enforces maxItems backpressure by evicting oldest ready/ items and their blobs',
        () {
      final channel = _uniqueQueueNotification('backpressure');
      final queue = _createShareQueue(
        layout: layout,
        bus: producerBus,
        notificationName: channel,
        maxItems: 3,
      );

      final srcFile = File(p.join(tempDir.path, 'doc.pdf'))
        ..writeAsStringSync('pdf-content');

      for (var i = 1; i <= 5; i++) {
        queue.enqueueSync(
          _ShareItem(
            id: 'doc-$i',
            caption: 'Document $i',
            mediaPath: srcFile.path,
          ),
        );
      }

      // Because maxItems == 3, items doc-1 and doc-2 were evicted along with their blobs.
      expect(queue.evictedBackpressureCount, equals(2));
      expect(queue.pendingReadyCountSync(), equals(3));
      expect(Directory(layout.blobsDirectoryPath).listSync(), hasLength(3));

      final drained = queue.drainAvailableSync();
      expect(
        drained.map((d) => d.value.id).toList(),
        equals(<String>['doc-3', 'doc-4', 'doc-5']),
      );
      for (final d in drained) {
        d.ack();
      }
      expect(Directory(layout.blobsDirectoryPath).listSync(), isEmpty);
    });

    test('consume() stream drains initial backlog and reacts to live <notify.h> enqueues',
        () async {
      final channel = _uniqueQueueNotification('consume_stream');
      final producer = _createShareQueue(
        layout: layout,
        bus: producerBus,
        notificationName: channel,
      );
      final consumer = _createShareQueue(
        layout: layout,
        bus: consumerBus,
        notificationName: channel,
      );

      // Enqueue 1 item before consumer starts listening.
      producer.enqueueSync(const _ShareItem(id: 'pre-1', caption: 'Before'));

      final receivedIds = <String>[];
      final receivedThree = Completer<void>();

      final sub = consumer.consume().listen((delivery) {
        receivedIds.add(delivery.value.id);
        delivery.ack();
        if (receivedIds.length == 3 && !receivedThree.isCompleted) {
          receivedThree.complete();
        }
      });

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(receivedIds, equals(<String>['pre-1']));

      // Enqueue 2 live items -> <notify.h> wakes up consumer.consume() stream.
      await producer.enqueue(const _ShareItem(id: 'live-2', caption: 'Live 2'));
      await producer.enqueue(const _ShareItem(id: 'live-3', caption: 'Live 3'));

      await receivedThree.future.timeout(const Duration(seconds: 2));
      expect(
        receivedIds,
        equals(<String>['pre-1', 'live-2', 'live-3']),
      );
      expect(consumer.pendingReadyCountSync(), equals(0));
      expect(consumer.inflightCountSync(), equals(0));

      await sub.cancel();
      await producer.dispose();
      await consumer.dispose();
    });
  });
}
