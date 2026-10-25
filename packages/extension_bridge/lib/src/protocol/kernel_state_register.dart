import 'dart:math' as math;

/// The 16-bit magic header (`0xEB42`, "ExtensionBridge 42") stored in bits
/// `63..48` of every initialized `<notify.h>` 64-bit state register.
const int kKernelStateRegisterMagic = 0xEB42;

/// Bit mask for a 16-bit unsigned field (`0xFFFF`).
const int _kMask16 = 0xFFFF;

/// Bit mask for a 32-bit unsigned field (`0xFFFFFFFF`).
const int _kMask32 = 0xFFFFFFFF;

/// {@template extension_bridge.kernel_state_register}
/// Zero-cost wrapper around the 64-bit Darwin `<notify.h>` kernel state
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
/// - **Bits `63..48` ([magic]):** `0xEB42` when initialized. If `notifyd`
///   garbage-collects a notification token after all processes exit, the
///   register resets to `0x0` (`!hasValidMagic`), signaling cold-start readers
///   to seed `notify_set_state` from the authoritative APFS `_gen` header.
/// - **Bits `47..32` ([writerId]):** 16-bit logical writer identifier mixing
///   `getpid()` with an instance-unique nonce. Allows O(1) self-echo
///   cancellation even when iOS 17+ `AppIntent.perform()` runs in-process
///   inside the host `Runner` binary.
/// - **Bits `31..0` ([generation] / [signedPayload32]):** Monotonic 32-bit
///   generation counter for `@SharedState` / `@SharedQueue`, or an inline
///   32-bit payload for zero-disk `@DarwinSignal` RPCs.
/// {@endtemplate}
extension type const KernelStateRegister(int rawBits) {
  /// Packs [magic], [writerId], and [generation] into a single 64-bit
  /// `<notify.h>` register integer.
  factory KernelStateRegister.pack({
    required int writerId,
    required int generation,
    int magic = kKernelStateRegisterMagic,
  }) =>
      KernelStateRegister(
        ((magic & _kMask16) << 48) |
            ((writerId & _kMask16) << 32) |
            (generation & _kMask32),
      );

  /// Packs a signed or unsigned 32-bit signal [payload] into a 64-bit
  /// `<notify.h>` register for zero-disk `@DarwinSignal` delivery.
  factory KernelStateRegister.packSignal({
    required int writerId,
    int payload = 0,
    int magic = kKernelStateRegisterMagic,
  }) =>
      KernelStateRegister.pack(
        writerId: writerId,
        generation: payload & _kMask32,
        magic: magic,
      );

  /// Uninitialized register value (`0x0000000000000000`) returned by `notifyd`
  /// before any writer or cold-start seeder calls `notify_set_state`.
  static const KernelStateRegister zero = KernelStateRegister(0);

  /// Extracts the 16-bit magic header from bits `63..48`.
  int get magic => (rawBits >>> 48) & _kMask16;

  /// Whether bits `63..48` match [kKernelStateRegisterMagic] (`0xEB42`).
  bool get hasValidMagic => magic == kKernelStateRegisterMagic;

  /// Whether this register is uninitialized (`0`) or lacks a valid magic
  /// header, requiring cold-start seeding from the APFS snapshot.
  bool get isUnseeded => rawBits == 0 || !hasValidMagic;

  /// Extracts the 16-bit logical writer identifier from bits `47..32`.
  int get writerId => (rawBits >>> 32) & _kMask16;

  /// Extracts the unsigned 32-bit generation counter (or unsigned signal
  /// payload) from bits `31..0`.
  int get generation => rawBits & _kMask32;

  /// Extracts bits `31..0` as a two's-complement signed 32-bit integer for
  /// `@DarwinSignal` payloads that may be negative.
  int get signedPayload32 => generation.toSigned(32);

  /// Returns `true` if this register was written by [localWriterId].
  bool isFromWriter(int localWriterId) =>
      hasValidMagic && writerId == (localWriterId & _kMask16);

  /// Determines whether a `<notify.h>` state wakeup can be dropped in O(1)
  /// without touching the disk.
  ///
  /// A state notification is suppressed if the register has a valid magic
  /// header and **either**:
  /// 1. Its [generation] is already `<= localGeneration` (modulo 32-bit mask)
  ///    known in memory, or
  /// 2. It was emitted by [localWriterId] and its [generation] matches the
  ///    local state.
  bool shouldSuppressStateWakeup({
    required int localWriterId,
    required int localGeneration,
  }) {
    if (!hasValidMagic) return false;
    final maskedLocalGen = localGeneration & _kMask32;
    if (generation <= maskedLocalGen) {
      return true;
    }
    return false;
  }

  /// Formats the 64-bit register as a fixed-width 16-digit hexadecimal literal
  /// (e.g., `'0xeb42483c0000002a'`).
  String toHexString() {
    final high = ((rawBits >>> 32) & _kMask32).toRadixString(16).padLeft(8, '0');
    final low = (rawBits & _kMask32).toRadixString(16).padLeft(8, '0');
    return '0x$high$low';
  }
}

/// Auto-incrementing per-isolate counter used to ensure two bridge instances
/// inside the same OS process never share a 16-bit logical writer ID.
int _nextInstanceSalt = 1;

/// Generates a non-zero 16-bit logical writer ID (`1..0xFFFF`) by mixing the
/// OS process ID ([pid]) with a per-instance [instanceNonce].
///
/// Mixing an instance nonce with `getpid()` guarantees that even when iOS 17+
/// executes an `AppIntent.perform()` inside the host `Runner` process on a
/// background Swift thread, the Swift writer and Dart listener have distinct
/// 16-bit writer IDs.
int deriveLogicalWriterId({
  required int pid,
  int? instanceNonce,
}) {
  final salt = instanceNonce ?? (_nextInstanceSalt++ ^ math.Random().nextInt(1 << 16));
  var hash = ((pid & _kMask32) * 0x9E3779B1) ^ ((salt & _kMask32) * 0x85EBCA6B);
  hash ^= hash >>> 16;
  hash = (hash * 0x7FEB352D) & _kMask32;
  hash ^= hash >>> 15;
  final id16 = hash & _kMask16;
  return id16 == 0 ? 1 : id16;
}
