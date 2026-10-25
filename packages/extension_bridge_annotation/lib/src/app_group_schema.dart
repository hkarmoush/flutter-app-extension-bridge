/// {@template extension_bridge.app_group_schema}
/// Declares a cross-process Darwin App Group bridge contract on an abstract
/// schema class.
///
/// Classes annotated with [AppGroupSchema] are analyzed by
/// `extension_bridge_generator` to produce:
/// 1. A pure-Dart FFI client (`<Name>Bridge`) and deterministic in-memory fake
///    (`Fake<Name>Bridge`).
/// 2. A standalone Swift 6 Package (`ios/<swiftPackageName>/Package.swift`)
///    containing `Codable, Sendable, Equatable` models, lock-free snapshot
///    stores, Maildir queues, `<notify.h>` listeners, and `@_cdecl` C-ABI
///    hooks for `WidgetKit`, `ActivityKit`, and iOS 18 `ControlWidget`.
///
/// ### Example
/// ```dart
/// @AppGroupSchema(
///   groupId: 'group.com.example.pulsehub',
///   swiftPackageName: 'PulseHubExtensionKit',
///   schemaVersion: 1,
/// )
/// abstract class PulseHubSchema {
///   @SharedState(reloadWidgets: ['NowPlayingWidget'])
///   NowPlayingState get nowPlaying;
///
///   @SharedQueue(maxItems: 100)
///   ShareInboxItem get shareInbox;
///
///   @DarwinSignal()
///   void onPlaybackCommand(int commandCode);
/// }
/// ```
/// {@endtemplate}
final class AppGroupSchema {
  /// {@macro extension_bridge.app_group_schema}
  const AppGroupSchema({
    required this.groupId,
    this.swiftPackageName,
    this.schemaVersion = 1,
    this.notificationPrefix,
  }) : assert(schemaVersion >= 1, 'schemaVersion must be >= 1');

  /// The Apple App Group identifier shared between the Flutter host app and
  /// all App Extension targets (must begin with `'group.'`, e.g.,
  /// `'group.com.example.app'`).
  final String groupId;

  /// Optional name for the generated local Swift Package under `ios/`.
  ///
  /// When omitted, `extension_bridge_generator` derives the package name from
  /// the annotated schema class (e.g., `PulseHubSchema` ->
  /// `PulseHubExtensionKit`).
  final String? swiftPackageName;

  /// Monotonic integer version written to the `_schema_version` field of every
  /// state and queue envelope. Defaults to `1`.
  final int schemaVersion;

  /// Optional reverse-DNS prefix for Darwin `<notify.h>` notification keys.
  ///
  /// When omitted, `extension_bridge_generator` derives the prefix from
  /// [groupId] by stripping the leading `'group.'` segment and appending
  /// `'.eb'` (e.g., `'com.example.app.eb'`).
  final String? notificationPrefix;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AppGroupSchema &&
          other.groupId == groupId &&
          other.swiftPackageName == swiftPackageName &&
          other.schemaVersion == schemaVersion &&
          other.notificationPrefix == notificationPrefix;

  @override
  int get hashCode => Object.hash(
        groupId,
        swiftPackageName,
        schemaVersion,
        notificationPrefix,
      );

  @override
  String toString() => 'AppGroupSchema('
      'groupId: $groupId, '
      'swiftPackageName: $swiftPackageName, '
      'schemaVersion: $schemaVersion, '
      'notificationPrefix: $notificationPrefix)';
}
