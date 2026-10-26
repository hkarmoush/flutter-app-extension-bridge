import Foundation

/// Maximum 16-bit logical counter value (`0xFFFF` = `65535`) within a single
/// Hybrid Logical Clock microsecond tick.
public let kMaxHlcCounter: UInt16 = 0xFFFF

/// Immutable Hybrid Logical Clock (HLC) timestamp combining a physical UTC
/// microsecond epoch (``wallTimeMicros``) with a 16-bit monotonic
/// ``logicalCounter`` and 16-bit ``writerId``.
///
/// Maildir queue envelopes in `queue/<name>/ready/` are named using
/// ``toQueueFileName(_:)`` (`<17-digit-micros>_<4-hex-counter>_<uuid>.json`) so
/// standard lexicographical sorting yields strict causal and chronological
/// order without parsing JSON contents.
public struct HlcTimestamp: Sendable, Equatable, Hashable, Comparable, CustomStringConvertible {
    /// Monotonic UTC epoch timestamp in microseconds.
    public let wallTimeMicros: Int64

    /// 16-bit logical tie-breaker counter (`0..0xFFFF`) incremented when
    /// multiple events occur within the same physical microsecond or during a
    /// backward wall-clock jump.
    public let logicalCounter: UInt16

    /// Optional 16-bit logical writer identifier (`0..0xFFFF`).
    public let writerId: UInt16

    /// Creates an ``HlcTimestamp``.
    public init(
        wallTimeMicros: Int64,
        logicalCounter: UInt16,
        writerId: UInt16 = 0
    ) {
        precondition(wallTimeMicros >= 0, "wallTimeMicros must be non-negative")
        self.wallTimeMicros = wallTimeMicros
        self.logicalCounter = logicalCounter
        self.writerId = writerId
    }

    /// Encodes this timestamp as a fixed-width, lexicographically sortable
    /// 22-character prefix: `<17-digit-wallTimeMicros>_<4-digit-hex-counter>`.
    ///
    /// Example: `"00001729800000123_0001"`.
    public func toSortablePrefix() -> String {
        String(format: "%017lld_%04x", wallTimeMicros, logicalCounter)
    }

    /// Formats a Maildir queue envelope filename ordered by this HLC timestamp.
    ///
    /// Example: `"00001729800000123_0001_9b1deb4d-3b7d.json"`.
    public func toQueueFileName(_ itemUuid: String) -> String {
        "\(toSortablePrefix())_\(itemUuid).json"
    }

    /// Attempts to parse an ``HlcTimestamp`` from a sortable prefix, queue
    /// filename, or full file path string, returning `nil` if the basename does
    /// not begin with a valid `<17-digit-micros>_<4-hex-counter>` header.
    public static func tryParse(_ prefixOrFileName: String) -> HlcTimestamp? {
        let base: Substring
        if let lastSlash = prefixOrFileName.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
            base = prefixOrFileName[prefixOrFileName.index(after: lastSlash)...]
        } else {
            base = prefixOrFileName[...]
        }

        let utf8 = Array(base.utf8)
        guard utf8.count >= 22 else { return nil }
        guard utf8[17] == 0x5F /* '_' */ else { return nil }
        if utf8.count > 22 {
            let delimiter = utf8[22]
            guard delimiter == 0x5F /* '_' */ || delimiter == 0x2E /* '.' */ else {
                return nil
            }
        }

        // Verify all 17 chars of micros are ASCII digits and 4 chars of counter are hex digits.
        for i in 0..<17 {
            let b = utf8[i]
            guard b >= 0x30 && b <= 0x39 else { return nil }
        }
        for i in 18..<22 {
            let b = utf8[i]
            let isDigit = b >= 0x30 && b <= 0x39
            let isLowerHex = b >= 0x61 && b <= 0x66
            let isUpperHex = b >= 0x41 && b <= 0x46
            guard isDigit || isLowerHex || isUpperHex else { return nil }
        }

        let microsStr = String(decoding: utf8[0..<17], as: UTF8.self)
        let counterStr = String(decoding: utf8[18..<22], as: UTF8.self)

        guard let micros = Int64(microsStr, radix: 10),
              micros >= 0,
              let counter = UInt16(counterStr, radix: 16)
        else {
            return nil
        }

