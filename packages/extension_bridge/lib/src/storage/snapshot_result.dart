import 'package:meta/meta.dart';

import '../protocol/state_envelope.dart';

/// {@template extension_bridge.snapshot_result}
/// Exhaustive sealed result returned by `AtomicStateStore.readResult()`.
///
/// Use a Dart 3 `switch` expression to handle both present snapshots
/// ([SnapshotHit]) and uninitialized keys ([SnapshotEmpty]):
/// ```dart
/// final result = store.readResult();
/// switch (result) {
///   case SnapshotHit(:final value, :final envelope, :final fromMemoryCache):
///     print('Gen ${envelope.generation}: $value (cached: $fromMemoryCache)');
///   case SnapshotEmpty():
///     print('No state written yet');
/// }
/// ```
/// {@endtemplate}
@immutable
sealed class SnapshotResult<T> {
  /// {@macro extension_bridge.snapshot_result}
  const SnapshotResult();

  /// Decoded model value if present, or `null` if [SnapshotEmpty].
  T? get valueOrNull;

  /// Full [StateEnvelope] metadata and payload if present, or `null` if
  /// [SnapshotEmpty].
  StateEnvelope<T>? get envelopeOrNull;
}

/// {@template extension_bridge.snapshot_hit}
/// Indicates that a valid `@SharedState` snapshot was returned from either the
/// `~299 ns` shared-memory cache ([fromMemoryCache] == `true`) or a lock-free
/// APFS snapshot read ([fromMemoryCache] == `false`).
/// {@endtemplate}
@immutable
final class SnapshotHit<T> extends SnapshotResult<T> {
  /// {@macro extension_bridge.snapshot_hit}
  const SnapshotHit({
    required this.value,
    required this.envelope,
    required this.fromMemoryCache,
  });

  /// Strongly-typed decoded model value (with any `@SharedAttachment` paths
  /// resolved to absolute paths inside the App Group container).
  final T value;

  /// Wire envelope containing `_gen`, `_updated_at_us`, `_writer_id`, and
  /// `_attachments`.
  final StateEnvelope<T> envelope;

  /// Whether this snapshot was served from the in-memory fast path after
  /// `notify_check` (~299 ns `shm`) confirmed no remote mutation occurred.
  final bool fromMemoryCache;

  @override
  T get valueOrNull => value;

  @override
  StateEnvelope<T> get envelopeOrNull => envelope;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SnapshotHit<T> &&
          other.value == value &&
          other.envelope == envelope &&
          other.fromMemoryCache == fromMemoryCache;

  @override
  int get hashCode => Object.hash(value, envelope, fromMemoryCache);

  @override
  String toString() => 'SnapshotHit('
      'gen: ${envelope.generation}, '
      'fromMemoryCache: $fromMemoryCache, '
      'value: $value)';
}

/// {@template extension_bridge.snapshot_empty}
/// Indicates that no snapshot file exists yet on disk for the requested
/// `@SharedState` key.
/// {@endtemplate}
@immutable
final class SnapshotEmpty<T> extends SnapshotResult<T> {
  /// {@macro extension_bridge.snapshot_empty}
  const SnapshotEmpty();

  @override
  T? get valueOrNull => null;

  @override
  StateEnvelope<T>? get envelopeOrNull => null;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is SnapshotEmpty<T>;

  @override
  int get hashCode => (SnapshotEmpty).hashCode;

  @override
  String toString() => 'SnapshotEmpty<$T>()';
}
