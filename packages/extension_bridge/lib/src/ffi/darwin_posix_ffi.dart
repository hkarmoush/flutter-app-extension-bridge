import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

/// Status codes returned by Darwin's `<notify.h>` (`libsystem_notify.dylib`).
abstract final class NotifyStatus {
  /// Notification subsystem call succeeded (`NOTIFY_STATUS_OK = 0`).
  static const int ok = 0;

  /// Notification name string is invalid (`NOTIFY_STATUS_INVALID_NAME = 1`).
  static const int invalidName = 1;

  /// Token integer is not registered or already canceled
  /// (`NOTIFY_STATUS_INVALID_TOKEN = 2`).
  static const int invalidToken = 2;

  /// Mach port is invalid (`NOTIFY_STATUS_INVALID_PORT = 3`).
  static const int invalidPort = 3;

  /// File descriptor is invalid (`NOTIFY_STATUS_INVALID_FILE = 4`).
  static const int invalidFile = 4;

  /// Signal number is invalid (`NOTIFY_STATUS_INVALID_SIGNAL = 5`).
  static const int invalidSignal = 5;

  /// Malformed request to `notifyd` (`NOTIFY_STATUS_INVALID_REQUEST = 6`).
  static const int invalidRequest = 6;

  /// Caller is not authorized for the notification key
  /// (`NOTIFY_STATUS_NOT_AUTHORIZED = 7`).
  static const int notAuthorized = 7;

  /// Notification subsystem option is disabled (`NOTIFY_STATUS_OPT_DISABLE = 8`).
  static const int optDisable = 8;

  /// `notifyd` server could not be reached (`NOTIFY_STATUS_SERVER_NOT_FOUND = 9`).
  static const int serverNotFound = 9;

  /// Null pointer passed to `<notify.h>` (`NOTIFY_STATUS_NULL_INPUT = 10`).
  static const int nullInput = 10;

  /// Generic failure in `libsystem_notify` (`NOTIFY_STATUS_FAILED = 1000000`).
  static const int failed = 1000000;
}

/// Sentinel value (`-1`) representing an uninitialized or canceled `<notify.h>`
/// registration token (`NOTIFY_TOKEN_INVALID`).
const int kNotifyTokenInvalid = -1;

/// Darwin `<sys/clonefile.h>` flags for `clonefile(2)`.
abstract final class ClonefileFlags {
  /// Do not follow symbolic links when cloning (`CLONE_NOFOLLOW = 0x0001`).
  static const int noFollow = 0x0001;

  /// Do not copy file owner UID/GID if caller is non-root
  /// (`CLONE_NOOWNERCOPY = 0x0002`).
  ///
  /// Required when cloning media files across extension temporary directories
  /// and App Group containers to prevent `EPERM`.
  static const int noOwnerCopy = 0x0002;

  /// Copy access control lists (`CLONE_ACL = 0x0004`).
  static const int acl = 0x0004;
}

/// Standard Darwin POSIX `errno` constants from `<sys/errno.h>`.
abstract final class DarwinErrno {
  /// Operation not permitted (`EPERM = 1`).
  static const int eperm = 1;

  /// No such file or directory (`ENOENT = 2`).
  static const int enoent = 2;

  /// No such process (`ESRCH = 3`).
  ///
  /// Returned by `kill(pid, 0)` when the target PID has terminated (`SIGKILL`
  /// or Jetsam OOM), enabling instant `< 1 ms` `.cas` symlink lease eviction.
  static const int esrch = 3;

  /// Interrupted system call (`EINTR = 4`).
  static const int eintr = 4;

  /// Permission denied (`EACCES = 13`).
  static const int eacces = 13;

  /// File or symlink already exists (`EEXIST = 17`).
  static const int eexist = 17;

  /// Cross-device link (`EXDEV = 18`).
  ///
  /// Returned by `clonefile(2)` when source and destination reside on different
  /// mounted volumes.
  static const int exdev = 18;

  /// Invalid argument (`EINVAL = 22`).
  static const int einval = 22;

  /// Operation not supported on filesystem (`ENOTSUP = 45`).
  static const int enotsup = 45;

  /// Function not implemented (`ENOSYS = 78`).
  static const int enosys = 78;
}

/// Grand Central Dispatch (`<dispatch/dispatch.h>`) Quality-of-Service classes
/// passed to `dispatch_get_global_queue`.
abstract final class DispatchQosClass {
  /// Highest interactive priority (`QOS_CLASS_USER_INTERACTIVE = 0x21`).
  static const int userInteractive = 0x21;

