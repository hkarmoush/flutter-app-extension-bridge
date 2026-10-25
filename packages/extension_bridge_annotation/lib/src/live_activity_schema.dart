/// {@template extension_bridge.live_activity_schema}
/// Declares a strongly-typed `ActivityKit` Live Activity & Dynamic Island
/// contract on an `@AppGroupSchema` member.
///
/// Generates:
/// - Cross-platform Swift 6 [attributes] and [contentState] `Codable, Sendable,
///   Equatable` structs.
/// - `#if canImport(ActivityKit) && os(iOS)` `ActivityAttributes` conformance
///   and `@_cdecl` C-ABI lifecycle entrypoints (`eb_la_<key>_start`,
///   `eb_la_<key>_update`, `eb_la_<key>_end`).
/// - A typed `LiveActivityBridge<Attributes, ContentState>` controller in Dart
///   and a corresponding mock recorder in `Fake<Name>Bridge`.
///
/// ### Example
/// ```dart
/// @LiveActivitySchema(
///   attributes: DeliveryAttributes,
///   contentState: DeliveryContentState,
///   key: 'delivery_tracker',
/// )
/// void deliveryActivity();
/// ```
/// {@endtemplate}
final class LiveActivitySchema {
  /// {@macro extension_bridge.live_activity_schema}
  const LiveActivitySchema({
    required this.attributes,
    required this.contentState,
    this.key,
  });

  /// The `@BridgeModel` class describing static `ActivityAttributes` properties
  /// set when the Live Activity starts.
  final Type attributes;

  /// The `@BridgeModel` class describing dynamic `Activity.ContentState`
  /// properties updated throughout the Live Activity's lifecycle.
  final Type contentState;

  /// Optional C-ABI symbol identifier suffix (`eb_la_<key>_*`).
  ///
  /// When omitted, the generator converts the annotated member name to
  /// `snake_case`.
  final String? key;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LiveActivitySchema &&
          other.attributes == attributes &&
          other.contentState == contentState &&
          other.key == key;

  @override
  int get hashCode => Object.hash(attributes, contentState, key);

  @override
  String toString() => 'LiveActivitySchema('
      'attributes: $attributes, '
      'contentState: $contentState, '
      'key: $key)';
}
