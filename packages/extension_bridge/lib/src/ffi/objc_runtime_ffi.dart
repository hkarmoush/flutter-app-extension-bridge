import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../protocol/bridge_exception.dart';
import 'objc_block_ffi.dart';

typedef _ObjCGetClassNative = Pointer<Void> Function(Pointer<Utf8> name);
typedef _ObjCGetClassDart = Pointer<Void> Function(Pointer<Utf8> name);

typedef _SelRegisterNameNative = Pointer<Void> Function(Pointer<Utf8> name);
typedef _SelRegisterNameDart = Pointer<Void> Function(Pointer<Utf8> name);

typedef _ObjCAutoreleasePoolPushNative = Pointer<Void> Function();
typedef _ObjCAutoreleasePoolPushDart = Pointer<Void> Function();

typedef _ObjCAutoreleasePoolPopNative = Void Function(Pointer<Void> pool);
typedef _ObjCAutoreleasePoolPopDart = void Function(Pointer<Void> pool);

// Typed objc_msgSend signatures required by arm64 / x86_64 C ABI.
typedef _MsgSendIdNoArgsNative = Pointer<Void> Function(
  Pointer<Void> receiver,
  Pointer<Void> selector,
);
typedef _MsgSendIdNoArgsDart = Pointer<Void> Function(
  Pointer<Void> receiver,
  Pointer<Void> selector,
);

typedef _MsgSendIdPtrArgNative = Pointer<Void> Function(
  Pointer<Void> receiver,
  Pointer<Void> selector,
  Pointer<Void> arg1,
);
typedef _MsgSendIdPtrArgDart = Pointer<Void> Function(
  Pointer<Void> receiver,
  Pointer<Void> selector,
  Pointer<Void> arg1,
);

typedef _MsgSendVoidPtrArgNative = Void Function(
  Pointer<Void> receiver,
  Pointer<Void> selector,
  Pointer<Void> arg1,
);
typedef _MsgSendVoidPtrArgDart = void Function(
  Pointer<Void> receiver,
  Pointer<Void> selector,
  Pointer<Void> arg1,
);

typedef _MsgSendVoidTwoPtrArgsNative = Void Function(
  Pointer<Void> receiver,
  Pointer<Void> selector,
  Pointer<Void> arg1,
  Pointer<Void> arg2,
);
typedef _MsgSendVoidTwoPtrArgsDart = void Function(
  Pointer<Void> receiver,
  Pointer<Void> selector,
  Pointer<Void> arg1,
  Pointer<Void> arg2,
);

typedef _MsgSendAddObserverNative = Pointer<Void> Function(
  Pointer<Void> receiver,
  Pointer<Void> selector,
  Pointer<Void> name,
  Pointer<Void> object,
  Pointer<Void> queue,
  Pointer<Void> block,
);
typedef _MsgSendAddObserverDart = Pointer<Void> Function(
  Pointer<Void> receiver,
  Pointer<Void> selector,
  Pointer<Void> name,
  Pointer<Void> object,
  Pointer<Void> queue,
  Pointer<Void> block,
);