  /// User-initiated priority (`QOS_CLASS_USER_INITIATED = 0x19`).
  static const int userInitiated = 0x19;

  /// Default priority (`QOS_CLASS_DEFAULT = 0x15`).
  static const int defaultQos = 0x15;

  /// Utility background priority (`QOS_CLASS_UTILITY = 0x11`).
  static const int utility = 0x11;
}

// --- Native C Function Typedefs ---

typedef _NotifyRegisterDispatchNative = Uint32 Function(
  Pointer<Utf8> name,
  Pointer<Int32> outToken,
  Pointer<Void> queue,
  Pointer<Void> handlerBlock,
);
typedef _NotifyRegisterDispatchDart = int Function(
  Pointer<Utf8> name,
  Pointer<Int32> outToken,
  Pointer<Void> queue,
  Pointer<Void> handlerBlock,
);

typedef _NotifyRegisterCheckNative = Uint32 Function(
  Pointer<Utf8> name,
  Pointer<Int32> outToken,
);
typedef _NotifyRegisterCheckDart = int Function(
  Pointer<Utf8> name,
  Pointer<Int32> outToken,
);

typedef _NotifyCheckNative = Uint32 Function(
  Int32 token,
  Pointer<Int32> check,
);
typedef _NotifyCheckDart = int Function(
  int token,
  Pointer<Int32> check,
);

typedef _NotifyPostNative = Uint32 Function(Pointer<Utf8> name);
typedef _NotifyPostDart = int Function(Pointer<Utf8> name);

typedef _NotifySetStateNative = Uint32 Function(Int32 token, Uint64 state64);
typedef _NotifySetStateDart = int Function(int token, int state64);

typedef _NotifyGetStateNative = Uint32 Function(
  Int32 token,
  Pointer<Uint64> state64,
);
typedef _NotifyGetStateDart = int Function(
  int token,
  Pointer<Uint64> state64,
);

typedef _NotifyCancelNative = Uint32 Function(Int32 token);
typedef _NotifyCancelDart = int Function(int token);

typedef _NotifyIsValidTokenNative = Bool Function(Int32 val);
typedef _NotifyIsValidTokenDart = bool Function(int val);

typedef _DispatchGetGlobalQueueNative = Pointer<Void> Function(
  IntPtr identifier,
  UintPtr flags,
);
typedef _DispatchGetGlobalQueueDart = Pointer<Void> Function(
  int identifier,
  int flags,
);

typedef _ClonefileNative = Int32 Function(
  Pointer<Utf8> src,
  Pointer<Utf8> dst,
  Uint32 flags,
);
typedef _ClonefileDart = int Function(
  Pointer<Utf8> src,
  Pointer<Utf8> dst,
  int flags,
);

typedef _RenameNative = Int32 Function(
  Pointer<Utf8> oldPath,
  Pointer<Utf8> newPath,
);
typedef _RenameDart = int Function(
  Pointer<Utf8> oldPath,
  Pointer<Utf8> newPath,
);

typedef _UnlinkNative = Int32 Function(Pointer<Utf8> path);
typedef _UnlinkDart = int Function(Pointer<Utf8> path);

typedef _SymlinkNative = Int32 Function(
  Pointer<Utf8> target,
  Pointer<Utf8> linkPath,
);
typedef _SymlinkDart = int Function(
  Pointer<Utf8> target,
  Pointer<Utf8> linkPath,
);

typedef _ReadlinkNative = IntPtr Function(
  Pointer<Utf8> path,
  Pointer<Uint8> buf,
  IntPtr bufSize,
);
typedef _ReadlinkDart = int Function(
  Pointer<Utf8> path,
  Pointer<Uint8> buf,
  int bufSize,
);

typedef _KillNative = Int32 Function(Int32 pid, Int32 sig);
typedef _KillDart = int Function(int pid, int sig);

typedef _GetpidNative = Int32 Function();
typedef _GetpidDart = int Function();

typedef _ErrorNative = Pointer<Int32> Function();
typedef _ErrorDart = Pointer<Int32> Function();

