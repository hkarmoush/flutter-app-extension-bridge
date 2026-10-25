import 'package:meta/meta.dart';

/// Default maximum lifetime (`2,000,000` microseconds = `2,000` ms) of a live
/// `.cas` symlink lease before contenders treat the lease as stale.
///
/// Note: If the holder process was terminated via `SIGKILL` or Jetsam OOM,
/// contenders detect `kill(pid, 0) == ESRCH` and evict the lease immediately
/// (< 1 ms) without waiting for this ceiling.
const int kDefaultCasLeaseCeilingMicros = 2000000;

/// {@template extension_bridge.cas_lease_token}
/// Value representation of a zero-FD atomic symlink lease target stored at
/// `state/.<key>.v<version>.cas`.
///
/// ### Wire Format
/// ```text
/// <pid>:<acquiredAtMicros>:<nonce>
/// ```
/// Example: `'48219:1729785600123456:9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d'`
///
/// Using an atomic POSIX `symlink(2)` containing the holder's PID, timestamp,
/// and unique nonce avoids holding any open file descriptor or kernel file
/// lock (`flock`/`fcntl`), making the critical section `0xdead10cc`-proof and
/// enabling instant dead-process detection via `kill(pid, 0) == ESRCH`.
/// {@endtemplate}
@immutable
final class CasLeaseToken {
  /// {@macro extension_bridge.cas_lease_token}
  const CasLeaseToken({
    required this.pid,
    required this.acquiredAtMicros,
    required this.nonce,
  })  : assert(pid > 0, 'pid must be positive'),
        assert(acquiredAtMicros >= 0, 'acquiredAtMicros must be non-negative'),
        assert(nonce != '', 'nonce must not be empty');

  /// OS process ID (`getpid()`) of the writer holding the `.cas` symlink lease.
  final int pid;

  /// UTC epoch timestamp in microseconds when the lease was created.
  final int acquiredAtMicros;

  /// Unique per-attempt token used to verify lease ownership via `readlink(2)`
  /// before committing `rename(2)` or `unlink(2)`.
  final String nonce;

  /// Encodes this lease token into the `<pid>:<acquiredAtMicros>:<nonce>`
  /// symlink target string.
  String encode() => '$pid:$acquiredAtMicros:$nonce';

  /// Returns `true` if the lease age (`nowMicros - acquiredAtMicros`) exceeds
  /// [ceilingMicros].
  bool isExpired({
    required int nowMicros,
    int ceilingMicros = kDefaultCasLeaseCeilingMicros,
  }) =>
      nowMicros - acquiredAtMicros > ceilingMicros;

  /// Attempts to parse a [CasLeaseToken] from a `readlink(2)` target string,
  /// returning `null` if malformed.
  static CasLeaseToken? tryParse(String rawTarget) {
    final firstColon = rawTarget.indexOf(':');
    if (firstColon <= 0) return null;
    final secondColon = rawTarget.indexOf(':', firstColon + 1);
    if (secondColon <= firstColon + 1 || secondColon >= rawTarget.length - 1) {
      return null;
    }

    final pid = int.tryParse(rawTarget.substring(0, firstColon), radix: 10);
    final ts = int.tryParse(
      rawTarget.substring(firstColon + 1, secondColon),
      radix: 10,
    );
    final nonce = rawTarget.substring(secondColon + 1);

    if (pid == null || pid <= 0 || ts == null || ts < 0 || nonce.isEmpty) {
      return null;
    }
    return CasLeaseToken(
      pid: pid,
      acquiredAtMicros: ts,
      nonce: nonce,
    );
  }

  /// Parses a [CasLeaseToken] from [rawTarget], throwing a [FormatException]
  /// if malformed.
  static CasLeaseToken parse(String rawTarget) {
    final token = tryParse(rawTarget);
    if (token == null) {
      throw FormatException('Invalid .cas symlink lease target', rawTarget);
    }
    return token;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CasLeaseToken &&
          other.pid == pid &&
          other.acquiredAtMicros == acquiredAtMicros &&
          other.nonce == nonce;

  @override
  int get hashCode => Object.hash(pid, acquiredAtMicros, nonce);

  @override
  String toString() => 'CasLeaseToken(${encode()})';
}
