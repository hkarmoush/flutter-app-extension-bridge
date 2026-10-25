import 'package:meta/meta.dart';

/// Maximum 16-bit logical counter value (`0xFFFF` = `65535`) within a single
/// Hybrid Logical Clock microsecond tick.
const int kMaxHlcCounter = 0xFFFF;

/// {@template extension_bridge.hlc_timestamp}
/// Immutable Hybrid Logical Clock (HLC) timestamp combining a physical UTC
/// microsecond epoch ([wallTimeMicros]) with a 16-bit monotonic
/// [logicalCounter] and 16-bit [writerId].
///
/// Maildir queue envelopes in `queue/<name>/ready/` are named using
/// [toQueueFileName] (`<17-digit-micros>_<4-hex-counter>_<uuid>.json`) so
/// standard lexicographical sorting yields strict causal and chronological
/// order without parsing JSON contents.
/// {@endtemplate}
@immutable
final class HlcTimestamp implements Comparable<HlcTimestamp> {
  /// {@macro extension_bridge.hlc_timestamp}
  const HlcTimestamp({
    required this.wallTimeMicros,
    required this.logicalCounter,
    this.writerId = 0,
  })  : assert(wallTimeMicros >= 0, 'wallTimeMicros must be non-negative'),
        assert(
          logicalCounter >= 0 && logicalCounter <= kMaxHlcCounter,
          'logicalCounter must fit in 16 bits (0..0xFFFF)',
        ),
        assert(
          writerId >= 0 && writerId <= 0xFFFF,
          'writerId must fit in 16 bits (0..0xFFFF)',
        );

  /// Monotonic UTC epoch timestamp in microseconds.
  final int wallTimeMicros;

  /// 16-bit logical tie-breaker counter (`0..0xFFFF`) incremented when
  /// multiple events occur within the same physical microsecond or during a
  /// backward wall-clock jump.
  final int logicalCounter;

  /// Optional 16-bit logical writer identifier (`0..0xFFFF`).
  final int writerId;

  /// Encodes this timestamp as a fixed-width, lexicographically sortable
  /// 22-character prefix: `<17-digit-wallTimeMicros>_<4-digit-hex-counter>`.
  ///
  /// Example: `'00001729800000123_0001'`.
  String toSortablePrefix() {
    final microsPart = wallTimeMicros.toString().padLeft(17, '0');
    final counterPart = logicalCounter.toRadixString(16).padLeft(4, '0');
    return '${microsPart}_$counterPart';
  }

  /// Formats a Maildir queue envelope filename ordered by this HLC timestamp.
  ///
  /// Example: `'00001729800000123_0001_9b1deb4d-3b7d.json'`.
  String toQueueFileName(String itemUuid) =>
      '${toSortablePrefix()}_$itemUuid.json';