/// {@template extension_bridge.darwin_posix_ffi}
/// Low-level `dart:ffi` bindings to Darwin's `libSystem.B.dylib` (exposed via
/// [DynamicLibrary.process]), covering `<notify.h>`, `<sys/clonefile.h>`,
/// `<dispatch/dispatch.h>`, and POSIX filesystem/process primitives.
///
/// Works identically across Flutter iOS/macOS apps, background Dart Isolates,
/// standalone `dart test` runs, and `dart run` CLI processes with zero
/// dependency on `package:flutter`.
/// {@endtemplate}
final class DarwinPosixFfi {
  /// {@macro extension_bridge.darwin_posix_ffi}
  DarwinPosixFfi({DynamicLibrary? library})
      : _lib = library ?? DynamicLibrary.process() {
    _notifyRegisterDispatch = _lib.lookupFunction<
        _NotifyRegisterDispatchNative,
        _NotifyRegisterDispatchDart>('notify_register_dispatch');
    _notifyRegisterCheck = _lib.lookupFunction<_NotifyRegisterCheckNative,
        _NotifyRegisterCheckDart>('notify_register_check');
    _notifyCheck = _lib
        .lookupFunction<_NotifyCheckNative, _NotifyCheckDart>('notify_check');
    _notifyPost =
        _lib.lookupFunction<_NotifyPostNative, _NotifyPostDart>('notify_post');
    _notifySetState =
        _lib.lookupFunction<_NotifySetStateNative, _NotifySetStateDart>(
      'notify_set_state',
    );
    _notifyGetState =
        _lib.lookupFunction<_NotifyGetStateNative, _NotifyGetStateDart>(
      'notify_get_state',
    );
    _notifyCancel = _lib
        .lookupFunction<_NotifyCancelNative, _NotifyCancelDart>('notify_cancel');
    _notifyCancelPtr =
        _lib.lookup<NativeFunction<Void Function(Pointer<Void>)>>(
      'notify_cancel',
    );
    _notifyIsValidToken = _lib.lookupFunction<_NotifyIsValidTokenNative,
        _NotifyIsValidTokenDart>('notify_is_valid_token');
    _dispatchGetGlobalQueue = _lib.lookupFunction<
        _DispatchGetGlobalQueueNative,
        _DispatchGetGlobalQueueDart>('dispatch_get_global_queue');
    _clonefile =
        _lib.lookupFunction<_ClonefileNative, _ClonefileDart>('clonefile');
    _rename = _lib.lookupFunction<_RenameNative, _RenameDart>('rename');
    _unlink = _lib.lookupFunction<_UnlinkNative, _UnlinkDart>('unlink');
    _symlink = _lib.lookupFunction<_SymlinkNative, _SymlinkDart>('symlink');
    _readlink = _lib.lookupFunction<_ReadlinkNative, _ReadlinkDart>('readlink');
    _kill = _lib.lookupFunction<_KillNative, _KillDart>('kill');
    _getpid = _lib.lookupFunction<_GetpidNative, _GetpidDart>('getpid');
    _errnoLocation = _lib.lookupFunction<_ErrorNative, _ErrorDart>('__error');
  }

  /// Lazily initialized singleton bound to [DynamicLibrary.process].
  static final DarwinPosixFfi instance = DarwinPosixFfi();

  /// Whether the current host OS supports Darwin `<notify.h>` and APFS
  /// `clonefile(2)` (`Platform.isMacOS || Platform.isIOS`).
  static bool get isSupportedPlatform => Platform.isMacOS || Platform.isIOS;

  final DynamicLibrary _lib;

  late final _NotifyRegisterDispatchDart _notifyRegisterDispatch;
  late final _NotifyRegisterCheckDart _notifyRegisterCheck;
  late final _NotifyCheckDart _notifyCheck;
  late final _NotifyPostDart _notifyPost;
  late final _NotifySetStateDart _notifySetState;
  late final _NotifyGetStateDart _notifyGetState;
  late final _NotifyCancelDart _notifyCancel;
  late final Pointer<NativeFunction<Void Function(Pointer<Void>)>>
      _notifyCancelPtr;
  late final _NotifyIsValidTokenDart _notifyIsValidToken;
  late final _DispatchGetGlobalQueueDart _dispatchGetGlobalQueue;
  late final _ClonefileDart _clonefile;
  late final _RenameDart _rename;
  late final _UnlinkDart _unlink;
  late final _SymlinkDart _symlink;
  late final _ReadlinkDart _readlink;
  late final _KillDart _kill;
  late final _GetpidDart _getpid;
  late final _ErrorDart _errnoLocation;

