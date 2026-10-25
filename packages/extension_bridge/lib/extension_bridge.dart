/// Pure-Dart FFI runtime for cross-process Darwin App Extension communication,
/// `<notify.h>` 64-bit kernel state registers, `0xdead10cc`-proof lock-free
/// atomic snapshots, and Maildir queues with APFS `clonefile(2)` attachments.
library;

export 'package:extension_bridge_annotation/extension_bridge_annotation.dart';

export 'src/ffi/apfs_clonefile.dart';
export 'src/ffi/darwin_notification_bus.dart';
export 'src/ffi/darwin_posix_ffi.dart';
export 'src/ffi/extension_kit_hooks.dart';
export 'src/ffi/objc_block_ffi.dart';
export 'src/ffi/objc_runtime_ffi.dart';
export 'src/lifecycle/darwin_lifecycle_observer.dart';
export 'src/protocol/bridge_exception.dart';
export 'src/protocol/cas_lease_token.dart';
export 'src/protocol/hybrid_logical_clock.dart';
export 'src/protocol/kernel_state_register.dart';
export 'src/protocol/state_envelope.dart';
export 'src/storage/atomic_state_store.dart';
export 'src/storage/container_layout.dart';
export 'src/storage/shared_attachment_manager.dart';
export 'src/storage/shared_queue.dart';
export 'src/storage/snapshot_result.dart';
