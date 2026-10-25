import 'dart:ffi';

import 'package:ffi/ffi.dart';

/// Clang Block ABI flag indicating a compile-time/process-lifetime global block
/// (`BLOCK_IS_GLOBAL = 1 << 28`).
///
/// When `BLOCK_IS_GLOBAL` is set and `isa` points to `_NSConcreteGlobalBlock`,
/// `_Block_copy` and `_Block_release` in `libsystem_blocks.dylib` become
/// O(1) no-ops that never copy or free the block struct.
const int kObjCBlockIsGlobalFlag = 1 << 28;

/// Clang Objective-C Block descriptor layout (`struct Block_descriptor_1`).
final class ObjCBlockDescriptor1 extends Struct {
  /// Reserved field (always `0`).
  @UintPtr()
  external int reserved;

  /// Total byte size of the owning [ObjCBlockLayout] (`sizeOf<ObjCBlockLayout>()`).
  @UintPtr()
  external int size;
}

/// Clang Objective-C Block memory layout (`struct Block_layout` from
/// `<Block_private.h>`).
///
/// ```text
/// +------------------------------------------------------------------+
/// | isa:        &_NSConcreteGlobalBlock (8 bytes)                    |
/// | flags:      BLOCK_IS_GLOBAL = 0x10000000 (4 bytes)               |
/// | reserved:   0 (4 bytes)                                          |
/// | invoke:     NativeCallable.listener.nativeFunction (8 bytes)     |
/// | descriptor: Pointer<ObjCBlockDescriptor1> (8 bytes)              |
/// +------------------------------------------------------------------+
/// ```
final class ObjCBlockLayout extends Struct {
  /// Objective-C class pointer (`_NSConcreteGlobalBlock`).
  external Pointer<Void> isa;

  /// Bitwise block flags ([kObjCBlockIsGlobalFlag]).
  @Int32()
  external int flags;

  /// Reserved alignment field (`0`).
  @Int32()
  external int reserved;

  /// C function pointer invoked when the block is called (`void (*)(void *block, ...)`).
  external Pointer<Void> invoke;

  /// Pointer to the block's static [ObjCBlockDescriptor1].
  external Pointer<ObjCBlockDescriptor1> descriptor;
}

typedef _NotifyBlockInvokeNative = Void Function(
  Pointer<Void> block,
  Int32 token,
);

typedef _NotificationObserverInvokeNative = Void Function(
  Pointer<Void> block,
  Pointer<Void> nsNotification,
);

/// {@template extension_bridge.darwin_notify_block_demuxer}
/// Shared isolate-wide Objective-C `_NSConcreteGlobalBlock` demultiplexer for
/// Darwin `<notify.h>` `notify_register_dispatch`.
///
/// Instead of allocating a separate [NativeCallable] and Objective-C block per
/// notification key, `extension_bridge` allocates a **single** static
/// [ObjCBlockLayout] backed by `_NSConcreteGlobalBlock` (`BLOCK_IS_GLOBAL`)
/// and a single [NativeCallable.listener] (`keepIsolateAlive = false`).
///
/// When `notifyd` delivers a wakeup on the GCD queue, `libdispatch` invokes the
/// global block with the integer `token`, and [DarwinNotifyBlockDemuxer]
/// routes the wakeup in O(1) to the Dart callback registered for that token.
/// {@endtemplate}
final class DarwinNotifyBlockDemuxer {
  DarwinNotifyBlockDemuxer._() {
    final processLib = DynamicLibrary.process();
    final globalBlockIsa = processLib.lookup<Void>('_NSConcreteGlobalBlock');

    _callable = NativeCallable<_NotifyBlockInvokeNative>.listener(
      _onNativeDispatch,
    )..keepIsolateAlive = false;

    _descriptor = calloc<ObjCBlockDescriptor1>()
      ..ref.reserved = 0
      ..ref.size = sizeOf<ObjCBlockLayout>();

    _block = calloc<ObjCBlockLayout>()
      ..ref.isa = globalBlockIsa
      ..ref.flags = kObjCBlockIsGlobalFlag
      ..ref.reserved = 0
      ..ref.invoke = _callable.nativeFunction.cast<Void>()
      ..ref.descriptor = _descriptor;
  }

  /// Shared singleton demultiplexer for the current Dart isolate.
  static final DarwinNotifyBlockDemuxer instance = DarwinNotifyBlockDemuxer._();

  late final NativeCallable<_NotifyBlockInvokeNative> _callable;
  late final Pointer<ObjCBlockDescriptor1> _descriptor;
  late final Pointer<ObjCBlockLayout> _block;

  final Map<int, WeakReference<Object>> _tokenOwners =
      <int, WeakReference<Object>>{};
  final Map<int, void Function(int token)> _handlers =
      <int, void Function(int token)>{};

