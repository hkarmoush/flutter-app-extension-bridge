import Foundation

/// Default maximum lifetime (`2,000,000` microseconds = `2,000` ms) of a live
/// `.cas` symlink lease before contenders treat the lease as stale.
///
/// Note: If the holder process was terminated via `SIGKILL` or Jetsam OOM,
/// contenders detect `kill(pid, 0) == ESRCH` and evict the lease immediately
/// (< 1 ms) without waiting for this ceiling.
public let kDefaultCasLeaseCeilingMicros: Int64 = 2_000_000

/// Value representation of a zero-FD atomic symlink lease target stored at
/// `state/.<key>.v<version>.cas`.
///
/// ### Wire Format
/// ```text
/// <pid>:<acquiredAtMicros>:<nonce>
/// ```
/// Example: `"48219:1729785600123456:9b1deb4d-3b7d-4bad-9bdd-2b0d7b3dcb6d"`
///
/// Using an atomic POSIX `symlink(2)` containing the holder's PID, timestamp,
/// and unique nonce avoids holding any open file descriptor or kernel file
/// lock (`flock`/`fcntl`), making the critical section `0xdead10cc`-proof and
/// enabling instant dead-process detection via `kill(pid, 0) == ESRCH`.
public struct CasLeaseToken: Sendable, Equatable, Hashable, CustomStringConvertible {
    /// OS process ID (`getpid()`) of the writer holding the `.cas` symlink lease.
    public let pid: Int32

    /// UTC epoch timestamp in microseconds when the lease was created.
    public let acquiredAtMicros: Int64

    /// Unique per-attempt token used to verify lease ownership via `readlink(2)`
    /// before committing `rename(2)` or `unlink(2)`.
    public let nonce: String

    /// Creates a ``CasLeaseToken``.
    public init(pid: Int32, acquiredAtMicros: Int64, nonce: String) {
        precondition(pid > 0, "pid must be positive")
        precondition(acquiredAtMicros >= 0, "acquiredAtMicros must be non-negative")
        precondition(!nonce.isEmpty, "nonce must not be empty")
        self.pid = pid
        self.acquiredAtMicros = acquiredAtMicros
        self.nonce = nonce
    }

    /// Encodes this lease token into the `<pid>:<acquiredAtMicros>:<nonce>`
    /// symlink target string.
    public func encode() -> String {
        "\(pid):\(acquiredAtMicros):\(nonce)"
    }

    /// Returns `true` if the lease age (`nowMicros - acquiredAtMicros`) exceeds
    /// `ceilingMicros`.
    public func isExpired(
        nowMicros: Int64,
        ceilingMicros: Int64 = kDefaultCasLeaseCeilingMicros
    ) -> Bool {
        nowMicros - acquiredAtMicros > ceilingMicros
    }

    /// Attempts to parse a ``CasLeaseToken`` from a `readlink(2)` target string,
    /// returning `nil` if malformed.
    public static func tryParse(_ rawTarget: String) -> CasLeaseToken? {
        guard let firstColon = rawTarget.firstIndex(of: ":") else { return nil }
        guard firstColon > rawTarget.startIndex else { return nil }

        let afterFirst = rawTarget.index(after: firstColon)
        guard afterFirst < rawTarget.endIndex,
              let secondColon = rawTarget[afterFirst...].firstIndex(of: ":")
        else {
            return nil
        }
        guard secondColon > afterFirst else { return nil }

        let afterSecond = rawTarget.index(after: secondColon)
        guard afterSecond < rawTarget.endIndex else { return nil }

        let pidStr = rawTarget[..<firstColon]
        let tsStr = rawTarget[afterFirst..<secondColon]
        let nonce = String(rawTarget[afterSecond...])

        guard let pid = Int32(pidStr, radix: 10),
              pid > 0,
              let ts = Int64(tsStr, radix: 10),
              ts >= 0,
              !nonce.isEmpty
        else {
            return nil
        }

        return CasLeaseToken(pid: pid, acquiredAtMicros: ts, nonce: nonce)
    }

    /// Parses a ``CasLeaseToken`` from `rawTarget`, throwing
    /// ``ExtensionBridgeError/corruptEnvelope(key:message:)`` if malformed.
    public static func parse(_ rawTarget: String) throws -> CasLeaseToken {
        guard let token = tryParse(rawTarget) else {
            throw ExtensionBridgeError.corruptEnvelope(
                key: nil,
                message: "Invalid .cas symlink lease target: \"\(rawTarget)\""
            )
        }
        return token
    }

    public var description: String {
        "CasLeaseToken(\(encode()))"
    }
}
