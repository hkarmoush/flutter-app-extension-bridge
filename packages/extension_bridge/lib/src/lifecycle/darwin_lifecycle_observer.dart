import 'dart:async';
import 'dart:ffi';

import '../ffi/objc_block_ffi.dart';
import '../ffi/objc_runtime_ffi.dart';

/// Standard UIKit notification posted when an iOS/tvOS/visionOS app enters the
/// foreground active state.
const String kUIApplicationDidBecomeActiveNotification =
    'UIApplicationDidBecomeActiveNotification';

/// Standard AppKit notification posted when a macOS app enters the foreground
/// active state.
const String kNSApplicationDidBecomeActiveNotification =
    'NSApplicationDidBecomeActiveNotification';

/// {@template extension_bridge.darwin_lifecycle_observer}
/// Pure-Dart Objective-C `NSNotificationCenter` observer that detects when the
/// host iOS or macOS application resumes into the foreground active state
/// (`UIApplicationDidBecomeActiveNotification` /
/// `NSApplicationDidBecomeActiveNotification`).
///
/// When an iOS app is suspended in the background, `notifyd` coalesces or
/// defers Mach port delivery until the process resumes. Subscribing to
/// [onDidBecomeActive] allows `extension_bridge` stores and queues to
/// automatically run their two-stage `notify_check` (~299 ns `shm`) →
/// `notify_get_state` reconciliation sweep upon foreground resume—with **zero
/// dependency on `package:flutter` or `WidgetsBindingObserver`**.
/// {@endtemplate}
final class DarwinLifecycleObserver {
  /// {@macro extension_bridge.darwin_lifecycle_observer}
  DarwinLifecycleObserver({
    ObjCRuntimeFfi? objcRuntime,
    List<String>? notificationNames,
  })  : _objc = objcRuntime ?? ObjCRuntimeFfi.instance,
        _notificationNames = notificationNames ??
            const <String>[
              kUIApplicationDidBecomeActiveNotification,
              kNSApplicationDidBecomeActiveNotification,
            ];

  final ObjCRuntimeFfi _objc;
  final List<String> _notificationNames;

  final List<Pointer<Void>> _observerTokens = <Pointer<Void>>[];
  ObjCNotificationBlock? _block;
  StreamController<String>? _controller;
  bool _isDisposed = false;
  int _resumeCount = 0;

  /// Number of foreground resume notifications observed since creation.
  int get resumeCount => _resumeCount;

  /// Whether native `NSNotificationCenter` observers are currently attached.
  bool get isObserving => _observerTokens.isNotEmpty;

  /// Broadcast stream that emits the notification name whenever the host
  /// application transitions to the foreground active state.
  Stream<String> get onDidBecomeActive {
    if (_isDisposed) {
      throw StateError('DarwinLifecycleObserver has already been disposed.');
    }
    return (_controller ??= StreamController<String>.broadcast(
      onListen: _startObserving,
      onCancel: _stopObserving,
    ))
        .stream;
  }

  void _startObserving() {
    if (_isDisposed || _observerTokens.isNotEmpty) return;

    final block = ObjCNotificationBlock((_) {
      if (_isDisposed) return;
      _resumeCount += 1;
      _controller?.add('DidBecomeActive');
    });
    _block = block;

    for (final name in _notificationNames) {
      final token = _objc.addNotificationObserver(
        notificationName: name,
        block: block,
      );
      if (token != nullptr) {
        _observerTokens.add(token);
      }
    }
  }

  void _stopObserving() {
    for (final token in _observerTokens) {
      _objc.removeNotificationObserver(token);
    }
    _observerTokens.clear();
    _block?.dispose();
    _block = null;
  }

  /// Simulates a foreground resume notification on
  /// `[NSNotificationCenter defaultCenter]` (useful for deterministic lifecycle
  /// reconciliation tests).
  void simulateDidBecomeActive({
    String notificationName = kNSApplicationDidBecomeActiveNotification,
  }) {
    _objc.postNotification(notificationName);
  }

  /// Unregisters all `NSNotificationCenter` observers and closes the
  /// [onDidBecomeActive] stream.
  Future<void> dispose() async {
    if (_isDisposed) return;
    _isDisposed = true;
    _stopObserving();
    await _controller?.close();
    _controller = null;
  }
}
