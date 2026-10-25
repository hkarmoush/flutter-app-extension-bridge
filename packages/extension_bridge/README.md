# `extension_bridge`

**Pure-Dart `dart:ffi` Cross-Process IPC (`<notify.h>` 64-Bit Kernel State Registers), `0xdead10cc`-Proof Lock-Free Atomic Storage & Zero-Copy APFS `clonefile(2)` Maildir Queues for Flutter ↔ iOS/macOS App Extensions**

`package:extension_bridge` is the core runtime engine powering generated bridges between Flutter and Darwin App Extensions (**WidgetKit**, **iOS 17+ Interactive `AppIntents`**, **ActivityKit Live Activities & Dynamic Island**, **Share/Action Extensions**, and **iOS 18 `ControlWidget`**)—with **zero `MethodChannel` overhead** and **zero `sdk: flutter` dependency**.

---

## Key Capabilities

| Subsystem | Core Primitives | Systems Guarantees |
|---|---|---|
| **Kernel `<notify.h>` Bus** | `DarwinNotificationBus`, `KernelStateRegister`, `DarwinNotifyBlockDemuxer` | • **Stage 1 (`~299 ns`):** `notify_check` process-mapped shared-memory (`shm`) fast path (zero Mach IPC)<br>• **Stage 2 (`~9.3 µs`):** `notify_get_state` 64-bit register `[0xEB42 \| writerId \| gen]`<br>• **O(1) Self-Echo Cancellation:** Suppresses local writes & in-process iOS 17+ `AppIntent` echoes with zero disk I/O<br>• **Zero-Disk 32-Bit `@DarwinSignal` RPC:** `~19 µs` P50 cross-process wakeup |
| **Lock-Free `@SharedState` Store** | `AtomicStateStore<T>`, `SnapshotResult<T>`, `CasLeaseToken` | • **`0xdead10cc`-Proof:** Zero `flock`, `fcntl`, SQLite WAL, or `NSFileCoordinator` locks<br>• **Zero-FD Symlink CAS Loop:** Out-of-band `.tmp` serialization + atomic `symlink("<pid>:<ts>:<nonce>", ".cas")` lease + POSIX `rename(2)`<br>• **Instant Crash Recovery (`< 1 ms`):** `kill(pid, 0) == ESRCH` dead-process lease eviction + split-brain owner token verification |
| **Maildir `@SharedQueue` & Blobs** | `SharedQueueStore<T>`, `QueueDelivery<T>`, `SharedAttachmentManager`, `ApfsFileCloner` | • **Lock-Free Multi-Producer Outbox:** `tmp/` → `ready/` → `inflight/` ordered by `HybridLogicalClock`<br>• **APFS `clonefile(2)` (`CLONE_NOOWNERCOPY`):** `~0.3 ms`, `0` extra disk bytes for 200 MB 4K media attachments<br>• **At-Least-Once Crash Recovery:** Restores unacknowledged `inflight/` items on startup and GCs `@SharedState` blobs (`< currentGen - 2`) |
| **Pure-Dart ObjC & C-ABI Hooks** | `ObjCRuntimeFfi`, `AppGroupContainerResolver`, `DarwinLifecycleObserver`, `ExtensionKitHooks` | • Resolves App Group containers via `NSFileManager` (`objc_msgSend`)<br>• Auto-reconciles on `UIApplicationDidBecomeActiveNotification` / `NSApplicationDidBecomeActiveNotification`<br>• Lazily invokes `@_cdecl` `WidgetCenter`, `ControlCenter`, and `ActivityKit` hooks |

---

## Quick Usage

While most applications use `extension_bridge_generator` to generate a strongly-typed `<Name>Bridge` client from an `@AppGroupSchema` contract, you can also use `AtomicStateStore` and `SharedQueueStore` directly:

```dart
import 'dart:io';
import 'package:extension_bridge/extension_bridge.dart';

Future<void> main() async {
  final tempDir = Directory.systemTemp.createTempSync('eb_demo_');
  final layout = ContainerLayout(tempDir.path);
  final bus = DarwinNotificationBus();

  final store = AtomicStateStore<Map<String, Object?>>(
    key: 'now_playing',
    layout: layout,
    notificationBus: bus,
    notificationName: 'com.example.pulsehub.eb.state.now_playing',
    codec: StateEnvelopeCodec<Map<String, Object?>>(
      key: 'now_playing',
      encodePayload: (map) => map,
      decodePayload: (raw) => Map<String, Object?>.from(raw! as Map),
    ),
  );

  // 1. Lock-free atomic CAS update:
  store.update((current) => <String, Object?>{
    'title': 'Solar Sailer',
    'playCount': ((current?['playCount'] as int?) ?? 0) + 1,
  });

  // 2. ~299 ns shared-memory fast-path read:
  final snapshot = store.readResult();
  switch (snapshot) {
    case SnapshotHit(:final value, :final envelope, :final fromMemoryCache):
      print('Gen ${envelope.generation}: $value (cached: $fromMemoryCache)');
    case SnapshotEmpty():
      print('Empty');
  }

  await store.dispose();
  await bus.dispose();
  tempDir.deleteSync(recursive: true);
}
```

---

## Architecture Decision Records (ADRs)

- [ADR-001: Why Not `UserDefaults(suiteName:)`, SQLite WAL, or `NSFileCoordinator`?](https://github.com/hkarmoush/flutter-app-extension-bridge/blob/main/doc/architecture/ADR-001-why-not-userdefaults-or-nsfilecoordinator.md)
- [ADR-002: Darwin `<notify.h>` 64-Bit Kernel State Register Protocol & `_NSConcreteGlobalBlock` FFI Dispatch](https://github.com/hkarmoush/flutter-app-extension-bridge/blob/main/doc/architecture/ADR-002-notifyd-64bit-state-register-protocol.md)
- [ADR-003: Lock-Free Optimistic Concurrency Control (CAS), Zero-FD Symlink Leases & Instant `ESRCH` Crash Recovery](https://github.com/hkarmoush/flutter-app-extension-bridge/blob/main/doc/architecture/ADR-003-lock-free-occ-cas-and-crash-recovery.md)
- [ADR-004: Lock-Free Maildir `@SharedQueue`, Hybrid Logical Clocks & APFS `clonefile(2)` Blob Lifecycle](https://github.com/hkarmoush/flutter-app-extension-bridge/blob/main/doc/architecture/ADR-004-maildir-queues-and-apfs-clonefile.md)
- [Schema DSL Reference](https://github.com/hkarmoush/flutter-app-extension-bridge/blob/main/doc/reference/schema-dsl-reference.md)