/// {@template extension_bridge.objc_runtime_ffi}
/// Pure-Dart Objective-C runtime bridge (`libobjc.A.dylib` +
/// `Foundation.framework`) using typed `objc_msgSend` invocations.
///
/// Enables `package:extension_bridge` to resolve App Group container URLs via
/// `NSFileManager` and observe application foreground resume notifications via
/// `NSNotificationCenter` with **zero compiled plugin binary** and **zero
/// dependency on `package:flutter`**.
/// {@endtemplate}
final class ObjCRuntimeFfi {
  /// {@macro extension_bridge.objc_runtime_ffi}
  ObjCRuntimeFfi({DynamicLibrary? objcLibrary})
      : _objc = objcLibrary ?? _openObjCLibrary() {
    _ensureFoundationLoaded();

    _objcGetClass = _objc
        .lookupFunction<_ObjCGetClassNative, _ObjCGetClassDart>('objc_getClass');
    _selRegisterName = _objc.lookupFunction<_SelRegisterNameNative,
        _SelRegisterNameDart>('sel_registerName');
    _autoreleasePoolPush = _objc.lookupFunction<_ObjCAutoreleasePoolPushNative,
        _ObjCAutoreleasePoolPushDart>('objc_autoreleasePoolPush');
    _autoreleasePoolPop = _objc.lookupFunction<_ObjCAutoreleasePoolPopNative,
        _ObjCAutoreleasePoolPopDart>('objc_autoreleasePoolPop');

    final msgSendPtr = _objc.lookup<NativeFunction<Void Function()>>(
      'objc_msgSend',
    );
    _msgSendIdNoArgs = msgSendPtr
        .cast<NativeFunction<_MsgSendIdNoArgsNative>>()
        .asFunction<_MsgSendIdNoArgsDart>();
    _msgSendIdPtrArg = msgSendPtr
        .cast<NativeFunction<_MsgSendIdPtrArgNative>>()
        .asFunction<_MsgSendIdPtrArgDart>();
    _msgSendVoidPtrArg = msgSendPtr
        .cast<NativeFunction<_MsgSendVoidPtrArgNative>>()
        .asFunction<_MsgSendVoidPtrArgDart>();
    _msgSendVoidTwoPtrArgs = msgSendPtr
        .cast<NativeFunction<_MsgSendVoidTwoPtrArgsNative>>()
        .asFunction<_MsgSendVoidTwoPtrArgsDart>();
    _msgSendAddObserver = msgSendPtr
        .cast<NativeFunction<_MsgSendAddObserverNative>>()
        .asFunction<_MsgSendAddObserverDart>();
  }

  /// Lazily initialized singleton bound to `libobjc.A.dylib`.
  static final ObjCRuntimeFfi instance = ObjCRuntimeFfi();

  static DynamicLibrary _openObjCLibrary() {
    if (Platform.isMacOS || Platform.isIOS) {
      return DynamicLibrary.open('/usr/lib/libobjc.A.dylib');
    }
    return DynamicLibrary.process();
  }

  static void _ensureFoundationLoaded() {
    if (!Platform.isMacOS && !Platform.isIOS) return;
    try {
      DynamicLibrary.open(
        '/System/Library/Frameworks/Foundation.framework/Foundation',
      );
    } on Object {
      // Foundation is already linked in the process address space.
    }
  }

  final DynamicLibrary _objc;

  late final _ObjCGetClassDart _objcGetClass;
  late final _SelRegisterNameDart _selRegisterName;
  late final _ObjCAutoreleasePoolPushDart _autoreleasePoolPush;
  late final _ObjCAutoreleasePoolPopDart _autoreleasePoolPop;

  late final _MsgSendIdNoArgsDart _msgSendIdNoArgs;
  late final _MsgSendIdPtrArgDart _msgSendIdPtrArg;
  late final _MsgSendVoidPtrArgDart _msgSendVoidPtrArg;
  late final _MsgSendVoidTwoPtrArgsDart _msgSendVoidTwoPtrArgs;
  late final _MsgSendAddObserverDart _msgSendAddObserver;

  // Cached classes & selectors.
  Pointer<Void>? _nsStringClass;
  Pointer<Void>? _nsFileManagerClass;
  Pointer<Void>? _nsNotificationCenterClass;

  Pointer<Void>? _selStringWithUtf8String;
  Pointer<Void>? _selUtf8String;
  Pointer<Void>? _selDefaultManager;
  Pointer<Void>? _selContainerUrlForGroup;
  Pointer<Void>? _selPath;
  Pointer<Void>? _selDefaultCenter;
  Pointer<Void>? _selAddObserverForName;
  Pointer<Void>? _selRemoveObserver;
  Pointer<Void>? _selPostNotificationNameObject;

  /// Looks up an Objective-C `Class` pointer by [className], returning
  /// [nullptr] if the class is not registered in the runtime.
  Pointer<Void> getClass(String className) => using((Arena arena) {
        final namePtr = className.toNativeUtf8(allocator: arena);
        return _objcGetClass(namePtr);
      });

  /// Registers or looks up an Objective-C `SEL` pointer by [selectorName].
  Pointer<Void> getSelector(String selectorName) => using((Arena arena) {
        final selPtr = selectorName.toNativeUtf8(allocator: arena);
        return _selRegisterName(selPtr);
      });

