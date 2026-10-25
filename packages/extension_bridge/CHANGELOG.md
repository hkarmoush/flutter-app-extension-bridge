# Changelog

## 0.1.0

- Implemented wire protocol primitives (`KernelStateRegister`, `HybridLogicalClock`, `StateEnvelope`, `CasLeaseToken`, and `ExtensionBridgeException`).
- Implemented Darwin `<notify.h>`, POSIX, `_NSConcreteGlobalBlock`, and `libobjc.A.dylib` FFI bindings (`DarwinPosixFfi`, `DarwinNotificationBus`, `ObjCRuntimeFfi`, `DarwinLifecycleObserver`, `ExtensionKitHooks`, `ApfsFileCloner`).
- Implemented `0xdead10cc`-proof lock-free storage engine (`ContainerLayout`, `AtomicStateStore<T>`, `SharedQueueStore<T>`, `SharedAttachmentManager`, and `SnapshotResult<T>`).
