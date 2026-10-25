/// Example demonstrating `AtomicStateStore`, `SharedQueueStore`, and Darwin FFI
/// `<notify.h>` 64-bit state registers in `package:extension_bridge`.
library;

import 'dart:io';

import 'package:extension_bridge/extension_bridge.dart';

Future<void> main() async {
  final tempDir = Directory.systemTemp.createTempSync('eb_example_');
  final layout = ContainerLayout(tempDir.path);
  final bus = DarwinNotificationBus();

  try {
    final mapCodec = StateEnvelopeCodec<Map<String, Object?>>(
      key: 'now_playing',
      encodePayload: (map) => map,
      decodePayload: (raw) => Map<String, Object?>.from(raw! as Map),
    );

    // 1. AtomicStateStore: 0xdead10cc-proof lock-free snapshot & CAS loop.
    final stateStore = AtomicStateStore<Map<String, Object?>>(
      key: 'now_playing',
      layout: layout,
      codec: mapCodec,
      notificationBus: bus,
      notificationName: 'dev.extension_bridge.example.state.now_playing',
    );

    stateStore.update((current) => <String, Object?>{
          'title': 'Starlight',
          'playCount': ((current?['playCount'] as int?) ?? 0) + 1,
        });

    // ~299 ns shared-memory fast-path cache hit:
    final hit = stateStore.readResult();
    assert(hit is SnapshotHit<Map<String, Object?>> && hit.fromMemoryCache);

    // 2. SharedQueueStore: HLC-ordered Maildir transactional queue.
    final queueStore = SharedQueueStore<Map<String, Object?>>(
      queueKey: 'share_inbox',
      layout: layout,
      codec: mapCodec,
      notificationBus: bus,
      notificationName: 'dev.extension_bridge.example.queue.share_inbox',
    );

    await queueStore.enqueue(const <String, Object?>{'url': 'https://dart.dev'});
    final processed = await queueStore.processAvailable((item, delivery) {
      assert(item['url'] == 'https://dart.dev');
      delivery.ack();
    });
    assert(processed == 1);

    await stateStore.dispose();
    await queueStore.dispose();
  } finally {
    await bus.dispose();
    if (tempDir.existsSync()) {
      tempDir.deleteSync(recursive: true);
    }
  }
}