  /// Executes [action] inside a scoped Objective-C `@autoreleasepool` block so
  /// temporary Foundation objects (`NSString`, `NSURL`) are drained
  /// immediately even on background Dart isolate threads.
  T withAutoreleasePool<T>(T Function() action) {
    final pool = _autoreleasePoolPush();
    try {
      return action();
    } finally {
      _autoreleasePoolPop(pool);
    }
  }

  /// Creates an autoreleased `NSString *` from a Dart [value].
  Pointer<Void> toNSString(String value, {required Allocator allocator}) {
    final cls = _nsStringClass ??= getClass('NSString');
    final sel =
        _selStringWithUtf8String ??= getSelector('stringWithUTF8String:');
    if (cls == nullptr) return nullptr;
    final utf8Ptr = value.toNativeUtf8(allocator: allocator);
    return _msgSendIdPtrArg(cls, sel, utf8Ptr.cast<Void>());
  }

  /// Converts an Objective-C `NSString *` pointer to a Dart [String], or `null`
  /// if [nsString] is [nullptr].
  String? fromNSString(Pointer<Void> nsString) {
    if (nsString == nullptr) return null;
    final sel = _selUtf8String ??= getSelector('UTF8String');
    final cStrPtr = _msgSendIdNoArgs(nsString, sel).cast<Utf8>();
    if (cStrPtr == nullptr) return null;
    return cStrPtr.toDartString();
  }

  /// Queries `[[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:groupId].path`.
  ///
  /// Returns the absolute filesystem path to the shared App Group container, or
  /// `null` if [groupId] is empty or the current process is not entitled for
  /// [groupId] on iOS.
  String? containerPathForAppGroup(String groupId) {
    if (groupId.trim().isEmpty) return null;
    return withAutoreleasePool(
      () => using((Arena arena) {
        final fmClass = _nsFileManagerClass ??= getClass('NSFileManager');
        if (fmClass == nullptr) return null;

        final selDefaultManager =
            _selDefaultManager ??= getSelector('defaultManager');
        final selContainerUrl = _selContainerUrlForGroup ??= getSelector(
          'containerURLForSecurityApplicationGroupIdentifier:',
        );
        final selPath = _selPath ??= getSelector('path');

        final fileManager = _msgSendIdNoArgs(fmClass, selDefaultManager);
        if (fileManager == nullptr) return null;

        final nsGroupId = toNSString(groupId, allocator: arena);
        if (nsGroupId == nullptr) return null;

        final containerUrl = _msgSendIdPtrArg(
          fileManager,
          selContainerUrl,
          nsGroupId,
        );
        if (containerUrl == nullptr) return null;

        final nsPath = _msgSendIdNoArgs(containerUrl, selPath);
        return fromNSString(nsPath);
      }),
    );
  }

  /// Subscribes [block] to [notificationName] on
  /// `[NSNotificationCenter defaultCenter]` (`addObserverForName:object:queue:usingBlock:`).
  ///
  /// Returns the opaque `id` observer token required by
  /// [removeNotificationObserver].
  Pointer<Void> addNotificationObserver({
    required String notificationName,
    required ObjCNotificationBlock block,
  }) =>
      withAutoreleasePool(
        () => using((Arena arena) {
          final ncClass = _nsNotificationCenterClass ??=
              getClass('NSNotificationCenter');
          if (ncClass == nullptr) return nullptr;

          final selDefaultCenter =
              _selDefaultCenter ??= getSelector('defaultCenter');
          final selAddObserver = _selAddObserverForName ??= getSelector(
            'addObserverForName:object:queue:usingBlock:',
          );

          final center = _msgSendIdNoArgs(ncClass, selDefaultCenter);
          if (center == nullptr) return nullptr;

          final nsName = toNSString(notificationName, allocator: arena);
          if (nsName == nullptr) return nullptr;

          return _msgSendAddObserver(
            center,
            selAddObserver,
            nsName,
            nullptr,
            nullptr,
            block.blockPointer,
          );
        }),
      );

