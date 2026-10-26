# ``ExtensionBridgeCore``

Type-safe, `0xdead10cc`-proof lock-free storage, `<notify.h>` 64-bit state register IPC, and zero-copy APFS `clonefile(2)` media queues for iOS and macOS App Extensions.

## Overview

`ExtensionBridgeCore` is the pure Swift 6 runtime counterpart to `package:extension_bridge` on Dart. It powers generated `<Name>ExtensionKit` Swift packages shared across your Flutter host application (`Runner`) and Darwin App Extensions:

- **WidgetKit (`TimelineProvider` & iOS 17+ interactive `AppIntent`)**
- **Share & Action Extensions (`UIShareExtension`)**
- **ActivityKit Live Activities & Dynamic Island (`ActivityAttributes`)**
- **iOS 18 Control Center Widgets (`ControlWidget` & `ControlConfigurationIntent`)**

### Key Architectural Guarantees

1. **`0xdead10cc`-Proof Lock-Free Snapshots & Symlink CAS:**
   Never acquires kernel advisory locks (`flock`, `fcntl`), SQLite WAL locks, or `NSFileCoordinator` locks inside the shared App Group container. Readers read immutable snapshot files with zero locks; writers serialize to `.tmp` out-of-band, acquire a zero-FD POSIX symlink lease (`state/.<key>.v1.cas`), probe `kill(pid, 0) == ESRCH` for `< 1 ms` dead-process eviction, and atomically swap the snapshot via `rename(2)`.
2. **Two-Stage `~299 ns` Shared-Memory Read Fast Path:**
   ``AtomicStateStore/read()`` checks `notifyd`'s process-mapped shared-memory slot via `notify_check` in ~299 ns with zero Mach IPC, touching APFS only when a newer generation has actually been committed.
3. **Zero-Copy APFS `clonefile(2)` Attachments:**
   ``SharedAttachmentManager`` and ``ApfsFileCloner`` clone large photos and 4K videos into `<AppGroup>/extension_bridge/blobs/` using `clonefile(src, dst, CLONE_NOOWNERCOPY)` in ~0.3 ms with 0 extra disk bytes and < 50 KB of RAM, keeping Share Extensions well below the 16–30 MB Jetsam ceiling.

### Quick Example

```swift
import ExtensionBridgeCore

struct NowPlayingState: Codable, Sendable, Equatable {
    var title: String
    var isPlaying: Bool
}

let vault = try ExtensionBridgeVault(groupId: "group.com.example.pulsehub")
let nowPlaying = vault.stateStore(key: "now_playing", type: NowPlayingState.self)

// Atomic lock-free CAS update from an iOS 17 AppIntent:
try nowPlaying.update { current in
    var next = current ?? NowPlayingState(title: "Unknown", isPlaying: false)
    next.isPlaying.toggle()
    return next
}
```

## Topics

### Essentials

- <doc:ZeroDeadlockConcurrency>
- <doc:KernelRegisterProtocol>
- ``ExtensionBridgeVault``
- ``ContainerLayout``
- ``AppGroupContainerResolver``
- ``ExtensionBridgeError``

### Lock-Free Atomic State Store (`@SharedState`)

- ``AtomicStateStore``
- ``SnapshotResult``
- ``StateEnvelope``
- ``StateEnvelopeHeader``
- ``StateEnvelopeCodec``
- ``CasLeaseToken``
- ``kDefaultCasLeaseCeilingMicros``
- ``kStateEnvelopeMagic``

### Maildir Queue & Zero-Copy Attachments (`@SharedQueue` & `@SharedAttachment`)

- ``SharedQueueStore``
- ``SharedQueueWriter``
- ``QueueDelivery``
- ``QueueEnqueuedReceipt``
- ``SharedAttachmentManager``
- ``StagedAttachments``
- ``ApfsFileCloner``
- ``ApfsCloneResult``
- ``AttachmentCopyMode``
- ``CloneStrategy``
- ``kClonefileNoOwnerCopyFlag``
- ``kDefaultStateBlobRetentionGenerations``

### Kernel `<notify.h>` Signal Bus (`@DarwinSignal`)

- ``DarwinNotifyCenter``
- ``DarwinNotifySubscription``
- ``DarwinStateWakeupEvent``
- ``DarwinSignalEvent``
- ``KernelStateRegister``
- ``kKernelStateRegisterMagic``

### Hybrid Logical Clocks

- ``HybridLogicalClock``
- ``HlcTimestamp``
- ``kMaxHlcCounter``

### Lifecycle & C-ABI Bridge Support

- ``ExtensionActivityGuard``
- ``ExtensionKitCAbiSupport``
- ``DarwinPosix``
