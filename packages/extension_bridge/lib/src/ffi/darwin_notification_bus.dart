import 'dart:async';
import 'dart:ffi';

import 'package:meta/meta.dart';

import '../protocol/bridge_exception.dart';
import '../protocol/kernel_state_register.dart';
import 'darwin_posix_ffi.dart';
import 'objc_block_ffi.dart';

/// {@template extension_bridge.darwin_notification_token}
/// Finalizable handle wrapping an active Darwin `<notify.h>` registration
/// token.
///
/// Paired with a [NativeFinalizer] bound directly to `notify_cancel` in
/// `libSystem.B.dylib`. If the owning [DarwinNotificationToken] becomes
/// unreachable without an explicit call to [cancel], the Dart VM garbage
/// collector automatically invokes `notify_cancel(token)` so Mach ports and
/// `notifyd` registrations never leak.
/// {@endtemplate}
final class DarwinNotificationToken implements Finalizable {
  /// Registers a shared-memory check token (`notify_register_check`) for
  /// [notificationName].
  factory DarwinNotificationToken.registerCheck(
    String notificationName, {
    DarwinPosixFfi? posix,
  }) {
    final ffi = posix ?? DarwinPosixFfi.instance;
    final result = ffi.notifyRegisterCheck(notificationName);
    if (result.status != NotifyStatus.ok ||
        !ffi.notifyIsValidToken(result.token)) {
      throw DarwinNotificationException(
        operation: 'notify_register_check',
        notificationName: notificationName,
        statusCode: result.status,
      );
    }
    // Consume the initial registration check=1 sentinel so subsequent calls to
    // notifyCheck report true only when a post occurs after registration.
    ffi.notifyCheck(result.token);
    return DarwinNotificationToken._(
      notificationName: notificationName,
      token: result.token,
      isDispatchToken: false,
      posix: ffi,
    );
  }

  /// Registers a GCD background dispatch token (`notify_register_dispatch`)
  /// routed through [DarwinNotifyBlockDemuxer] for [notificationName].
  factory DarwinNotificationToken.registerDispatch(
    String notificationName, {
    required void Function(int token) onNotification,
    DarwinPosixFfi? posix,
    int qosClass = DispatchQosClass.userInteractive,
  }) {
    final ffi = posix ?? DarwinPosixFfi.instance;
    final queue = ffi.getGlobalQueue(qosClass: qosClass);
    final demuxer = DarwinNotifyBlockDemuxer.instance;

    final result = ffi.notifyRegisterDispatch(
      name: notificationName,
      queue: queue,
      handlerBlock: demuxer.blockPointer,
    );
    if (result.status != NotifyStatus.ok ||
        !ffi.notifyIsValidToken(result.token)) {
      throw DarwinNotificationException(
        operation: 'notify_register_dispatch',
        notificationName: notificationName,
        statusCode: result.status,
      );
    }

    demuxer.registerToken(result.token, onNotification);
    return DarwinNotificationToken._(
      notificationName: notificationName,
      token: result.token,
      isDispatchToken: true,
      posix: ffi,
    );
  }

  DarwinNotificationToken._({
    required this.notificationName,
    required int token,
    required this.isDispatchToken,
    required DarwinPosixFfi posix,
  })  : _token = token,
        _posix = posix {
    _notifyCancelFinalizer.attach(
      this,
      Pointer<Void>.fromAddress(token),
      detach: this,
    );
  }

  static final NativeFinalizer _notifyCancelFinalizer = NativeFinalizer(
    DarwinPosixFfi.instance.notifyCancelFinalizerSymbol,
  );

  /// The Darwin notification key name associated with this token.
  final String notificationName;

  /// Whether this token was registered via `notify_register_dispatch` (`true`)
  /// or `notify_register_check` (`false`).
  final bool isDispatchToken;

  final DarwinPosixFfi _posix;
  int _token;
  bool _isCanceled = false;

  /// Raw integer token assigned by `notifyd`, or [kNotifyTokenInvalid] (`-1`)
  /// if [cancel] has been called.
  int get token => _token;

  /// Whether [cancel] has been called on this token.
  bool get isCanceled => _isCanceled;

