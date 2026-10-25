import 'dart:ffi';

import 'package:ffi/ffi.dart';

typedef _ReloadKindNative = Void Function(Pointer<Utf8> kindOrNull);
typedef _ReloadKindDart = void Function(Pointer<Utf8> kindOrNull);

typedef _LiveActivityStartNative = Int32 Function(
  Pointer<Utf8> attributesJson,
  Pointer<Utf8> contentStateJson,
  Pointer<Utf8> outActivityIdBuf,
  Int32 outBufCapacity,
);
typedef _LiveActivityStartDart = int Function(
  Pointer<Utf8> attributesJson,
  Pointer<Utf8> contentStateJson,
  Pointer<Utf8> outActivityIdBuf,
  int outBufCapacity,
);

typedef _LiveActivityUpdateNative = Int32 Function(
  Pointer<Utf8> activityIdOrNull,
  Pointer<Utf8> contentStateJson,
);
typedef _LiveActivityUpdateDart = int Function(
  Pointer<Utf8> activityIdOrNull,
  Pointer<Utf8> contentStateJson,
);

typedef _LiveActivityEndNative = Int32 Function(
  Pointer<Utf8> activityIdOrNull,
  Pointer<Utf8> finalContentStateJsonOrNull,
  Int32 dismissalPolicy,
);
typedef _LiveActivityEndDart = int Function(
  Pointer<Utf8> activityIdOrNull,
  Pointer<Utf8> finalContentStateJsonOrNull,
  int dismissalPolicy,
);

/// {@template extension_bridge.extension_kit_hooks}
/// Lazy resolver for Layer 2 `@_cdecl` C-ABI symbols emitted into the
/// generated `<Name>ExtensionKit` Swift Package (`eb_reload_widget_timelines`,
/// `eb_reload_control_widgets`, and `eb_la_<key>_*`).
///
/// When running inside a Flutter iOS/macOS host app that links the generated
/// `<Name>ExtensionKit` package, [ExtensionKitHooks] resolves and invokes the
/// compiled `@_cdecl` symbols directly via `dart:ffi`. When running inside a
/// standalone `dart test` or CLI process where the Swift target is not linked,
/// calls safely no-op (or route to optional test spy callbacks).
/// {@endtemplate}
final class ExtensionKitHooks {
  /// {@macro extension_bridge.extension_kit_hooks}
  ExtensionKitHooks({
    DynamicLibrary? library,
    void Function(String? kind)? onReloadWidgetTimelines,
    void Function(String? kind)? onReloadControlWidgets,
  })  : _lib = library ?? DynamicLibrary.process(),
        _onReloadWidgetTimelines = onReloadWidgetTimelines,
        _onReloadControlWidgets = onReloadControlWidgets;

  /// Default singleton bound to [DynamicLibrary.process].
  static final ExtensionKitHooks instance = ExtensionKitHooks();

  final DynamicLibrary _lib;
  final void Function(String? kind)? _onReloadWidgetTimelines;
  final void Function(String? kind)? _onReloadControlWidgets;

  _ReloadKindDart? _reloadWidgetsFn;
  bool _resolvedReloadWidgets = false;

  _ReloadKindDart? _reloadControlsFn;
  bool _resolvedReloadControls = false;

  /// Whether `eb_reload_widget_timelines` is linked into the current process.
  bool get hasReloadWidgetTimelinesSymbol =>
      _lib.providesSymbol('eb_reload_widget_timelines');

  /// Whether `eb_reload_control_widgets` is linked into the current process.
  bool get hasReloadControlWidgetsSymbol =>
      _lib.providesSymbol('eb_reload_control_widgets');

  /// Requests `WidgetCenter.shared.reloadTimelines(ofKind:)` (or
  /// `reloadAllTimelines()` when [kind] is `null`).
  ///
  /// Invokes `eb_reload_widget_timelines` if linked in the current binary, and
  /// notifies any registered test callback.
  void reloadWidgetTimelines({String? kind}) {
    _onReloadWidgetTimelines?.call(kind);

    if (!_resolvedReloadWidgets) {
      _resolvedReloadWidgets = true;
      if (hasReloadWidgetTimelinesSymbol) {
        _reloadWidgetsFn =
            _lib.lookupFunction<_ReloadKindNative, _ReloadKindDart>(
          'eb_reload_widget_timelines',
        );
      }
    }

    final fn = _reloadWidgetsFn;
    if (fn == null) return;

    using((Arena arena) {
      final kindPtr =
          kind == null ? nullptr : kind.toNativeUtf8(allocator: arena);
      fn(kindPtr);
    });
  }

