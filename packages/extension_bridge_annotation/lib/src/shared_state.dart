/// {@template extension_bridge.shared_state}
/// Marks a getter on an `@AppGroupSchema` class as a lock-free, atomic
/// cross-process state slot backed by APFS `rename(2)` snapshots and a 64-bit
/// `<notify.h>` kernel state register.
///
/// Every `@SharedState` getter generates:
/// - `read()`: Two-stage ~299 ns `notify_check` shared-memory cache check +
///   lock-free APFS snapshot read.
/// - `write(T value)`: Out-of-band `.tmp` serialization + atomic `.cas`
///   symlink lease + POSIX `rename(2)` + `<notify.h>` broadcast.
/// - `update(T Function(T? current) mutator)`: Lock-free optimistic
///   concurrency control (CAS loop) with automatic retry on concurrent
///   `_gen` increments and instant `kill(pid, 0) == ESRCH` dead-process lease
///   eviction.
/// - `watch()`: Reactive `Stream<T>` driven by `notify_register_dispatch`
///   with O(1) self-echo suppression.
///
/// ### Example
/// ```dart
/// @SharedState(
///   key: 'now_playing',
///   reloadWidgets: ['NowPlayingWidget'],
///   reloadControls: ['NowPlayingControl'],
/// )
/// NowPlayingState get nowPlaying;
/// ```
/// {@endtemplate}
final class SharedState {
  /// {@macro extension_bridge.shared_state}
  const SharedState({
    this.key,
    this.reloadWidgets,
    this.reloadControls,
    this.notificationName,
  });

  /// Optional on-disk key identifier (`state/<key>.v<version>.json`).
  ///
  /// When omitted, the generator converts the annotated getter name to
  /// `snake_case`.
  final String? key;

  /// Optional list of `WidgetKit` widget `kind` strings to reload automatically
  /// via `WidgetCenter.shared.reloadTimelines(ofKind:)` when Dart mutates this
  /// state.
  ///
  /// Pass `const ['*']` to reload all widget timelines via
  /// `WidgetCenter.shared.reloadAllTimelines()`.
  final List<String>? reloadWidgets;

  /// Optional list of iOS 18 `ControlWidget` `kind` strings to reload
  /// automatically via `ControlCenter.shared.reloadControls(ofKind:)` when
  /// Dart mutates this state.
  ///
  /// Pass `const ['*']` to reload all control widgets.
  final List<String>? reloadControls;

  /// Optional override for the full `<notify.h>` Darwin notification name.
  ///
  /// When omitted, the generator uses `<notificationPrefix>.state.<key>`.
  final String? notificationName;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SharedState &&
          other.key == key &&
          _listEquals(other.reloadWidgets, reloadWidgets) &&
          _listEquals(other.reloadControls, reloadControls) &&
          other.notificationName == notificationName;

  @override
  int get hashCode => Object.hash(
        key,
        reloadWidgets == null ? null : Object.hashAll(reloadWidgets!),
        reloadControls == null ? null : Object.hashAll(reloadControls!),
        notificationName,
      );

  @override
  String toString() => 'SharedState('
      'key: $key, '
      'reloadWidgets: $reloadWidgets, '
      'reloadControls: $reloadControls, '
      'notificationName: $notificationName)';
}

bool _listEquals<T>(List<T>? a, List<T>? b) {
  if (identical(a, b)) return true;
  if (a == null || b == null || a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
