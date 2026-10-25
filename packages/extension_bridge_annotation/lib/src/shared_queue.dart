/// {@template extension_bridge.shared_queue}
/// Marks a getter on an `@AppGroupSchema` class as a lock-free, multi-producer
/// Maildir queue (`tmp/` -> `ready/` -> `inflight/`) ordered by a Hybrid
/// Logical Clock (HLC).
///
/// Designed for Share Extensions, Action Extensions, and Interactive Widgets
/// that enqueue items or media attachments under strict 16-30 MB Jetsam memory
/// limits while the host Flutter app may be suspended or terminated.
///
/// ### Example
/// ```dart
/// @SharedQueue(key: 'shared_inbox', maxItems: 128)
/// SharedMediaItem get sharedInbox;
/// ```
/// {@endtemplate}
final class SharedQueue {
  /// {@macro extension_bridge.shared_queue}
  const SharedQueue({
    this.key,
    this.maxItems = 256,
    this.notificationName,
  }) : assert(maxItems >= 1, 'maxItems must be >= 1');

  /// Optional directory key under `queue/<key>/`.
  ///
  /// When omitted, the generator converts the annotated getter name to
  /// `snake_case`.
  final String? key;

  /// Maximum number of pending items allowed in `ready/` before backpressure
  /// or oldest-item eviction policies apply. Defaults to `256`.
  final int maxItems;

  /// Optional override for the full `<notify.h>` Darwin notification name.
  ///
  /// When omitted, the generator uses `<notificationPrefix>.queue.<key>`.
  final String? notificationName;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SharedQueue &&
          other.key == key &&
          other.maxItems == maxItems &&
          other.notificationName == notificationName;

  @override
  int get hashCode => Object.hash(key, maxItems, notificationName);

  @override
  String toString() => 'SharedQueue('
      'key: $key, '
      'maxItems: $maxItems, '
      'notificationName: $notificationName)';
}
