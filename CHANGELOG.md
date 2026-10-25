# Changelog

All notable changes to the `extension_bridge` workspace are documented in this file.

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
