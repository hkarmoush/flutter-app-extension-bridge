# Kernel `<notify.h>` 64-Bit State Register Protocol

Understand how ``KernelStateRegister`` and ``DarwinNotifyCenter`` deliver sub-300 ns cache hits, ~19 µs cross-process wakeups, and O(1) self-echo suppression.

## Overview

Every Darwin notification token managed by `notifyd` (`<notify.h>`) is backed by both a process-mapped shared-memory (`shm`) generation slot and a kernel-resident 64-bit integer register.

### 64-Bit Register Bit Layout

```text
 63              48 47              32 31                                 0
+------------------+------------------+------------------------------------+
| 16-bit Magic 0xEB| 16-bit Writer ID |     32-bit Monotonic Generation    |
+------------------+------------------+------------------------------------+
```

- **Bits `63..48` (`0xEB42`):** Identifies a seeded `extension_bridge` register. If `notifyd` reclaims a register when all processes exit, the register reads as `0x0` (``KernelStateRegister/isUnseeded``), prompting the next reader to seed `notify_set_state` from the APFS snapshot's `_gen` header.
- **Bits `47..32` (``KernelStateRegister/writerId``):** 16-bit logical writer identifier derived by mixing `getpid()` with an instance-unique nonce (``KernelStateRegister/deriveLogicalWriterId(pid:instanceNonce:)``). Even when iOS 17+ runs an interactive `AppIntent.perform()` in-process inside the Flutter host binary, the Swift `AppIntent` writer and Dart listener have distinct `writerId`s.
- **Bits `31..0` (``KernelStateRegister/generation`` / ``KernelStateRegister/signedPayload32``):** Monotonic 32-bit generation counter for `@SharedState` / `@SharedQueue`, or a signed 32-bit payload for zero-disk `@DarwinSignal` RPCs.

### Two-Stage Shared-Memory Fast Path

1. **Stage 1 (`notify_check` ~299 ns):** ``DarwinNotifyCenter/checkChanged(_:)`` inspects the `notifyd` shared-memory page mapped directly into the process address space. If `check == 0`, zero notifications have been posted since the last check and ``AtomicStateStore/read()`` returns its cached model immediately with zero syscalls and zero Mach IPC.
2. **Stage 2 (`notify_get_state` ~9.3 µs):** Only when `check == 1` does ``DarwinNotifyCenter/getRegister(_:)`` query the 64-bit register via Mach IPC to compare `reg.generation` against the locally cached generation.
