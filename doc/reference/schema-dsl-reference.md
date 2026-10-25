# Schema DSL & Type Mapping Reference

This document provides the complete technical reference for `package:extension_bridge_annotation` and the Dart ↔ Swift 6 type mapping rules enforced by `extension_bridge_generator`.

---

## 1. Contract & Member Annotations

### 1.1 `@AppGroupSchema`

Declares a cross-process App Group contract on an `abstract class`.

```dart
@AppGroupSchema(
  groupId: 'group.com.example.pulsehub',
  swiftPackageName: 'PulseHubExtensionKit',
  schemaVersion: 1,
  notificationPrefix: 'com.example.pulsehub.eb',
)
abstract class PulseHubSchema { ... }
```

| Parameter | Type | Default | Description |
|---|---|---|---|
| `groupId` | `String` | *(Required)* | The Apple App Group identifier shared across `Runner` and all App Extension targets. Must begin with `'group.'` (`[EB-GEN-002]`). |
| `swiftPackageName` | `String?` | Derived from class name | Name of the generated local Swift 6 Package written to `ios/<swiftPackageName>/Package.swift`. |
| `schemaVersion` | `int` | `1` | Monotonic integer version embedded in `_schema_version` of every JSON envelope (`>= 1`). |
| `notificationPrefix` | `String?` | `<groupId without group.>.eb` | Reverse-DNS prefix used for `<notify.h>` Darwin notification names. |

---

### 1.2 `@SharedState`

Marks a getter on an `@AppGroupSchema` class as an atomic, lock-free snapshot slot backed by APFS `rename(2)` and a 64-bit `<notify.h>` kernel state register.

```dart
@SharedState(
  key: 'now_playing',
  reloadWidgets: ['NowPlayingWidget'],
  reloadControls: ['PlaybackControl'],
)
NowPlayingState get nowPlaying;
```

| Parameter | Type | Default | Description |
|---|---|---|---|
| `key` | `String?` | `snake_case` getter name | On-disk filename stem (`state/<key>.v<schemaVersion>.json`). |
| `reloadWidgets` | `List<String>?` | `null` | `WidgetKit` `kind` strings reloaded automatically via `WidgetCenter.shared.reloadTimelines(ofKind:)` when Dart mutates this state (`['*']` reloads all timelines). |
| `reloadControls` | `List<String>?` | `null` | iOS 18 `ControlWidget` `kind` strings reloaded via `ControlCenter.shared.reloadControls(ofKind:)` when Dart mutates this state. |
| `notificationName` | `String?` | `<prefix>.state.<key>` | Explicit `<notify.h>` Darwin notification key override. |

#### Generated Operations
- **Dart (`<Name>Bridge` & `Fake<Name>Bridge`):**
  - `Future<T?> read<Key>()` / `T? read<Key>Sync()` — Two-stage ~299 ns `notify_check` shared-memory fast path → `notify_get_state` → lock-free APFS snapshot read.
  - `Future<StateEnvelope<T>> write<Key>(T value)` — Out-of-band `.tmp` serialization + `.cas` symlink lease + atomic `rename(2)` + `<notify.h>` post.
  - `Future<StateEnvelope<T>> update<Key>(T Function(T? current) mutator)` — Lock-free optimistic concurrency control (CAS loop) with instant `kill(pid, 0) == ESRCH` dead-process lease eviction.
  - `Stream<T> watch<Key>({bool emitInitial = true})` — Reactive broadcast stream driven by `notify_register_dispatch` with O(1) self-echo cancellation.
- **Swift 6 (`<swiftPackageName>`):**
  - `func read<Key>() throws -> T?`
  - `func write<Key>(_ value: T) throws -> StateEnvelope<T>`
  - `func update<Key>(_ mutator: @Sendable (T?) throws -> T) throws -> StateEnvelope<T>`
  - `func watch<Key>() -> AsyncStream<T>`

---

### 1.3 `@SharedQueue`

Marks a getter on an `@AppGroupSchema` class as a lock-free Maildir multi-producer queue (`queue/<key>/{tmp,ready,inflight}/`) ordered by a Hybrid Logical Clock (HLC).

```dart
@SharedQueue(key: 'share_inbox', maxItems: 128)
SharedMediaItem get shareInbox;
```

| Parameter | Type | Default | Description |
|---|---|---|---|
| `key` | `String?` | `snake_case` getter name | Queue directory name under `extension_bridge/queue/<key>/`. |
| `maxItems` | `int` | `256` | Maximum committed items retained in `ready/` (`>= 1`). |
| `notificationName` | `String?` | `<prefix>.queue.<key>` | Explicit `<notify.h>` Darwin notification key override. |

---

### 1.4 `@DarwinSignal`

