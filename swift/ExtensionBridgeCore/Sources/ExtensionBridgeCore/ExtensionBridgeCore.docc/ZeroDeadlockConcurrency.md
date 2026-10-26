# Zero-Deadlock (`0xdead10cc`-Proof) Concurrency

Learn how `ExtensionBridgeCore` achieves strict serializability across the Flutter host app and iOS/macOS App Extensions without holding kernel file locks.

## Overview

When any iOS process holds an open file lock (`flock(2)`, `fcntl(2)`, SQLite WAL shared-memory lock, or `NSFileCoordinator` lock) inside a shared App Group container (`group.*`) and is suspended by SpringBoard, the iOS kernel terminates the process with exception **`0xdead10cc`**.

``AtomicStateStore`` eliminates this class of crashes entirely through **immutable snapshot replacement** and **zero-FD POSIX symlink leases**.

### 1. Zero-Lock Snapshot Reads

State files (`state/<key>.v<version>.json`) are never mutated in place. Writers serialize to a hidden sibling staging file (`state/.<key>.v<version>.tmp.<nonce>`) and commit via POSIX `rename(2)`, which atomically replaces the directory entry on APFS. Readers open and read the active snapshot with zero locks—always observing either the complete previous generation or the complete new generation.

### 2. Out-of-Band Serialization & Zero-FD `.cas` Symlink Leases

Both ``AtomicStateStore/write(_:)`` and ``AtomicStateStore/update(_:)`` execute the following 8-step Compare-And-Swap (CAS) state machine:

1. **Snapshot Read:** Read the current authoritative snapshot (`expectedGen`) from APFS.
2. **Pure Mutator Evaluation:** Run the caller's pure closure (`mutator(current)`) to compute the next state for `expectedGen + 1`.
3. **Out-of-Band Staging (`< 15 µs` Critical Section):** Clone any `@SharedAttachment` files into `blobs/` via `clonefile(2)` and write + `fsync(2)` the complete JSON envelope to `.tmp.<nonce>` **before** entering the `.cas` critical section.
4. **Atomic Symlink Lease (`symlink("<pid>:<ts_us>:<nonce>", ".<key>.v1.cas")`):** Acquire the lease using an atomic POSIX symbolic link that requires zero open file descriptors.
5. **Instant Dead-Process Eviction (`kill(pid, 0) == ESRCH`):** If `.cas` already exists (`EEXIST`), read the symlink target via `readlink(2)` and probe `kill(holderPid, 0)`. If `errno == ESRCH`, the previous extension was killed (`SIGKILL` / Jetsam OOM) and its orphaned lease is evicted in **< 1 ms**.
6. **Generation & Split-Brain Verification:** Verify that the on-disk `_gen` still equals `expectedGen` and that `readlink(".cas") == myLease.encode()`.
7. **Atomic Commit:** Execute `rename(".tmp.<nonce>", "<key>.v1.json")` and unlink `.cas`.
8. **Kernel Broadcast:** Update the 64-bit `<notify.h>` state register (`[0xEB42 | writerId | nextGen]`) and post the notification.