  static final Finalizer<int> _ownerFinalizer = Finalizer<int>(
    instance.unregisterToken,
  );

  /// Pointer to the static Objective-C `void (^)(int token)` block suitable for
  /// passing to `notify_register_dispatch`.
  Pointer<Void> get blockPointer => _block.cast<Void>();

  /// Number of active `<notify.h>` tokens currently registered in the
  /// demultiplexer.
  int get activeTokenCount => _handlers.length;

  /// Associates `<notify.h>` [token] with [handler].
  ///
  /// When [owner] is provided, [handler] must not strongly capture [owner]; a
  /// Dart [Finalizer] is attached to [owner] so that if [owner] is garbage
  /// collected without an explicit [unregisterToken] call, the [token] mapping
  /// is automatically removed from the demultiplexer.
  void registerToken(
    int token,
    void Function(int token) handler, {
    Object? owner,
  }) {
    _handlers[token] = handler;
    if (owner != null) {
      _tokenOwners[token] = WeakReference<Object>(owner);
      _ownerFinalizer.attach(owner, token, detach: owner);
    }
  }

  /// Removes the handler associated with `<notify.h>` [token].
  void unregisterToken(int token, {Object? detachOwner}) {
    if (detachOwner != null) {
      _ownerFinalizer.detach(detachOwner);
    }
    _tokenOwners.remove(token);
    _handlers.remove(token);
  }

  void _onNativeDispatch(Pointer<Void> _, int token) {
    final ownerRef = _tokenOwners[token];
    if (ownerRef != null && ownerRef.target == null) {
      _tokenOwners.remove(token);
      _handlers.remove(token);
      return;
    }
    final handler = _handlers[token];
    if (handler != null) {
      handler(token);
    }
  }
}

/// {@template extension_bridge.objc_notification_block}
/// Disposable Objective-C `void (^)(NSNotification *)` block wrapper backed by
/// `_NSConcreteGlobalBlock` and a [NativeCallable.listener] (`keepIsolateAlive = false`).
///
/// Used by `DarwinLifecycleObserver` to subscribe to
/// `UIApplicationDidBecomeActiveNotification` and
/// `NSApplicationDidBecomeActiveNotification` on `NSNotificationCenter` without
/// depending on `package:flutter`.
///
/// **Lifetime Note:** Because [NativeCallable.listener] dispatches onto the
/// Dart isolate's event loop asynchronously after the synchronous Objective-C
/// block invocation returns, the raw `NSNotification *` pointer passed to the
/// callback may already be autoreleased by the time the Dart callback runs and
/// must not be dereferenced via `objc_msgSend`.
/// {@endtemplate}
final class ObjCNotificationBlock {
  /// {@macro extension_bridge.objc_notification_block}
  ObjCNotificationBlock(void Function(Pointer<Void> notification) onInvoke)
      : _onInvoke = onInvoke {
    final processLib = DynamicLibrary.process();
    final globalBlockIsa = processLib.lookup<Void>('_NSConcreteGlobalBlock');

    _callable = NativeCallable<_NotificationObserverInvokeNative>.listener(
      _handleInvoke,
    )..keepIsolateAlive = false;

    _descriptor = calloc<ObjCBlockDescriptor1>()
      ..ref.reserved = 0
      ..ref.size = sizeOf<ObjCBlockLayout>();

    _block = calloc<ObjCBlockLayout>()
      ..ref.isa = globalBlockIsa
      ..ref.flags = kObjCBlockIsGlobalFlag
      ..ref.reserved = 0
      ..ref.invoke = _callable.nativeFunction.cast<Void>()
      ..ref.descriptor = _descriptor;
  }

  final void Function(Pointer<Void> notification) _onInvoke;
  late final NativeCallable<_NotificationObserverInvokeNative> _callable;
  late final Pointer<ObjCBlockDescriptor1> _descriptor;
  late final Pointer<ObjCBlockLayout> _block;
  bool _isDisposed = false;

  /// Whether [dispose] has been called on this block.
  bool get isDisposed => _isDisposed;

  /// Raw Objective-C block pointer (`id` / `void (^)(NSNotification *)`).
  Pointer<Void> get blockPointer => _block.cast<Void>();

  void _handleInvoke(Pointer<Void> _, Pointer<Void> notification) {
    if (_isDisposed) return;
    _onInvoke(notification);
  }

  /// Closes the underlying [NativeCallable] and frees the block structures.
  ///
  /// Must only be called **after** the observer has been unregistered from
  /// `NSNotificationCenter`.
  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    _callable.close();
    calloc.free(_block);
    calloc.free(_descriptor);
  }
}