  /// Deterministic cleanup that detaches the [NativeFinalizer], unregisters
  /// any [DarwinNotifyBlockDemuxer] callback, and calls `notify_cancel`.
  void cancel() {
    if (_isCanceled) return;
    _isCanceled = true;
    _notifyCancelFinalizer.detach(this);
    final activeToken = _token;
    _token = kNotifyTokenInvalid;
    if (isDispatchToken) {
      DarwinNotifyBlockDemuxer.instance.unregisterToken(activeToken);
    }
    _posix.notifyCancel(activeToken);
  }
}

/// {@template extension_bridge.darwin_state_wakeup_event}
/// Event emitted by [DarwinNotificationBus.watchState] when a remote process
/// (or another in-process bridge instance with a distinct `writerId`) commits a
/// new `@SharedState` or `@SharedQueue` generation.
/// {@endtemplate}
@immutable
final class DarwinStateWakeupEvent {
  /// {@macro extension_bridge.darwin_state_wakeup_event}
  const DarwinStateWakeupEvent({
    required this.notificationName,
    required this.register,
  });

  /// The Darwin notification channel name.
  final String notificationName;

  /// The 64-bit [KernelStateRegister] read from `notifyd` at wakeup time.
  final KernelStateRegister register;

  /// 16-bit logical writer identifier extracted from [register].
  int get writerId => register.writerId;

  /// 32-bit monotonic generation counter extracted from [register].
  int get generation => register.generation;

  @override
  String toString() =>
      'DarwinStateWakeupEvent(name: $notificationName, register: ${register.toHexString()})';
}

/// {@template extension_bridge.darwin_signal_event}
/// Event emitted by [DarwinNotificationBus.watchSignal] when a `@DarwinSignal`
/// is received from another process or bridge instance.
/// {@endtemplate}
@immutable
final class DarwinSignalEvent {
  /// {@macro extension_bridge.darwin_signal_event}
  const DarwinSignalEvent({
    required this.signalName,
    required this.writerId,
    required this.payload,
    required this.register,
  });

  /// The Darwin signal notification name.
  final String signalName;

  /// 16-bit logical writer ID of the sender.
  final int writerId;

  /// Signed 32-bit integer payload unpacked from bits `31..0` of [register].
  final int payload;

  /// Full 64-bit [KernelStateRegister] snapshot read from `notifyd`.
  final KernelStateRegister register;

  @override
  String toString() => 'DarwinSignalEvent('
      'name: $signalName, '
      'writerId: $writerId, '
      'payload: $payload, '
      'register: ${register.toHexString()})';
}

/// {@template extension_bridge.darwin_notification_bus}
/// High-speed cross-process Darwin `<notify.h>` signal bus implementing:
///
/// 1. **Two-Stage Shared-Memory Fast Path (`~299 ns`):**
///    - **Stage 1 ([checkChanged]):** Reads `notifyd`'s process-mapped shared
///      memory slot via `notify_check` in ~299 ns with zero Mach IPC.
///    - **Stage 2 ([getRegister]):** Invokes `notify_get_state` (~9.3 µs Mach
///      IPC) only when `notify_check` reports a mutation or during dispatch
///      wakeups.
/// 2. **O(1) Self-Echo Cancellation:**
///    Tags every state commit and signal with `[0xEB42 | writerId | generation]`
///    in the kernel's 64-bit register before calling `notify_post`. When the
///    sender's own GCD listener wakes up, it sees `isFromWriter(writerId)` /
///    `generation <= localGen` and drops the echo in O(1) with **zero disk I/O**.
/// 3. **Cold-Start `0x0` Register Seeding ([seedStateIfUnseeded]):**
///    Re-hydrates the kernel register from the authoritative APFS `_gen`
///    header if `notifyd` garbage-collected the register while all processes
///    were terminated.
/// 4. **Zero-Disk 32-Bit `@DarwinSignal` RPC ([postSignal] / [watchSignal]):**
///    Transmits 32-bit command payloads directly inside the `<notify.h>`
///    register in **~19 µs P50** without touching the filesystem.
/// {@endtemplate}
final class DarwinNotificationBus {
  /// {@macro extension_bridge.darwin_notification_bus}
  DarwinNotificationBus({
    DarwinPosixFfi? posix,
    int? writerId,
  })  : _posix = posix ?? DarwinPosixFfi.instance,
        writerId = writerId ??
            deriveLogicalWriterId(
              pid: (posix ?? DarwinPosixFfi.instance).getpid(),
            ) {
    assert(
      this.writerId > 0 && this.writerId <= 0xFFFF,
      'writerId must be a non-zero 16-bit integer (1..0xFFFF)',
    );
  }