Marks a method on an `@AppGroupSchema` class as a zero-disk cross-process `<notify.h>` signal RPC.

```dart
@DarwinSignal(name: 'playback_command')
void sendPlaybackCommand(int commandCode);
```

- **Supported Signatures:**
  - `void methodName()` — Stateless trigger transmitted in ~19 µs P50.
  - `void methodName(int payload)` — Signed or unsigned 32-bit integer packed into bits `31..0` of the 64-bit `<notify.h>` state register (`[0xEB42 | writerId | payload32]`).
  - `void methodName(bool payload)` — Packed as `0` or `1` in bits `31..0`.
  - `void methodName(MyEnum payload)` — Packed as the enum declaration index in bits `31..0`.

---

### 1.5 `@LiveActivitySchema`

Declares an `ActivityKit` Live Activity & Dynamic Island contract on an `@AppGroupSchema` member.

```dart
@LiveActivitySchema(
  attributes: DeliveryAttributes,
  contentState: DeliveryContentState,
  key: 'delivery_tracker',
)
void deliveryActivity();
```

| Parameter | Type | Default | Description |
|---|---|---|---|
| `attributes` | `Type` | *(Required)* | `@BridgeModel` class representing static `ActivityAttributes`. |
| `contentState` | `Type` | *(Required)* | `@BridgeModel` class representing dynamic `Activity.ContentState`. |
| `key` | `String?` | `snake_case` member name | C-ABI symbol stem (`eb_la_<key>_start`, `eb_la_<key>_update`, `eb_la_<key>_end`). |

---

## 2. Model & Field Annotations

### 2.1 `@BridgeModel`

Marks a Dart `class`, `sealed class`, or `enum` for cross-language Dart ↔ Swift 6 code generation.

```dart
@BridgeModel(discriminatorKey: '_type')
sealed class WidgetAction {
  const WidgetAction();
}
```

| Parameter | Type | Default | Description |
|---|---|---|---|
| `discriminatorKey` | `String` | `'_type'` | JSON discriminator key used when encoding/decoding Dart 3 `sealed class` subclasses into Swift 6 `enum` cases with associated values. |

### 2.2 `@SharedAttachment`

Marks a `String` or `String?` field on a `@BridgeModel` class as a file path that is automatically cloned into `<AppGroup>/extension_bridge/blobs/` via APFS `clonefile(src, dst, CLONE_NOOWNERCOPY)` on write and resolved back to an absolute path on read.

```dart
@SharedAttachment(copyMode: AttachmentCopyMode.cloneOrStream)
final String? mediaPath;
```

### 2.3 `@Default` & `@DefaultEnumValue`

Provide schema-evolution resilience when an updated Widget or App Extension decodes JSON written by an older or newer binary:
- `@Default(constantValue)` on a field emits `try container.decodeIfPresent(T.self, forKey: .field) ?? defaultValue` in Swift 6 and `json['field'] as T? ?? defaultValue` in Dart.
- `@DefaultEnumValue()` on an `enum` value designates the fallback case when decoding an unrecognized future string wire value.

---

## 3. Complete Dart ↔ Swift 6 Type Matrix

| Dart Type | Generated Swift 6 Type | Wire Representation & Notes |
|---|---|---|
| `int` | `Int64` | 64-bit signed integer |
| `double` | `Double` | IEEE 754 64-bit float |
| `bool` | `Bool` | JSON boolean (`true` / `false`) |
| `String` | `String` | UTF-8 JSON string |
| `DateTime` | `Date` | Serialized as UTC Unix epoch microseconds (`Int64`); converted in Swift via `Date(timeIntervalSince1970: Double(us) / 1_000_000.0)` |
| `Duration` | `TimeInterval` (`Double`) | Serialized as `Int64` microseconds; converted in Swift via `TimeInterval(us) / 1_000_000.0` (seconds) |
| `List<T>` | `[T]` | Recursive `Codable, Sendable, Equatable` array |
| `Map<String, V>` | `[String: V]` | Recursive `Codable, Sendable, Equatable` dictionary |
| `Set<T>` | `Set<T>` | JSON array encoded/decoded as a deduplicated `Set` |
| `T?` | `T?` (`Optional<T>`) | Nullable field (`decodeIfPresent`) |
| `@BridgeModel() enum E` | `public enum E: String, Codable, Sendable, CaseIterable` | Custom `init(from:)` falls back to `@DefaultEnumValue()` or `.first` on unknown future cases |
| `@BridgeModel() class M` | `public struct M: Codable, Sendable, Equatable, Hashable` | Explicit `init(from:)` and `encode(to:)` for schema evolution |
| `@BridgeModel() sealed class S` | `public enum S: Codable, Sendable, Equatable, Hashable` | Each final subclass becomes a Swift `case` with typed associated values switched on `"_type"` |
