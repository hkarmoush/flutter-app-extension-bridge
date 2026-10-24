# Pivot Draft: Gap #1 vs. Gap #4

Following the market research on `pod2spm` (where `spm_migrator` already covers the template cases and 90% of top-100 plugins have migrated), this document outlines the initial draft for the two high-leverage, unclaimed evergreen gaps in the Flutter + iOS ecosystem:

1. **Gap #1: "Pigeon for iOS App Extensions"** — Type-Safe Cross-Process App Group, `NSFileCoordinator`, & Darwin Notification Bridge (+ Codegen).
2. **Gap #4: `CKSyncEngine` iCloud Sync Bridge for Flutter** — Modern Record-Zone Sync for Local-First Flutter Apps (Drift / SQLite).

---

## Option A — Gap #1: "Pigeon for iOS App Extensions"
**Working Titles:** `darwin_extension_bridge` / `app_group_pigeon` / `flutter_extension_sync`

### 1. The Core Problem
Every serious iOS app today ships with **App Extensions**:
- **WidgetKit** (Home Screen & Lock Screen widgets)
- **Live Activities** & Dynamic Island (`ActivityKit`)
- **Interactive Widgets** (iOS 17+ `AppIntents` running in extension/system processes)
- **Share Extensions** & **Action Extensions**
- **Control Center Widgets** (iOS 18+ `ControlWidget`)
- **Notification Service Extensions** & **Siri Intents**

**Why `MethodChannel` and `Pigeon` fail here:**
`MethodChannel`, `EventChannel`, and `Pigeon` only work **in-process** between the main Flutter engine and the main iOS host app (`Runner`). App Extensions run in **completely separate OS processes** with strict memory limits (16–30 MB for widgets) where spinning up a Flutter Engine is either impossible or strongly discouraged by Apple.