  /// Native symbol pointer to `notify_cancel` suitable for attaching a
  /// [NativeFinalizer] to notification token handles.
  ///
  /// Because both AAPCS64 (arm64) and System V AMD64 (x86_64) pass the first
  /// integer/pointer argument in the primary register (`x0`/`w0` on arm64,
  /// `rdi`/`edi` on x86_64), passing `Pointer<Void>.fromAddress(token)` as the
  /// finalizer token invokes `notify_cancel(token)` directly with zero native
  /// heap allocation.
  Pointer<NativeFunction<Void Function(Pointer<Void>)>>
      get notifyCancelFinalizerSymbol => _notifyCancelPtr;

  /// Reads the current thread-local POSIX `errno` value via Darwin's
  /// `__error()` function.
  int get lastErrno => _errnoLocation().value;

  /// Sets the current thread-local POSIX `errno` value.
  set lastErrno(int value) {
    _errnoLocation().value = value;
  }

  /// Returns the current OS process identifier (`getpid(2)`).
  int getpid() => _getpid();

  /// Sends signal [sig] to process [pid] (`kill(2)`).
  ///
  /// Passing `sig = 0` performs an existence check without sending a signal:
  /// returns `0` if the process is alive and owned by the caller, or `-1`
  /// (with [lastErrno] set to [DarwinErrno.esrch] if the process does not
  /// exist, or [DarwinErrno.eperm] if it is alive under a different UID).
  int kill(int pid, int sig) {
    lastErrno = 0;
    return _kill(pid, sig);
  }

  /// Returns `true` if OS process [pid] is currently alive in the Darwin
  /// kernel process table.
  ///
  /// Uses `kill(pid, 0)`:
  /// - Returns `true` if `kill` succeeds (`0`) or fails with `EPERM` (the
  ///   process exists under another UID).
  /// - Returns `false` if `kill` fails with `ESRCH` (process terminated via
  ///   `SIGKILL`, Jetsam OOM, or normal exit) or if `pid <= 0`.
  bool isProcessAlive(int pid) {
    if (pid <= 0) return false;
    final res = kill(pid, 0);
    if (res == 0) return true;
    return lastErrno == DarwinErrno.eperm;
  }

  /// Returns the global GCD queue (`dispatch_get_global_queue`) for [qosClass].
  Pointer<Void> getGlobalQueue({
    int qosClass = DispatchQosClass.userInteractive,
    int flags = 0,
  }) =>
      _dispatchGetGlobalQueue(qosClass, flags);

  /// Registers a shared-memory check token for [name] via
  /// `notify_register_check`.
  ///
  /// Returns a record of `(status, token)`.
  ({int status, int token}) notifyRegisterCheck(String name) =>
      using((Arena arena) {
        final namePtr = name.toNativeUtf8(allocator: arena);
        final outToken = arena<Int32>()..value = kNotifyTokenInvalid;
        final status = _notifyRegisterCheck(namePtr, outToken);
        return (status: status, token: outToken.value);
      });

  /// Registers an Objective-C dispatch block [handlerBlock] on [queue] for
  /// [name] via `notify_register_dispatch`.
  ///
  /// Returns a record of `(status, token)`.
  ({int status, int token}) notifyRegisterDispatch({
    required String name,
    required Pointer<Void> queue,
    required Pointer<Void> handlerBlock,
  }) =>
      using((Arena arena) {
        final namePtr = name.toNativeUtf8(allocator: arena);
        final outToken = arena<Int32>()..value = kNotifyTokenInvalid;
        final status = _notifyRegisterDispatch(
          namePtr,
          outToken,
          queue,
          handlerBlock,
        );
        return (status: status, token: outToken.value);
      });

  /// Checks whether [token] has received any notifications since the previous
  /// `notify_check` call (`~299 ns` shared-memory slot read, zero Mach IPC).
  ///
  /// Returns `(status, changed)` where `changed == true` when `check != 0`.
  ({int status, bool changed}) notifyCheck(int token) => using((Arena arena) {
        final checkPtr = arena<Int32>()..value = 0;
        final status = _notifyCheck(token, checkPtr);
        return (status: status, changed: checkPtr.value != 0);
      });

  /// Posts a Darwin notification for [name] via `notify_post`.
  int notifyPost(String name) => using((Arena arena) {
        final namePtr = name.toNativeUtf8(allocator: arena);
        return _notifyPost(namePtr);
      });