  final DarwinPosixFfi _posix;

  /// Distinct 16-bit logical writer identifier (`1..0xFFFF`) for this bus
  /// instance.
  final int writerId;

  final Map<String, DarwinNotificationToken> _checkTokens =
      <String, DarwinNotificationToken>{};
  final Map<String, DarwinNotificationToken> _dispatchTokens =
      <String, DarwinNotificationToken>{};
  final Map<String, _NotificationChannel<DarwinStateWakeupEvent>>
      _stateChannels = <String, _NotificationChannel<DarwinStateWakeupEvent>>{};
  final Map<String, _NotificationChannel<DarwinSignalEvent>> _signalChannels =
      <String, _NotificationChannel<DarwinSignalEvent>>{};
  final Map<String, int> _localGenerations = <String, int>{};

  bool _isDisposed = false;

  int _shmFastPathHits = 0;
  int _machIpcStateReads = 0;
  int _suppressedEchoCount = 0;
  int _deliveredWakeupCount = 0;

  /// Whether [dispose] has been called on this bus.
  bool get isDisposed => _isDisposed;

  /// Number of times Stage 1 [checkChanged] returned `false` (`check == 0` in
  /// `~299 ns` shared memory without needing Mach IPC or disk I/O).
  int get shmFastPathHits => _shmFastPathHits;

  /// Number of times Stage 2 [getRegister] executed `notify_get_state` Mach IPC.
  int get machIpcStateReads => _machIpcStateReads;

  /// Number of self-echo or already-processed wakeups suppressed in O(1) with
  /// zero disk I/O.
  int get suppressedEchoCount => _suppressedEchoCount;

  /// Number of remote state or signal wakeups delivered to listeners.
  int get deliveredWakeupCount => _deliveredWakeupCount;

  /// Returns the last known 32-bit generation recorded locally for
  /// [notificationName], or `null` if unknown.
  int? localGenerationFor(String notificationName) =>
      _localGenerations[notificationName];

  /// Updates the locally cached generation for [notificationName] (for example,
  /// after reading a snapshot from APFS).
  void recordLocalGeneration(String notificationName, int generation) {
    _localGenerations[notificationName] = generation & 0xFFFFFFFF;
  }

  DarwinNotificationToken _ensureCheckToken(String notificationName) {
    _checkNotDisposed();
    final existing = _checkTokens[notificationName];
    if (existing != null && !existing.isCanceled) {
      return existing;
    }
    final created = DarwinNotificationToken.registerCheck(
      notificationName,
      posix: _posix,
    );
    _checkTokens[notificationName] = created;
    return created;
  }

  /// **Stage 1 (`~299 ns` Shared-Memory Fast Path):** Checks whether any
  /// notification has been posted to [notificationName] since the previous
  /// check on this bus.
  ///
  /// Reads `notifyd`'s shared-memory (`shm`) generation slot mapped directly
  /// into the process address space—zero Mach IPC and zero syscalls.
  bool checkChanged(String notificationName) {
    final token = _ensureCheckToken(notificationName);
    final result = _posix.notifyCheck(token.token);
    if (result.status != NotifyStatus.ok) {
      throw DarwinNotificationException(
        operation: 'notify_check',
        notificationName: notificationName,
        statusCode: result.status,
      );
    }
    if (!result.changed) {
      _shmFastPathHits += 1;
    }
    return result.changed;
  }

  /// **Stage 2 (`~9.3 µs` Mach IPC):** Reads the 64-bit [KernelStateRegister]
  /// stored in `notifyd` for [notificationName].
  KernelStateRegister getRegister(String notificationName) {
    final token = _ensureCheckToken(notificationName);
    return _getRegisterForToken(notificationName, token.token);
  }

  KernelStateRegister _getRegisterForToken(
    String notificationName,
    int rawToken,
  ) {
    _machIpcStateReads += 1;
    final result = _posix.notifyGetState(rawToken);
    if (result.status != NotifyStatus.ok) {
      throw DarwinNotificationException(
        operation: 'notify_get_state',
        notificationName: notificationName,
        statusCode: result.status,
      );
    }
    return KernelStateRegister(result.state64);
  }