Today, Flutter developers use `home_widget` or raw `shared_preferences_foundation`, which forces them to:
1. Manually serialize/deserialize untyped strings/JSON into `UserDefaults(suiteName:)`.
2. Hit silent data corruption because `UserDefaults` is not safe for concurrent multi-process file writes (e.g., a Share Extension or Interactive Widget writing while the main Flutter app is reading/writing).
3. Have **zero real-time reactivity** when an extension mutates state while the Flutter app is in the foreground (because `UserDefaults` notifications don't cross process boundaries without low-level `CFNotificationCenterGetDarwinNotifyCenter()`).

### 2. What Exists Today (and Why It Falls Short)
| Package | Scope | Limitations |
|---|---|---|
| `home_widget` | WidgetKit key-value helper | Untyped string/primitive key-value store (`saveWidgetData<T>`), no Dart↔Swift model codegen, no Darwin Notification event streams, no atomic file coordination, WidgetKit-specific rather than a general extension architecture. |
| `shared_preferences` | App Group `UserDefaults` | In-process cache goes stale when an extension writes to the shared container; no cross-process notification observer; untyped keys. |
| `pigeon` | Type-safe Dart ↔ Native IPC | Strictly **in-process** (`BinaryMessenger`). Cannot communicate with separate extension targets or generate shared `Codable` App Group schemas. |

### 3. Proposed Architecture & Feature Set

A **two-part solution**: a **code generator** (`build_runner` / CLI, like Pigeon) + a **lightweight runtime** (Dart + Swift Package).

#### Layer 1: Schema & Codegen (The "Pigeon" Experience)
Define shared state models and cross-process signals once in a schema file (e.g., `extension_schema.dart`):
```dart
@AppGroupSchema(groupId: 'group.com.example.app')
abstract class PlaybackExtensionContract {
  /// Atomic, file-coordinated shared state accessible in Dart & Swift Extensions
  @SharedState(storage: StorageStrategy.coordinatedJsonFile)
  NowPlayingState get nowPlaying;

  /// Cross-process ring-buffered queue (e.g., Share Extension -> Main App inbox)
  @SharedQueue()
  List<SharedMediaItem> get incomingShares;

  /// Bi-directional zero-payload Darwin Notification signals
  @DarwinSignal()
  void onWidgetActionTriggered();

  @DarwinSignal()
  void onMainAppStateUpdated();
}
```
**Generated Outputs:**
- **Dart (`lib/src/generated/extension_contract.g.dart`):**
  - Type-safe classes with binary/JSON codecs.
  - `Stream<NowPlayingState>` that automatically emits whenever the extension mutates the state (triggered via Darwin Notification + re-read).
  - Atomic `updateNowPlaying((current) => ...)` mutators.
  - `Stream<List<SharedMediaItem>>` inbox consumer that atomically drains items queued by a Share Extension or `AppIntent`.
- **Swift (`ios/SharedExtensionKit/GeneratedContract.swift`):**
  - Pure Swift `Codable, Sendable, Equatable` structs ready to drop into `WidgetExtension`, `ShareExtension`, and `Runner` targets via a local Swift Package.
  - Async/await Swift API (`PlaybackExtensionContract.shared.readNowPlaying()`, `appendIncomingShare(...)`) backed by `NSFileCoordinator`.

#### Layer 2: Multi-Process Safe Storage Engine
- **`NSFileCoordinator` + Atomic File Writes:** Avoids `UserDefaults` plist corruption and size limits by storing shared state in the App Group container (`FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:)`) with proper `NSFileCoordinator` read/write locks across processes.
- **Transactional Inbox Queue:** Solves the classic "User shares 3 photos via Share Extension while main Flutter app is killed or backgrounded" problem using an append-only or directory-based atomic queue.

#### Layer 3: Darwin Notification Center Bridge (`CFNotificationCenterGetDarwinNotifyCenter`)
- Darwin notifications are the only official low-overhead IPC signal across iOS processes, but they **cannot carry a payload** (`userInfo` is ignored by the kernel).
- The runtime pairs **Darwin Notifications (the wakeup signal)** with **Coordinated App Group Storage (the payload)**:
  1. Interactive Widget / Share Extension writes payload to the App Group container via `NSFileCoordinator`.
  2. Extension posts a Darwin notification (`com.example.app.signal.nowPlaying`).
  3. If the Flutter app is alive, its C/FFI or Swift Darwin observer fires immediately, reads the updated file off the main thread, and pushes the decoded Dart object into a Dart `Stream`.
  4. If the Flutter app was cold/suspended, it reconciles the latest state automatically on `AppLifecycleState.resumed`.

#### Layer 4: First-Class Extension Triggers
- Built-in hooks for `WidgetCenter.shared.reloadTimelines(ofKind:)`, `ControlCenter.shared.reloadControls(ofKind:)` (iOS 18), and reading memory limits in extensions.

---

## Option B — Gap #4: `CKSyncEngine` iCloud Sync Bridge for Flutter
**Working Titles:** `flutter_cksync_engine` / `cloudkit_sync_engine` / `drift_icloud_sync`

### 1. The Core Problem
In **iOS 17 / macOS 14 (WWDC23)**, Apple introduced **`CKSyncEngine`** — a massive leap forward that replaces thousands of lines of error-prone `CKModifyRecordsOperation` / `CKFetchRecordZoneChangesOperation` boilerplate with the exact sync state machine Apple uses for Notes and Reminders.

Meanwhile, in the Flutter ecosystem:
- **Local-first apps** (using `drift`, `sqflite`, `sqlite3`) are booming, and iOS/macOS users expect **zero-signup, free iCloud sync** out of the box (no Firebase account, no backend subscription costs for the indie/mid-size developer).
- Existing CloudKit packages on `pub.dev` (`icloud_storage`, `cloud_kit`) are either simple file uploaders (iCloud Drive documents) or thin wrappers around basic single-record CRUD without `CKServerChangeToken` tracking, conflict resolution, batching, or push notification sync.

### 2. What `CKSyncEngine` Solves (and Why Bridging It to Dart Is High Value)
`CKSyncEngine` natively handles:
- **Change Token Management:** Persisting `CKSyncEngine.State.Serialization` automatically.
- **Network & Battery Scheduling:** Automatic retry on `zoneBusy`, `serviceUnavailable`, rate-limiting (`retryAfterSeconds`), and offline queueing.
- **Push Notification Integration:** Automatically listening for silent APNs CloudKit pushes and fetching incremental record deltas.
- **Account Transitions:** Detecting iCloud sign-in, sign-out, and account switches cleanly.

### 3. Proposed Architecture & Feature Set
1. **Core `flutter_cksync_engine` Plugin (SwiftPM-native):**
   - Bridges `CKSyncEngineDelegate` events (`handleEvent`, `nextRecordZoneChangeBatch`) to Dart via a structured async protocol.
   - Serializes `CKRecord` system fields (`encodedSystemFields`) alongside custom fields so Dart's local database stores the base server record for **3-way conflict resolution** (`serverRecordChanged`).
   - Handles `CKAsset` file paths for syncing images/audio alongside structured rows.
2. **Drop-in `drift` Adapter (`drift_cksync_engine`):**
   - Tracks local table changes via SQLite triggers or a local `pending_sync_changes` outbox table.
   - Feeds pending record IDs to `CKSyncEngine.state.add(pendingRecordZoneChanges:)`.
   - Applies incoming `fetchedRecordZoneChanges` and deletions directly into local tables inside a single transaction.

---

## Head-to-Head Comparison: Which Should We Build First?

| Criterion | Gap #1: "Pigeon for App Extensions" | Gap #4: `CKSyncEngine` iCloud Bridge |
|---|---|---|
| **Target Audience Size** | **Massive.** Nearly every polished consumer iOS Flutter app builds a Widget, Share Extension, or Live Activity. | **Medium-High.** Focused on productivity, note-taking, finance, tracker, and local-first iOS/macOS apps. |
| **Testing & DX Complexity** | **Fast local iteration.** Can be tested entirely in iOS Simulator with two targets (Runner + Widget/Share Extension) and unit tests. | **Higher friction.** Requires an active paid Apple Developer account, iCloud container provisioning, and physical device testing for silent APNs push sync. |
| **Architectural Appeal** | Showcases **Compiler/Codegen (Dart `analyzer`/`build`) + Systems iOS (`CFNotificationCenter`, `NSFileCoordinator`, Swift Concurrency, SwiftPM)**. | Showcases **Distributed Systems / Local-First Sync (`CKSyncEngine`, CRDT/3-way merge, SQLite/Drift integration)**. |
| **Complements Existing Ecosystem** | Pairs *with* `home_widget` or replaces its data layer; gives Share Extensions & Interactive Widgets a real architecture. | Pairs naturally with `drift` and `sqlite3`. |

### Recommendation
**Start with Gap #1 ("Pigeon for iOS App Extensions").**
1. It is immediately testable in CI without Apple CloudKit server credentials.
2. It solves an acute architectural pain point across **four** Apple frameworks (`WidgetKit`, `ActivityKit`, `AppIntents`, Share Extensions).
3. Combining **Dart codegen + Swift Package Manager + Darwin kernel notifications + `NSFileCoordinator`** makes it a standout systems-level open-source project.
