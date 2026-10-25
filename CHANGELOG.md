# Changelog

All notable changes to the `extension_bridge` workspace are documented in this file.

## 0.1.0-dev.3

- Implemented `ContainerLayout`, `SnapshotResult<T>`, and `SharedAttachmentManager` (with APFS `clonefile(2)` staging and generation `< currentGen - 2` `@SharedState` blob garbage collection).
- Implemented `AtomicStateStore<T>` featuring two-stage `~299 ns` `notify_check` → `notify_get_state` fast-path reads, out-of-band `.tmp` staging, zero-FD `.cas` symlink leases, instant `< 1 ms` `kill(pid, 0) == ESRCH` dead-PID lease eviction, and owner-token split-brain protection.
- Implemented `SharedQueueStore<T>` and `QueueDelivery<T>` featuring lock-free Maildir (`tmp/` → `ready/` → `inflight/`) HLC ordering, `maxItems` backpressure eviction, startup `inflight/` crash recovery, and transactional `ack()`/`nack()`.
- Added Tier 2 deterministic POSIX fault-injection test suites (`atomic_state_store_test.dart` and `shared_queue_test.dart`).
- Added `ADR-001`, `ADR-003`, `ADR-004`, and expanded `packages/extension_bridge/README.md`.

## 0.1.0-dev.2

- Implemented Darwin POSIX, `<notify.h>`, `<sys/clonefile.h>`, and `<dispatch/dispatch.h>` FFI bindings (`DarwinPosixFfi`).
- Implemented shared Objective-C `_NSConcreteGlobalBlock` (`ObjCBlockLayout`) token demultiplexer (`DarwinNotifyBlockDemuxer`) and `NativeFinalizer` token lifecycle (`DarwinNotificationToken`).
- Implemented `DarwinNotificationBus` with two-stage `notify_check` (~299 ns shared-memory fast path) → `notify_get_state` (~9.3 µs Mach IPC), cold-start `0x0` seeding, O(1) self-echo suppression, and zero-disk 32-bit `@DarwinSignal` RPCs.
- Implemented `ObjCRuntimeFfi`, `AppGroupContainerResolver`, `DarwinLifecycleObserver`, `ExtensionKitHooks`, and `ApfsFileCloner` (`clonefile(2)` with `CLONE_NOOWNERCOPY` and automatic streaming fallback on `EXDEV`/`ENOTSUP`).
- Added `doc/architecture/ADR-002-notifyd-64bit-state-register-protocol.md`.

## 0.1.0-dev.1

- Initial Dart 3.6+ workspace foundation for `extension_bridge_annotation`, `extension_bridge`, and `extension_bridge_generator`.
- Added zero-dependency schema DSL annotations (`@AppGroupSchema`, `@SharedState`, `@SharedQueue`, `@DarwinSignal`, `@LiveActivitySchema`, `@BridgeModel`, `@SharedAttachment`, `@Default`, `@DefaultEnumValue`).
- Added wire protocol primitives (`KernelStateRegister`, `HybridLogicalClock`, `StateEnvelope`, and `CasLeaseToken`).
