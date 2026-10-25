/// {@template extension_bridge.bridge_model}
/// Marks a Dart `class`, `sealed class`, or `enum` for cross-language
/// Dart <-> Swift 6 code generation.
///
/// - **Standard classes** generate immutable Dart value semantics (`copyWith`,
///   `toJson`, `fromJson`, deep equality) and a Swift 6
///   `public struct : Codable, Sendable, Equatable` with custom schema-tolerant
///   `init(from decoder:)` and `encode(to encoder:)` implementations.
/// - **Dart 3 `sealed class` hierarchies** generate a Swift 6
///   `public enum : Codable, Sendable, Equatable` with associated values
///   encoded via the [discriminatorKey] tag (defaulting to `'_type'`).
/// - **Dart `enum` declarations** generate a Swift 6
///   `public enum : String, Codable, Sendable, CaseIterable` with graceful
///   fallback decoding for unknown future cases via `@DefaultEnumValue()`.
///
/// ### Example
/// ```dart
/// @BridgeModel()
/// sealed class PlaybackAction {
///   const PlaybackAction();
/// }
///
/// @BridgeModel()
/// final class SeekAction extends PlaybackAction {
///   const SeekAction({required this.positionMs});
///   final int positionMs;
/// }
/// ```
/// {@endtemplate}
final class BridgeModel {
  /// {@macro extension_bridge.bridge_model}
  const BridgeModel({this.discriminatorKey = '_type'});

  /// JSON discriminator key used when serializing and deserializing Dart 3
  /// `sealed class` algebraic data types into Swift 6 `enum` cases with
  /// associated values. Defaults to `'_type'`.
  final String discriminatorKey;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is BridgeModel && other.discriminatorKey == discriminatorKey;

  @override
  int get hashCode => discriminatorKey.hashCode;

  @override
  String toString() => 'BridgeModel(discriminatorKey: $discriminatorKey)';
}

/// Convenience constant for [BridgeModel] (`@bridgeModel`).
const bridgeModel = BridgeModel();