  /// Parses an [HlcTimestamp] from a [toSortablePrefix], [toQueueFileName], or
  /// full file path string, returning `null` if the basename does not begin
  /// with a valid `<17-digit-micros>_<4-hex-counter>` header.
  static HlcTimestamp? tryParse(String prefixOrFileName) {
    final lastSlash = prefixOrFileName.lastIndexOf('/');
    final lastBackslash = prefixOrFileName.lastIndexOf(r'\');
    final sepIndex = lastSlash > lastBackslash ? lastSlash : lastBackslash;
    final target = sepIndex >= 0
        ? prefixOrFileName.substring(sepIndex + 1)
        : prefixOrFileName;

    if (target.length < 22) return null;
    if (target.codeUnitAt(17) != 0x5F /* '_' */) return null;
    if (target.length > 22 &&
        target.codeUnitAt(22) != 0x5F /* '_' */ &&
        target.codeUnitAt(22) != 0x2E /* '.' */) {
      return null;
    }

    final microsStr = target.substring(0, 17);
    final counterStr = target.substring(18, 22);

    final micros = int.tryParse(microsStr, radix: 10);
    final counter = int.tryParse(counterStr, radix: 16);
    if (micros == null || micros < 0 || counter == null || counter < 0) {
      return null;
    }
    return HlcTimestamp(
      wallTimeMicros: micros,
      logicalCounter: counter,
    );
  }

  /// Parses an [HlcTimestamp] from [prefixOrFileName], throwing a
  /// [FormatException] if malformed.
  static HlcTimestamp parse(String prefixOrFileName) {
    final parsed = tryParse(prefixOrFileName);
    if (parsed == null) {
      throw FormatException(
        'Invalid HLC timestamp prefix or queue filename',
        prefixOrFileName,
      );
    }
    return parsed;
  }

  @override
  int compareTo(HlcTimestamp other) {
    final wallCmp = wallTimeMicros.compareTo(other.wallTimeMicros);
    if (wallCmp != 0) return wallCmp;
    final counterCmp = logicalCounter.compareTo(other.logicalCounter);
    if (counterCmp != 0) return counterCmp;
    return writerId.compareTo(other.writerId);
  }

  /// Returns `true` if this timestamp is strictly earlier than [other].
  bool operator <(HlcTimestamp other) => compareTo(other) < 0;

  /// Returns `true` if this timestamp is earlier than or equal to [other].
  bool operator <=(HlcTimestamp other) => compareTo(other) <= 0;

  /// Returns `true` if this timestamp is strictly later than [other].
  bool operator >(HlcTimestamp other) => compareTo(other) > 0;

  /// Returns `true` if this timestamp is later than or equal to [other].
  bool operator >=(HlcTimestamp other) => compareTo(other) >= 0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is HlcTimestamp &&
          other.wallTimeMicros == wallTimeMicros &&
          other.logicalCounter == logicalCounter &&
          other.writerId == writerId;

  @override
  int get hashCode => Object.hash(wallTimeMicros, logicalCounter, writerId);

  @override
  String toString() =>
      'HlcTimestamp(${toSortablePrefix()}, writerId: $writerId)';
}

/// {@template extension_bridge.hybrid_logical_clock}
/// Monotonic Hybrid Logical Clock (HLC) generator resilient to NTP wall-clock
/// backward drift and sub-microsecond bursts.
///
/// Guarantees that every call to [now] or [receive] yields a strictly
/// increasing [HlcTimestamp] (`t_next > t_prev`), even if the system wall
/// clock jumps backward or freezes.
/// {@endtemplate}
final class HybridLogicalClock {
  /// Creates a [HybridLogicalClock] tagged with [writerId] and an optional
  /// [wallClockMicros] source (defaults to [DateTime.now]).
  HybridLogicalClock({
    this.writerId = 0,
    int Function()? wallClockMicros,
  })  : assert(
          writerId >= 0 && writerId <= 0xFFFF,
          'writerId must fit in 16 bits (0..0xFFFF)',
        ),
        _wallClockMicros =
            wallClockMicros ?? (() => DateTime.now().microsecondsSinceEpoch);

  /// 16-bit logical writer ID embedded into emitted [HlcTimestamp] instances.
  final int writerId;

  final int Function() _wallClockMicros;

  int _lastWallTimeMicros = 0;
  int _counter = -1;

  /// The most recently emitted [HlcTimestamp], or `null` if no timestamp has
  /// been generated yet.
  HlcTimestamp? get lastTimestamp => _counter < 0
      ? null
      : HlcTimestamp(
          wallTimeMicros: _lastWallTimeMicros,
          logicalCounter: _counter,
          writerId: writerId,
        );

  /// Generates a new strictly monotonic [HlcTimestamp] for a local event.
  HlcTimestamp now() {
    final physicalMicros = _wallClockMicros();
    if (physicalMicros > _lastWallTimeMicros) {
      _lastWallTimeMicros = physicalMicros;
      _counter = 0;
    } else {
      _counter += 1;
      if (_counter > kMaxHlcCounter) {
        // Counter saturated within a single physical microsecond; advance the
        // logical wall time by 1 us to preserve strict monotonicity.
        _lastWallTimeMicros += 1;
        _counter = 0;
      }
    }
    return HlcTimestamp(
      wallTimeMicros: _lastWallTimeMicros,
      logicalCounter: _counter,
      writerId: writerId,
    );
  }

  /// Advances the local clock after observing a [remote] timestamp from
  /// another process, preserving causal happens-before ordering.
  HlcTimestamp receive(HlcTimestamp remote) {
    final physicalMicros = _wallClockMicros();
    if (physicalMicros > _lastWallTimeMicros &&
        physicalMicros > remote.wallTimeMicros) {
      _lastWallTimeMicros = physicalMicros;
      _counter = 0;
    } else if (_lastWallTimeMicros == remote.wallTimeMicros) {
      _counter = (_counter > remote.logicalCounter
              ? _counter
              : remote.logicalCounter) +
          1;
      if (_counter > kMaxHlcCounter) {
        _lastWallTimeMicros += 1;
        _counter = 0;
      }
    } else if (_lastWallTimeMicros > remote.wallTimeMicros) {
      _counter += 1;
      if (_counter > kMaxHlcCounter) {
        _lastWallTimeMicros += 1;
        _counter = 0;
      }
    } else {
      _lastWallTimeMicros = remote.wallTimeMicros;
      _counter = remote.logicalCounter + 1;
      if (_counter > kMaxHlcCounter) {
        _lastWallTimeMicros += 1;
        _counter = 0;
      }
    }
    return HlcTimestamp(
      wallTimeMicros: _lastWallTimeMicros,
      logicalCounter: _counter,
      writerId: writerId,
    );
  }
}