  /// Removes a previously registered [observerToken] from
  /// `[NSNotificationCenter defaultCenter]`.
  void removeNotificationObserver(Pointer<Void> observerToken) {
    if (observerToken == nullptr) return;
    withAutoreleasePool(() {
      final ncClass =
          _nsNotificationCenterClass ??= getClass('NSNotificationCenter');
      if (ncClass == nullptr) return;

      final selDefaultCenter =
          _selDefaultCenter ??= getSelector('defaultCenter');
      final selRemove = _selRemoveObserver ??= getSelector('removeObserver:');

      final center = _msgSendIdNoArgs(ncClass, selDefaultCenter);
      if (center == nullptr) return;

      _msgSendVoidPtrArg(center, selRemove, observerToken);
    });
  }

  /// Posts [notificationName] to `[NSNotificationCenter defaultCenter]`.
  ///
  /// Useful in integration tests to deterministically trigger
  /// `UIApplicationDidBecomeActiveNotification` or
  /// `NSApplicationDidBecomeActiveNotification` handlers.
  void postNotification(String notificationName) {
    withAutoreleasePool(
      () => using((Arena arena) {
        final ncClass = _nsNotificationCenterClass ??=
            getClass('NSNotificationCenter');
        if (ncClass == nullptr) return;

        final selDefaultCenter =
            _selDefaultCenter ??= getSelector('defaultCenter');
        final selPost = _selPostNotificationNameObject ??=
            getSelector('postNotificationName:object:');

        final center = _msgSendIdNoArgs(ncClass, selDefaultCenter);
        if (center == nullptr) return;

        final nsName = toNSString(notificationName, allocator: arena);
        if (nsName == nullptr) return;

        _msgSendVoidTwoPtrArgs(center, selPost, nsName, nullptr);
      }),
    );
  }
}

/// {@template extension_bridge.app_group_container_resolver}
/// Resolves shared Darwin App Group (`group.*`) container directories with
/// support for local test/CLI overrides and `NSFileManager` Objective-C FFI
/// resolution.
///
/// ### Resolution Order
/// 1. Explicit in-memory override registered via [registerOverride].
/// 2. Process environment variable `EXTENSION_BRIDGE_CONTAINER_PATH`.
/// 3. Native `[[NSFileManager defaultManager] containerURLForSecurityApplicationGroupIdentifier:]`
///    resolved via [ObjCRuntimeFfi].
/// {@endtemplate}
final class AppGroupContainerResolver {
  AppGroupContainerResolver._();

  static final Map<String, String> _overrides = <String, String>{};

  /// Registers a local directory [containerPath] override for [groupId].
  ///
  /// Used by `extension_bridge sim --container-path`, multi-process chaos
  /// benchmarks, and standalone `dart test` suites running outside an
  /// Xcode-signed App Group sandbox.
  static void registerOverride(String groupId, String containerPath) {
    _overrides[groupId] = containerPath;
  }

  /// Clears a previously registered directory override for [groupId].
  static void clearOverride(String groupId) {
    _overrides.remove(groupId);
  }

  /// Clears all registered App Group container directory overrides.
  static void clearAllOverrides() {
    _overrides.clear();
  }

  /// Resolves the root directory path for [groupId].
  ///
  /// Throws a [StorageIoException] if the container cannot be resolved via
  /// overrides, `EXTENSION_BRIDGE_CONTAINER_PATH`, or `NSFileManager`.
  static String resolve(
    String groupId, {
    ObjCRuntimeFfi? objcRuntime,
    Map<String, String>? environment,
  }) {
    final overridePath = _overrides[groupId];
    if (overridePath != null && overridePath.isNotEmpty) {
      return overridePath;
    }

    final env = environment ?? Platform.environment;
    final envPath = env['EXTENSION_BRIDGE_CONTAINER_PATH'];
    if (envPath != null && envPath.isNotEmpty) {
      return envPath;
    }

    final runtime = objcRuntime ?? ObjCRuntimeFfi.instance;
    final nativePath = runtime.containerPathForAppGroup(groupId);
    if (nativePath != null && nativePath.isNotEmpty) {
      return nativePath;
    }

    throw StorageIoException(
      'Unable to resolve App Group container for "$groupId". '
      'Ensure the App Group capability is enabled in your Xcode .entitlements '
      'or register a local test container via '
      'AppGroupContainerResolver.registerOverride("$groupId", path).',
      path: groupId,
    );
  }
}