  /// Writes the 64-bit integer [state64] into the kernel register associated
  /// with [token] via `notify_set_state`.
  int notifySetState(int token, int state64) =>
      _notifySetState(token, state64);

  /// Reads the 64-bit integer register associated with [token] via
  /// `notify_get_state` (`~9.3 µs` Mach IPC to `notifyd`).
  ({int status, int state64}) notifyGetState(int token) =>
      using((Arena arena) {
        final statePtr = arena<Uint64>()..value = 0;
        final status = _notifyGetState(token, statePtr);
        return (status: status, state64: statePtr.value);
      });

  /// Cancels and releases a `<notify.h>` registration [token] via
  /// `notify_cancel`.
  int notifyCancel(int token) => _notifyCancel(token);

  /// Returns `true` if [token] is considered valid by `notify_is_valid_token`.
  bool notifyIsValidToken(int token) => _notifyIsValidToken(token);

  /// Executes Darwin's APFS Copy-on-Write `clonefile(2)` syscall from
  /// [sourcePath] to [destinationPath] with [flags].
  ///
  /// Returns `0` on success, or the positive POSIX `errno` on failure.
  int clonefile(
    String sourcePath,
    String destinationPath, {
    int flags = ClonefileFlags.noOwnerCopy,
  }) =>
      using((Arena arena) {
        final srcPtr = sourcePath.toNativeUtf8(allocator: arena);
        final dstPtr = destinationPath.toNativeUtf8(allocator: arena);
        lastErrno = 0;
        final result = _clonefile(srcPtr, dstPtr, flags);
        if (result == 0) return 0;
        final err = lastErrno;
        return err != 0 ? err : DarwinErrno.einval;
      });

  /// Atomically renames [oldPath] to [newPath] via POSIX `rename(2)`.
  ///
  /// Returns `0` on success, or the positive POSIX `errno` on failure.
  int rename(String oldPath, String newPath) => using((Arena arena) {
        final oldPtr = oldPath.toNativeUtf8(allocator: arena);
        final newPtr = newPath.toNativeUtf8(allocator: arena);
        lastErrno = 0;
        final result = _rename(oldPtr, newPtr);
        if (result == 0) return 0;
        final err = lastErrno;
        return err != 0 ? err : DarwinErrno.einval;
      });

  /// Unlinks (deletes) the directory entry at [path] via POSIX `unlink(2)`.
  ///
  /// Returns `0` on success, or the positive POSIX `errno` on failure.
  int unlink(String path) => using((Arena arena) {
        final pathPtr = path.toNativeUtf8(allocator: arena);
        lastErrno = 0;
        final result = _unlink(pathPtr);
        if (result == 0) return 0;
        final err = lastErrno;
        return err != 0 ? err : DarwinErrno.einval;
      });

  /// Creates an atomic symbolic link at [linkPath] pointing to [target] via
  /// POSIX `symlink(2)`.
  ///
  /// Used to acquire zero-FD `.cas` leases (`symlink("<pid>:<ts>:<nonce>", ".cas")`).
  /// Returns `0` on success, or the positive POSIX `errno` (such as
  /// [DarwinErrno.eexist]) on failure.
  int symlink({required String target, required String linkPath}) =>
      using((Arena arena) {
        final targetPtr = target.toNativeUtf8(allocator: arena);
        final linkPtr = linkPath.toNativeUtf8(allocator: arena);
        lastErrno = 0;
        final result = _symlink(targetPtr, linkPtr);
        if (result == 0) return 0;
        final err = lastErrno;
        return err != 0 ? err : DarwinErrno.einval;
      });

  /// Reads the target string of a symbolic link at [linkPath] via POSIX
  /// `readlink(2)`.
  ///
  /// Returns the decoded UTF-8 target string, or `null` if the symlink does
  /// not exist (`ENOENT`) or cannot be read.
  String? readlink(String linkPath, {int maxBytes = 1024}) =>
      using((Arena arena) {
        final linkPtr = linkPath.toNativeUtf8(allocator: arena);
        final buf = arena<Uint8>(maxBytes);
        lastErrno = 0;
        final count = _readlink(linkPtr, buf, maxBytes);
        if (count < 0) return null;
        final bytes = buf.asTypedList(count);
        return utf8.decode(bytes, allowMalformed: true);
      });
}
