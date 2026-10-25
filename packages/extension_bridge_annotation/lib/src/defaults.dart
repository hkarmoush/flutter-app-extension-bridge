/// {@template extension_bridge.default_value}
/// Supplies a forward- and backward-compatible fallback [value] when a field
/// is missing or `null` during JSON deserialization in both Dart and Swift 6.
///
/// In Swift 6, `@Default(...)` causes `swift_pm_emitter` to emit
/// `try container.decodeIfPresent(T.self, forKey: .field) ?? defaultValue`
/// inside `init(from decoder: Decoder)`, preventing `DecodingError.keyNotFound`
/// when an updated App Extension reads state written by an older app binary.
///
/// ### Example
/// ```dart
/// @BridgeModel()
/// class NowPlayingState {
///   const NowPlayingState({
///     required this.title,
///     @Default(1.0) this.playbackRate = 1.0,
///   });
///
///   final String title;
///   final double playbackRate;
/// }
/// ```
/// {@endtemplate}
final class Default<T> {
  /// {@macro extension_bridge.default_value}
  const Default(this.value);

  /// The constant fallback value used when the JSON key is absent or `null`.
  final T value;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is Default<T> && other.value == value;

  @override
  int get hashCode => value.hashCode;

  @override
  String toString() => 'Default($value)';
}

/// {@template extension_bridge.default_enum_value}
/// Marks an `enum` value as the fallback case when decoding an unrecognized
/// string wire value written by a newer schema version.
///
/// Prevents `DecodingError.dataCorrupted` in Swift 6 and `ArgumentError` in
/// Dart when an older App Extension binary reads an enum case introduced in a
/// newer host app release.
///
/// ### Example
/// ```dart
/// @BridgeModel()
/// enum PlaybackStatus {
///   @DefaultEnumValue()
///   idle,
///   playing,
///   paused,
/// }
/// ```
/// {@endtemplate}
final class DefaultEnumValue {
  /// {@macro extension_bridge.default_enum_value}
  const DefaultEnumValue();

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is DefaultEnumValue;

  @override
  int get hashCode => (DefaultEnumValue).hashCode;

  @override
  String toString() => 'DefaultEnumValue()';
}

/// Convenience constant for [`@DefaultEnumValue()`](DefaultEnumValue).
const defaultEnumValue = DefaultEnumValue();