  /// Requests iOS 18+ `ControlCenter.shared.reloadControls(ofKind:)` (or
  /// `reloadAllControls()` when [kind] is `null`).
  ///
  /// Invokes `eb_reload_control_widgets` if linked in the current binary, and
  /// notifies any registered test callback.
  void reloadControlWidgets({String? kind}) {
    _onReloadControlWidgets?.call(kind);

    if (!_resolvedReloadControls) {
      _resolvedReloadControls = true;
      if (hasReloadControlWidgetsSymbol) {
        _reloadControlsFn =
            _lib.lookupFunction<_ReloadKindNative, _ReloadKindDart>(
          'eb_reload_control_widgets',
        );
      }
    }

    final fn = _reloadControlsFn;
    if (fn == null) return;

    using((Arena arena) {
      final kindPtr =
          kind == null ? nullptr : kind.toNativeUtf8(allocator: arena);
      fn(kindPtr);
    });
  }

  /// Starts an `ActivityKit` Live Activity via the generated `@_cdecl` symbol
  /// `eb_la_<activityKey>_start`.
  ///
  /// Returns the started Activity ID string, or `null` if `ActivityKit` is
  /// unavailable on the current platform/process.
  String? startLiveActivity({
    required String activityKey,
    required String attributesJson,
    required String contentStateJson,
  }) {
    final symbol = 'eb_la_${activityKey}_start';
    if (!_lib.providesSymbol(symbol)) return null;

    final fn =
        _lib.lookupFunction<_LiveActivityStartNative, _LiveActivityStartDart>(
      symbol,
    );
    return using((Arena arena) {
      final attrPtr = attributesJson.toNativeUtf8(allocator: arena);
      final statePtr = contentStateJson.toNativeUtf8(allocator: arena);
      const bufCapacity = 256;
      final outBuf = arena<Uint8>(bufCapacity).cast<Utf8>();
      final status = fn(attrPtr, statePtr, outBuf, bufCapacity);
      if (status != 0) return null;
      return outBuf.toDartString();
    });
  }

  /// Updates an active `ActivityKit` Live Activity via
  /// `eb_la_<activityKey>_update`.
  ///
  /// Returns `true` if the `@_cdecl` symbol is present and succeeded (`0`).
  bool updateLiveActivity({
    required String activityKey,
    required String contentStateJson,
    String? activityId,
  }) {
    final symbol = 'eb_la_${activityKey}_update';
    if (!_lib.providesSymbol(symbol)) return false;

    final fn =
        _lib.lookupFunction<_LiveActivityUpdateNative, _LiveActivityUpdateDart>(
      symbol,
    );
    return using((Arena arena) {
      final idPtr = activityId == null
          ? nullptr
          : activityId.toNativeUtf8(allocator: arena);
      final statePtr = contentStateJson.toNativeUtf8(allocator: arena);
      return fn(idPtr, statePtr) == 0;
    });
  }

  /// Ends an `ActivityKit` Live Activity via `eb_la_<activityKey>_end`.
  ///
  /// Returns `true` if the `@_cdecl` symbol is present and succeeded (`0`).
  bool endLiveActivity({
    required String activityKey,
    String? activityId,
    String? finalContentStateJson,
    int dismissalPolicy = 0,
  }) {
    final symbol = 'eb_la_${activityKey}_end';
    if (!_lib.providesSymbol(symbol)) return false;

    final fn =
        _lib.lookupFunction<_LiveActivityEndNative, _LiveActivityEndDart>(
      symbol,
    );
    return using((Arena arena) {
      final idPtr = activityId == null
          ? nullptr
          : activityId.toNativeUtf8(allocator: arena);
      final statePtr = finalContentStateJson == null
          ? nullptr
          : finalContentStateJson.toNativeUtf8(allocator: arena);
      return fn(idPtr, statePtr, dismissalPolicy) == 0;
    });
  }
}
