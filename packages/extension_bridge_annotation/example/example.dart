/// Example demonstrating how to declare a cross-process App Group contract
/// using `package:extension_bridge_annotation`.
library;

import 'package:extension_bridge_annotation/extension_bridge_annotation.dart';

/// Playback status synchronized between Flutter and WidgetKit / ControlWidget.
@BridgeModel()
enum PlaybackStatus {
  /// Fallback state when decoding unknown future enum cases.
  @DefaultEnumValue()
  idle,

  /// Audio is actively playing.
  playing,

  /// Audio is paused.
  paused,
}

/// Immutable snapshot model stored in `@SharedState`.
@BridgeModel()
class NowPlayingState {
  /// Creates a [NowPlayingState] snapshot.
  const NowPlayingState({
    required this.trackId,
    required this.title,
    required this.status,
    @Default(1.0) this.playbackSpeed = 1.0,
    @SharedAttachment() this.artworkPath,
  });

  /// Unique track identifier.
  final String trackId;

  /// Human-readable track title.
  final String title;

  /// Current playback state.
  final PlaybackStatus status;

  /// Playback rate multiplier (defaults to `1.0` during schema migrations).
  final double playbackSpeed;

  /// Optional local file path to album artwork, cloned via APFS `clonefile(2)`.
  final String? artworkPath;
}

/// Sealed algebraic data type representing interactive widget actions.
@BridgeModel()
sealed class WidgetAction {
  /// Creates a [WidgetAction].
  const WidgetAction();
}

/// Toggles playback from an iOS 17+ interactive `Button(intent:)`.
@BridgeModel()
final class TogglePlayAction extends WidgetAction {
  /// Creates a [TogglePlayAction].
  const TogglePlayAction();
}

/// Seeks to [positionMs] from an interactive extension intent.
@BridgeModel()
final class SeekAction extends WidgetAction {
  /// Creates a [SeekAction].
  const SeekAction({required this.positionMs});

  /// Target playback position in milliseconds.
  final int positionMs;
}

/// Static attributes for an `ActivityKit` Live Activity.
@BridgeModel()
class WorkoutDeliveryAttributes {
  /// Creates [WorkoutDeliveryAttributes].
  const WorkoutDeliveryAttributes({required this.sessionId});

  /// Unique workout session identifier.
  final String sessionId;
}

/// Dynamic content state for an `ActivityKit` Live Activity.
@BridgeModel()
class WorkoutDeliveryContentState {
  /// Creates [WorkoutDeliveryContentState].
  const WorkoutDeliveryContentState({
    required this.elapsedSeconds,
    required this.heartRateBpm,
  });

  /// Elapsed workout duration in seconds.
  final int elapsedSeconds;

  /// Current heart rate in beats per minute.
  final int heartRateBpm;
}

/// Example `@AppGroupSchema` contract combining state, queue, signal, and Live
/// Activity definitions.
@AppGroupSchema(
  groupId: 'group.com.example.pulsehub',
  swiftPackageName: 'PulseHubExtensionKit',
  schemaVersion: 1,
)
abstract class PulseHubSchema {
  /// Atomic snapshot state shared with `NowPlayingWidget` and `PlaybackControl`.
  @SharedState(
    reloadWidgets: ['NowPlayingWidget'],
    reloadControls: ['PlaybackControl'],
  )
  NowPlayingState get nowPlaying;

  /// Lock-free Maildir queue of actions enqueued by extensions.
  @SharedQueue(maxItems: 128)
  WidgetAction get actionQueue;

  /// Zero-disk 32-bit `<notify.h>` signal RPC.
  @DarwinSignal()
  void onSkipTrack(int delta);

  /// Live Activity contract for Dynamic Island & Lock Screen banners.
  @LiveActivitySchema(
    attributes: WorkoutDeliveryAttributes,
    contentState: WorkoutDeliveryContentState,
    key: 'workout_session',
  )
  void workoutActivity();
}