  /// Seeds the 64-bit kernel register for [notificationName] with
  /// [authoritativeGeneration] if and only if the kernel register is currently
  /// uninitialized (`0x0` / `!hasValidMagic`).
  ///
  /// Because `notifyd` garbage-collects a key's 64-bit state register if all
  /// processes holding tokens exit, cold-start readers call this method after
  /// reading the authoritative `_gen` from APFS while holding their persistent
  /// check token. Does **not** call `notify_post`.
  ///
  /// Returns `true` if the register was unseeded and has now been seeded.
  bool seedStateIfUnseeded(
    String notificationName, {
    required int authoritativeGeneration,
    int? seedWriterId,
  }) {
    final token = _ensureCheckToken(notificationName);
    final current = _getRegisterForToken(notificationName, token.token);
    _localGenerations[notificationName] = authoritativeGeneration & 0xFFFFFFFF;
    if (!current.isUnseeded) {
      return false;
    }
    final seeded = KernelStateRegister.pack(
      writerId: seedWriterId ?? writerId,
      generation: authoritativeGeneration,
    );
    final status = _posix.notifySetState(token.token, seeded.rawBits);
    if (status != NotifyStatus.ok) {
      throw DarwinNotificationException(
        operation: 'notify_set_state',
        notificationName: notificationName,
        statusCode: status,
      );
    }
    return true;
  }

  /// Publishes a newly committed [generation] for [notificationName] by writing
  /// `[0xEB42 | writerId | generation]` via `notify_set_state` and broadcasting
  /// `notify_post`.
  ///
  /// Returns the [KernelStateRegister] written to `notifyd`.
  KernelStateRegister publishState(
    String notificationName, {
    required int generation,
  }) {
    final token = _ensureCheckToken(notificationName);
    final maskedGen = generation & 0xFFFFFFFF;
    _localGenerations[notificationName] = maskedGen;

    final reg = KernelStateRegister.pack(
      writerId: writerId,
      generation: maskedGen,
    );
    final setStatus = _posix.notifySetState(token.token, reg.rawBits);
    if (setStatus != NotifyStatus.ok) {
      throw DarwinNotificationException(
        operation: 'notify_set_state',
        notificationName: notificationName,
        statusCode: setStatus,
      );
    }

    final postStatus = _posix.notifyPost(notificationName);
    if (postStatus != NotifyStatus.ok) {
      throw DarwinNotificationException(
        operation: 'notify_post',
        notificationName: notificationName,
        statusCode: postStatus,
      );
    }

    return reg;
  }

  /// Subscribes to cross-process state mutations on [notificationName].
  ///
  /// Self-echo notifications originating from this [DarwinNotificationBus]
  /// (`writerId`) or carrying a generation `<= localGeneration` are suppressed
  /// in O(1) before emitting to the stream.
  Stream<DarwinStateWakeupEvent> watchState(String notificationName) {
    _checkNotDisposed();
    final existing = _stateChannels[notificationName];
    if (existing != null) {
      return existing.stream;
    }

    late final _NotificationChannel<DarwinStateWakeupEvent> channel;
    channel = _NotificationChannel<DarwinStateWakeupEvent>(
      onListen: () {
        _ensureCheckToken(notificationName);
        _ensureDispatchToken(notificationName);
      },
      onCancel: () {
        if (!channel.hasListener &&
            !(_signalChannels[notificationName]?.hasListener ?? false)) {
          _cancelDispatchToken(notificationName);
        }
      },
    );
    _stateChannels[notificationName] = channel;
    return channel.stream;
  }

  /// Sends a zero-disk `@DarwinSignal` RPC on [signalName] carrying an optional
  /// signed or unsigned 32-bit [payload] directly inside the `<notify.h>`
  /// 64-bit kernel register.
  KernelStateRegister postSignal(
    String signalName, {
    int payload = 0,
  }) {
    final token = _ensureCheckToken(signalName);
    final reg = KernelStateRegister.packSignal(
      writerId: writerId,
      payload: payload,
    );

    final setStatus = _posix.notifySetState(token.token, reg.rawBits);
    if (setStatus != NotifyStatus.ok) {
      throw DarwinNotificationException(
        operation: 'notify_set_state',
        notificationName: signalName,
        statusCode: setStatus,
      );
    }

    final postStatus = _posix.notifyPost(signalName);
    if (postStatus != NotifyStatus.ok) {
      throw DarwinNotificationException(
        operation: 'notify_post',
        notificationName: signalName,
        statusCode: postStatus,
      );
    }

    return reg;
  }