        return HlcTimestamp(wallTimeMicros: micros, logicalCounter: counter)
    }

    /// Parses an ``HlcTimestamp`` from `prefixOrFileName`, throwing
    /// ``ExtensionBridgeError/corruptEnvelope(key:message:)`` if malformed.
    public static func parse(_ prefixOrFileName: String) throws -> HlcTimestamp {
        guard let parsed = tryParse(prefixOrFileName) else {
            throw ExtensionBridgeError.corruptEnvelope(
                key: nil,
                message: "Invalid HLC timestamp prefix or queue filename: \"\(prefixOrFileName)\""
            )
        }
        return parsed
    }

    public static func < (lhs: HlcTimestamp, rhs: HlcTimestamp) -> Bool {
        if lhs.wallTimeMicros != rhs.wallTimeMicros {
            return lhs.wallTimeMicros < rhs.wallTimeMicros
        }
        if lhs.logicalCounter != rhs.logicalCounter {
            return lhs.logicalCounter < rhs.logicalCounter
        }
        return lhs.writerId < rhs.writerId
    }

    public var description: String {
        "HlcTimestamp(\(toSortablePrefix()), writerId: \(writerId))"
    }
}

/// Thread-safe, `Sendable` monotonic Hybrid Logical Clock (HLC) generator
/// resilient to NTP wall-clock backward drift and sub-microsecond bursts.
///
/// Guarantees that every call to ``now()`` or ``receive(_:)`` yields a strictly
/// increasing ``HlcTimestamp`` (`t_next > t_prev`), even if the system wall
/// clock jumps backward or freezes.
public final class HybridLogicalClock: @unchecked Sendable {
    /// 16-bit logical writer ID embedded into emitted ``HlcTimestamp`` instances.
    public let writerId: UInt16

    private let wallClockMicros: @Sendable () -> Int64
    private let lock = NSLock()
    private var lastWallTimeMicros: Int64 = 0
    private var counter: Int32 = -1

    /// Creates a ``HybridLogicalClock`` tagged with `writerId` and an optional
    /// `wallClockMicros` source.
    public init(
        writerId: UInt16 = 0,
        wallClockMicros: (@Sendable () -> Int64)? = nil
    ) {
        self.writerId = writerId
        self.wallClockMicros = wallClockMicros ?? {
            Int64(Date().timeIntervalSince1970 * 1_000_000.0)
        }
    }

    /// The most recently emitted ``HlcTimestamp``, or `nil` if no timestamp has
    /// been generated yet.
    public var lastTimestamp: HlcTimestamp? {
        lock.lock()
        defer { lock.unlock() }
        guard counter >= 0 else { return nil }
        return HlcTimestamp(
            wallTimeMicros: lastWallTimeMicros,
            logicalCounter: UInt16(counter),
            writerId: writerId
        )
    }

    /// Generates a new strictly monotonic ``HlcTimestamp`` for a local event.
    public func now() -> HlcTimestamp {
        lock.lock()
        defer { lock.unlock() }

        let physicalMicros = wallClockMicros()
        if physicalMicros > lastWallTimeMicros {
            lastWallTimeMicros = physicalMicros
            counter = 0
        } else {
            counter += 1
            if counter > Int32(kMaxHlcCounter) {
                lastWallTimeMicros += 1
                counter = 0
            }
        }
        return HlcTimestamp(
            wallTimeMicros: lastWallTimeMicros,
            logicalCounter: UInt16(counter),
            writerId: writerId
        )
    }

    /// Advances the local clock after observing a `remote` timestamp from
    /// another process, preserving causal happens-before ordering.
    @discardableResult
    public func receive(_ remote: HlcTimestamp) -> HlcTimestamp {
        lock.lock()
        defer { lock.unlock() }

        let physicalMicros = wallClockMicros()
        let remoteCounter = Int32(remote.logicalCounter)

        if physicalMicros > lastWallTimeMicros && physicalMicros > remote.wallTimeMicros {
            lastWallTimeMicros = physicalMicros
            counter = 0
        } else if lastWallTimeMicros == remote.wallTimeMicros {
            counter = max(counter, remoteCounter) + 1
            if counter > Int32(kMaxHlcCounter) {
                lastWallTimeMicros += 1
                counter = 0
            }
        } else if lastWallTimeMicros > remote.wallTimeMicros {
            counter += 1
            if counter > Int32(kMaxHlcCounter) {
                lastWallTimeMicros += 1
                counter = 0
            }
        } else {
            lastWallTimeMicros = remote.wallTimeMicros
            counter = remoteCounter + 1
            if counter > Int32(kMaxHlcCounter) {
                lastWallTimeMicros += 1
                counter = 0
            }
        }
        return HlcTimestamp(
            wallTimeMicros: lastWallTimeMicros,
            logicalCounter: UInt16(counter),
            writerId: writerId
        )
    }
}
