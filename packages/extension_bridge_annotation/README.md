# `extension_bridge_annotation`

Zero-dependency Dart annotations for declaring type-safe cross-process contracts between Flutter and Darwin App Extensions (**WidgetKit**, **iOS 17+ Interactive `AppIntents`**, **ActivityKit Live Activities & Dynamic Island**, **Share/Action Extensions**, and **iOS 18 `ControlWidget`**).

Used in tandem with [`extension_bridge`](https://github.com/hkarmoush/flutter-app-extension-bridge/tree/main/packages/extension_bridge) (the pure-Dart `dart:ffi` runtime) and [`extension_bridge_generator`](https://github.com/hkarmoush/flutter-app-extension-bridge/tree/main/packages/extension_bridge_generator) (the AST-driven Dart & Swift 6 Package code generator).

---

## Overview of Annotations

| Annotation | Target | Generated Artifacts |
|---|---|---|
| `@AppGroupSchema` | `abstract class` | Generates the typed Dart FFI client (`<Name>Bridge`), deterministic test double (`Fake<Name>Bridge`), and local Swift 6 Package (`ios/<swiftPackageName>/Package.swift`). |
| `@SharedState` | Getter on Schema | Generates `0xdead10cc`-proof lock-free snapshot `read()`, `write()`, CAS `update()`, and reactive `<notify.h>` `watch()` stream in Dart & Swift. |
| `@SharedQueue` | Getter on Schema | Generates a lock-free Maildir multi-producer queue (`tmp/` -> `ready/` -> `inflight/`) ordered by a Hybrid Logical Clock (HLC). |
| `@DarwinSignal` | Method on Schema | Generates a zero-disk ~19 µs cross-process `<notify.h>` signal RPC (packing optional 32-bit payloads directly in the kernel state register). |
| `@LiveActivitySchema` | Method on Schema | Generates cross-platform `Attributes` & `ContentState` models + `#if canImport(ActivityKit) && os(iOS)` `ActivityAttributes` and `@_cdecl` controllers. |
| `@BridgeModel` | `class` / `sealed class` / `enum` | Generates immutable Dart value classes and Swift 6 `Codable, Sendable, Equatable` structs or enums with associated values. |
| `@SharedAttachment` | `String` / `String?` field | Stages file paths into `<AppGroup>/extension_bridge/blobs/` via APFS `clonefile(2)` (`CLONE_NOOWNERCOPY`) with automatic lifecycle GC. |
| `@Default` / `@DefaultEnumValue` | Field / Enum case | Synthesizes forward- and backward-compatible `Codable` / JSON fallbacks across app and extension version skews. |

---

## Quick Example

```dart
import 'package:extension_bridge_annotation/extension_bridge_annotation.dart';

@BridgeModel()
enum PlaybackStatus {
  @DefaultEnumValue()
  idle,
  playing,
  paused,
}

@BridgeModel()
class NowPlayingState {
  const NowPlayingState({
    required this.trackId,
    required this.title,
    required this.status,
    @Default(1.0) this.playbackSpeed = 1.0,
    @SharedAttachment() this.artworkPath,
  });

  final String trackId;
  final String title;
  final PlaybackStatus status;
  final double playbackSpeed;
  final String? artworkPath;
}

@BridgeModel()
sealed class WidgetIntentAction {
  const WidgetIntentAction();
}

@BridgeModel()
final class TogglePlayPauseAction extends WidgetIntentAction {
  const TogglePlayPauseAction();
}

@BridgeModel()
final class SeekToPositionAction extends WidgetIntentAction {
  const SeekToPositionAction({required this.positionMs});
  final int positionMs;
}

@AppGroupSchema(
  groupId: 'group.com.example.pulsehub',
  swiftPackageName: 'PulseHubExtensionKit',
  schemaVersion: 1,
)
abstract class PulseHubSchema {
  @SharedState(
    reloadWidgets: ['NowPlayingWidget'],
    reloadControls: ['NowPlayingControl'],
  )
  NowPlayingState get nowPlaying;

  @SharedQueue(maxItems: 128)
  WidgetIntentAction get pendingWidgetActions;

  @DarwinSignal()
  void onAudioSkipCommand(int direction);
}
```

---

## Documentation & Reference

- [Complete Schema DSL Reference](https://github.com/hkarmoush/flutter-app-extension-bridge/blob/main/doc/reference/schema-dsl-reference.md)
- [Contributing & Architecture Guide](https://github.com/hkarmoush/flutter-app-extension-bridge/blob/main/CONTRIBUTING.md)