  /// Subscribes to incoming `@DarwinSignal` events on [signalName].
  ///
  /// Signals posted by this [DarwinNotificationBus] instance (`writerId`) are
  /// suppressed automatically via O(1) echo cancellation.
  Stream<DarwinSignalEvent> watchSignal(String signalName) {
    _checkNotDisposed();
    final existing = _signalChannels[signalName];
    if (existing != null) {
      return existing.stream;
    }

    late final _NotificationChannel<DarwinSignalEvent> channel;
    channel = _NotificationChannel<DarwinSignalEvent>(
      onListen: () {
        _ensureCheckToken(signalName);
        _ensureDispatchToken(signalName);
      },
      onCancel: () {
        if (!channel.hasListener &&
            !(_stateChannels[signalName]?.hasListener ?? false)) {
          _cancelDispatchToken(signalName);
        }
      },
    );
    _signalChannels[signalName] = channel;
    return channel.stream;
  }

  void _ensureDispatchToken(String notificationName) {
    final existing = _dispatchTokens[notificationName];
    if (existing != null && !existing.isCanceled) {
      return;
    }

    final dispatchToken = DarwinNotificationToken.registerDispatch(
      notificationName,
      posix: _posix,
      onNotification: (int rawToken) {
        _handleDispatchWakeup(notificationName, rawToken);
      },
    );
    _dispatchTokens[notificationName] = dispatchToken;
  }

  void _cancelDispatchToken(String notificationName) {
    final token = _dispatchTokens.remove(notificationName);
    token?.cancel();
  }

  void _handleDispatchWakeup(String notificationName, int rawToken) {
    if (_isDisposed) return;

    final KernelStateRegister reg;
    try {
      reg = _getRegisterForToken(notificationName, rawToken);
    } on DarwinNotificationException {
      return;
    }

    final stateChannel = _stateChannels[notificationName];
    if (stateChannel != null && stateChannel.hasListener) {
      final localGen = _localGenerations[notificationName];
      final isSelfEcho = reg.isFromWriter(writerId);
      final isStaleGen = localGen != null &&
          reg.shouldSuppressStateWakeup(
            localWriterId: writerId,
            localGeneration: localGen,
          );

      if (isSelfEcho || isStaleGen) {
        _suppressedEchoCount += 1;
      } else {
        if (reg.hasValidMagic) {
          _localGenerations[notificationName] = reg.generation;
        }
        _deliveredWakeupCount += 1;
        stateChannel.add(
          DarwinStateWakeupEvent(
            notificationName: notificationName,
            register: reg,
          ),
        );
      }
    }

    final signalChannel = _signalChannels[notificationName];
    if (signalChannel != null && signalChannel.hasListener) {
      if (reg.isFromWriter(writerId)) {
        _suppressedEchoCount += 1;
      } else {
        _deliveredWakeupCount += 1;
        signalChannel.add(
          DarwinSignalEvent(
            signalName: notificationName,
            writerId: reg.writerId,
            payload: reg.signedPayload32,
            register: reg,
          ),
        );
      }
    }
  }

  void _checkNotDisposed() {
    if (_isDisposed) {
      throw StateError('DarwinNotificationBus has already been disposed.');
    }
  }

  /// Cancels all registered `<notify.h>` tokens and closes all active streams.
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;

    for (final token in _dispatchTokens.values) {
      token.cancel();
    }
    _dispatchTokens.clear();

    for (final token in _checkTokens.values) {
      token.cancel();
    }
    _checkTokens.clear();

    final futures = <Future<void>>[
      for (final c in _stateChannels.values) c.close(),
      for (final c in _signalChannels.values) c.close(),
    ];
    _stateChannels.clear();
    _signalChannels.clear();
    await Future.wait(futures);
  }
}

final class _NotificationChannel<T> {
  _NotificationChannel({
    required void Function() onListen,
    required void Function() onCancel,
  }) : _controller = StreamController<T>.broadcast(
          onListen: onListen,
          onCancel: onCancel,
        );

  final StreamController<T> _controller;

  Stream<T> get stream => _controller.stream;

  bool get hasListener => _controller.hasListener;

  void add(T event) => _controller.add(event);

  Future<void> close() => _controller.close();
}
