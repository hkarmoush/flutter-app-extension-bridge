import Darwin
import Foundation

/// The 16-bit magic header (`0xEB42`, "ExtensionBridge 42") stored in bits
/// `63..48` of every initialized `<notify.h>` 64-bit state register.
public let kKernelStateRegisterMagic: UInt16 = 0xEB42

/// Zero-cost value wrapper around the 64-bit Darwin `<notify.h>` kernel state
/// register managed by `notifyd`.
///
/// ### 64-Bit Register Layout
/// ```text
///  63              48 47              32 31                                 0
/// +------------------+------------------+------------------------------------+
/// | 16-bit Magic 0xEB| 16-bit Writer ID |     32-bit Monotonic Generation    |
/// +------------------+------------------+------------------------------------+
/// ```
///
/// - **Bits `63..48` (``magic``):** `0xEB42` when initialized. If `notifyd`
///   garbage-collects a notification token after all processes exit, the
///   register resets to `0x0` (`!hasValidMagic`), signaling cold-start readers
///   to seed `notify_set_state` from the authoritative APFS `_gen` header.
/// - **Bits `47..32` (``writerId``):** 16-bit logical writer identifier mixing
///   `getpid()` with an instance-unique nonce. Allows O(1) self-echo
///   cancellation even when iOS 17+ `AppIntent.perform()` runs in-process
///   inside the host `Runner` binary.
/// - **Bits `31..0` (``generation`` / ``signedPayload32``):** Monotonic 32-bit
///   generation counter for `@SharedState` / `@SharedQueue`, or an inline
///   32-bit payload for zero-disk `@DarwinSignal` RPCs.
public struct KernelStateRegister: Sendable, Equatable, Hashable, CustomStringConvertible {
    /// Raw 64-bit unsigned integer stored in `notifyd`.
    public let rawBits: UInt64

    /// Uninitialized register value (`0x0000000000000000`) returned by `notifyd`
    /// before any writer or cold-start seeder calls `notify_set_state`.
    public static let zero = KernelStateRegister(rawBits: 0)

    /// Creates a ``KernelStateRegister`` wrapping ``rawBits``.
    @inlinable
    public init(rawBits: UInt64) {
        self.rawBits = rawBits
    }

    /// Packs `magic`, `writerId`, and `generation` into a single 64-bit
    /// `<notify.h>` register.
    @inlinable
    public static func pack(
        writerId: UInt16,
        generation: UInt64,
        magic: UInt16 = kKernelStateRegisterMagic
    ) -> KernelStateRegister {
        let m = UInt64(magic) << 48
        let w = UInt64(writerId) << 32
        let g = generation & 0xFFFF_FFFF
        return KernelStateRegister(rawBits: m | w | g)
    }

    /// Packs a signed 32-bit signal `payload` into a 64-bit `<notify.h>`
    /// register for zero-disk `@DarwinSignal` delivery.
    @inlinable
    public static func packSignal(
        writerId: UInt16,
        payload: Int32 = 0,
        magic: UInt16 = kKernelStateRegisterMagic
    ) -> KernelStateRegister {
        let unsignedPayload = UInt64(UInt32(bitPattern: payload))
        return pack(writerId: writerId, generation: unsignedPayload, magic: magic)
    }

    /// Extracts the 16-bit magic header from bits `63..48`.
    @inlinable
    public var magic: UInt16 {
        UInt16((rawBits >> 48) & 0xFFFF)
    }

    /// Whether bits `63..48` match ``kKernelStateRegisterMagic`` (`0xEB42`).
    @inlinable
    public var hasValidMagic: Bool {
        magic == kKernelStateRegisterMagic
    }

    /// Whether this register is uninitialized (`0`) or lacks a valid magic
    /// header, requiring cold-start seeding from the APFS snapshot.
    @inlinable
    public var isUnseeded: Bool {
        rawBits == 0 || !hasValidMagic
    }

    /// Extracts the 16-bit logical writer identifier from bits `47..32`.
    @inlinable
    public var writerId: UInt16 {
        UInt16((rawBits >> 32) & 0xFFFF)
    }

    /// Extracts the unsigned 32-bit generation counter (or unsigned signal
    /// payload) from bits `31..0`.
    @inlinable
    public var generation: UInt32 {
        UInt32(rawBits & 0xFFFF_FFFF)
    }

    /// Extracts bits `31..0` as a two's-complement signed 32-bit integer for
    /// `@DarwinSignal` payloads that may be negative.
    @inlinable
    public var signedPayload32: Int32 {
        Int32(bitPattern: generation)
    }

    /// Returns `true` if this register was written by `localWriterId`.
    @inlinable
    public func isFromWriter(_ localWriterId: UInt16) -> Bool {
        hasValidMagic && writerId == localWriterId
    }

    /// Determines whether a `<notify.h>` state wakeup can be dropped in O(1)
    /// without touching the disk.
    ///
    /// A state notification is suppressed if the register has a valid magic
    /// header and **either**:
    /// 1. It was emitted by `localWriterId` (`isFromWriter(localWriterId)`), or
    /// 2. `localGeneration` is known and the register's `generation` is already
    ///    `<= localGeneration` (modulo 32-bit mask) in memory.
    @inlinable
    public func shouldSuppressStateWakeup(
        localWriterId: UInt16,
        localGeneration: UInt64? = nil
    ) -> Bool {
        guard hasValidMagic else { return false }
        if writerId == localWriterId {
            return true
        }
        if let localGen = localGeneration {
            let maskedLocalGen = UInt32(localGen & 0xFFFF_FFFF)
            if generation <= maskedLocalGen {
                return true
            }
        }
        return false
    }

    /// Formats the 64-bit register as a fixed-width 16-digit lowercase
    /// hexadecimal literal (e.g., `"0xeb42483c0000002a"`).
    public func toHexString() -> String {
        String(format: "0x%016llx", rawBits)
    }

    public var description: String {
        "KernelStateRegister(\(toHexString()))"
    }

    /// Generates a non-zero 16-bit logical writer ID (`1..0xFFFF`) by mixing
    /// the OS process ID (`pid`) with a per-instance `instanceNonce`.
    ///
    /// Mixing an instance nonce with `getpid()` guarantees that even when
    /// iOS 17+ executes an `AppIntent.perform()` inside the host `Runner`
    /// process on a background Swift thread, the Swift writer and Dart listener
    /// have distinct 16-bit writer IDs.
    public static func deriveLogicalWriterId(
        pid: Int32 = getpid(),
        instanceNonce: UInt32? = nil
    ) -> UInt16 {
        let salt = instanceNonce ?? UInt32.random(in: 1...UInt32.max)
        let pidBits = UInt32(bitPattern: pid)
        var hash = (pidBits &* 0x9E37_79B1) ^ (salt &* 0x85EB_CA6B)
        hash ^= hash >> 16
        hash = hash &* 0x7FEB_352D
        hash ^= hash >> 15
        let id16 = UInt16(hash & 0xFFFF)
        return id16 == 0 ? 1 : id16
    }
}
