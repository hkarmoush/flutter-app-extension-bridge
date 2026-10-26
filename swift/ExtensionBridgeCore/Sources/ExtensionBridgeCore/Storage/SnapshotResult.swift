import Foundation

/// Exhaustive result of reading a `@SharedState` snapshot from
/// ``AtomicStateStore``.
public enum SnapshotResult<T: Sendable>: Sendable {
    /// A valid snapshot exists on disk (or in the in-memory fast-path cache).
    case hit(value: T, envelope: StateEnvelope<T>, fromMemoryCache: Bool)

    /// No snapshot has been written for this state key yet.
    case empty

    /// Returns the decoded payload value if ``hit(value:envelope:fromMemoryCache:)``,
    /// or `nil` if ``empty``.
    @inlinable
    public var valueOrNil: T? {
        switch self {
        case let .hit(value, _, _):
            return value
        case .empty:
            return nil
        }
    }

    /// Returns the ``StateEnvelope`` if ``hit(value:envelope:fromMemoryCache:)``,
    /// or `nil` if ``empty``.
    @inlinable
    public var envelopeOrNil: StateEnvelope<T>? {
        switch self {
        case let .hit(_, envelope, _):
            return envelope
        case .empty:
            return nil
        }
    }

    /// Whether the result was served from memory via the `~299 ns`
    /// `notify_check` fast path without reading APFS.
    @inlinable
    public var isFromMemoryCache: Bool {
        switch self {
        case let .hit(_, _, fromMemoryCache):
            return fromMemoryCache
        case .empty:
            return false
        }
    }
}

extension SnapshotResult: Equatable where T: Equatable {}
