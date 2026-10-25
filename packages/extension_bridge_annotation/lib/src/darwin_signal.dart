/// {@template extension_bridge.darwin_signal}
/// Marks a method on an `@AppGroupSchema` class as a zero-disk cross-process
/// `<notify.h>` signal RPC.
///
/// Signal methods may take either zero parameters (`void`) or a single 32-bit
/// compatible parameter (`int`, `bool`, or an `@BridgeModel` enum), which is
/// packed directly into the lower 32 bits of the `<notify.h>` 64-bit kernel
/// state register (`[0xEB42 | writerId | payload32]`) and delivered in
/// ~19 us P50 with zero file I/O.
///
/// ### Example
/// ```dart
/// @DarwinSignal(name: 'playback_command')
/// void sendPlaybackCommand(int commandCode);
/// ```
/// {@endtemplate}
final class DarwinSignal {
  /// {@macro extension_bridge.darwin_signal}
  const DarwinSignal({this.name});

  /// Optional logical signal name or notification suffix.
  ///
  /// When omitted, the generator converts the annotated method name to
  /// `snake_case` and prefixes it with `<notificationPrefix>.signal.`.
  final String? name;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is DarwinSignal && other.name == name;

  @override
  int get hashCode => name.hashCode;

  @override
  String toString() => 'DarwinSignal(name: $name)';
}
