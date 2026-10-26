import Foundation

/// Default number of historical `@SharedState` generations whose attachment
/// blobs are retained on disk before lazy garbage collection (`currentGen - 2`).
///
/// Retaining `currentGen - 1` and `currentGen - 2` guarantees that a concurrent
/// reader that opened a snapshot just before a new `rename(2)` commit can still
/// read its referenced attachment blobs without racing deletion.
public let kDefaultStateBlobRetentionGenerations: Int64 = 2

/// Result of staging a model's `@SharedAttachment` files into
/// `<AppGroup>/extension_bridge/blobs/`.
public struct StagedAttachments<T: Sendable>: Sendable {
    /// Copy of the model where `@SharedAttachment` fields have been rewritten
    /// to container-relative `blobs/...` paths for JSON serialization.
    public let stagedValue: T

    /// List of container-relative `blobs/...` paths created during this staging
    /// pass.
    public let relativeBlobPaths: [String]

    /// Creates a ``StagedAttachments`` result.
    public init(stagedValue: T, relativeBlobPaths: [String]) {
        self.stagedValue = stagedValue
        self.relativeBlobPaths = relativeBlobPaths
    }
}

/// Callback that stages any `@SharedAttachment` file paths on `value` for a
/// `@SharedState` write at `generation`.
public typealias StateAttachmentStager<T: Sendable> = @Sendable (
    _ value: T,
    _ generation: Int64,
    _ manager: SharedAttachmentManager
) throws -> StagedAttachments<T>

/// Callback that stages any `@SharedAttachment` file paths on `value` for a
/// `@SharedQueue` enqueue with `itemUuid`.
public typealias QueueAttachmentStager<T: Sendable> = @Sendable (
    _ value: T,
    _ itemUuid: String,
    _ manager: SharedAttachmentManager
) throws -> StagedAttachments<T>

/// Callback that resolves container-relative `blobs/...` paths on `value` back
/// to absolute filesystem paths inside the current process's App Group mount.
public typealias AttachmentPathResolver<T: Sendable> = @Sendable (
    _ value: T,
    _ manager: SharedAttachmentManager
) -> T

/// Manages zero-copy APFS `clonefile(2)` staging, path resolution, and
/// generation-bounded garbage collection for `@SharedAttachment` blobs inside
/// `<AppGroupContainer>/extension_bridge/blobs/`.
public final class SharedAttachmentManager: @unchecked Sendable {
    /// Container directory layout.
    public let layout: ContainerLayout

    private let cloner: ApfsFileCloner
    private let posix: DarwinPosix
    private let lock = NSLock()
    private var nonceCounter: UInt16 = 0

    private var _clonedBlobCount: Int = 0
    private var _streamFallbackBlobCount: Int = 0
    private var _garbageCollectedBlobCount: Int = 0

    /// Creates a ``SharedAttachmentManager``.
    public init(
        layout: ContainerLayout,
        fileCloner: ApfsFileCloner? = nil,
        posix: DarwinPosix = .shared
    ) {
        self.layout = layout
        self.posix = posix
        self.cloner = fileCloner ?? ApfsFileCloner(posix: posix)
    }

    /// Total number of blobs materialized via zero-copy APFS `clonefile(2)`.
    public var clonedBlobCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _clonedBlobCount
    }

    /// Total number of blobs materialized via the chunked streaming fallback.
    public var streamFallbackBlobCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _streamFallbackBlobCount
    }

    /// Total number of stale or acknowledged blobs unlinked from `blobs/`.
    public var garbageCollectedBlobCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _garbageCollectedBlobCount
    }

    /// Stages a single `@SharedState` attachment file from `sourcePath` into
    /// `blobs/state_<stateKey>_gen_<generation>_<nonce>_<name>` and returns its
    /// container-relative path (`blobs/...`).
    public func stageStateAttachment(
        sourcePath: String,
        stateKey: String,
        generation: Int64,
        copyMode: AttachmentCopyMode = .cloneOrStream
    ) throws -> String {
        let resolvedSource = layout.resolveBlobPath(sourcePath)
        let originalName = URL(fileURLWithPath: resolvedSource).lastPathComponent
        let relativeDst = layout.stateBlobRelativePath(
            stateKey: stateKey,
            generation: generation,
            nonce: nextShortNonce(),
            originalFileName: originalName
        )
        let absoluteDst = layout.resolveBlobPath(relativeDst)

        let result = try cloner.cloneFile(
            from: resolvedSource,
            to: absoluteDst,
            copyMode: copyMode
        )
        lock.lock()
        if result.strategy == .apfsClonefile {
            _clonedBlobCount += 1
        } else {
            _streamFallbackBlobCount += 1
        }
        lock.unlock()
        return relativeDst
    }

    /// Stages a single `@SharedQueue` attachment file from `sourcePath` into
    /// `blobs/queue_<itemUuid>_<attachmentIndex>_<name>` and returns its
    /// container-relative path (`blobs/...`).
    public func stageQueueAttachment(
        sourcePath: String,
        itemUuid: String,
        attachmentIndex: Int,
        copyMode: AttachmentCopyMode = .cloneOrStream
    ) throws -> String {
        let resolvedSource = layout.resolveBlobPath(sourcePath)
        let originalName = URL(fileURLWithPath: resolvedSource).lastPathComponent
        let relativeDst = layout.queueBlobRelativePath(
            itemUuid: itemUuid,
            attachmentIndex: attachmentIndex,
            originalFileName: originalName
        )
        let absoluteDst = layout.resolveBlobPath(relativeDst)

        let result = try cloner.cloneFile(
            from: resolvedSource,
            to: absoluteDst,
            copyMode: copyMode
        )
        lock.lock()
        if result.strategy == .apfsClonefile {
            _clonedBlobCount += 1
        } else {
            _streamFallbackBlobCount += 1
        }
        lock.unlock()
        return relativeDst
    }

    /// Resolves a container-relative blob path (`blobs/...`) to an absolute
    /// path inside the App Group container.
    public func resolveAttachmentPath(_ relativeOrAbsolutePath: String) -> String {
        layout.resolveBlobPath(relativeOrAbsolutePath)
    }

    /// Unlinks the given `relativeOrAbsolutePaths` from `blobs/`.
    @discardableResult
    public func unlinkBlobs<S: Sequence>(_ relativeOrAbsolutePaths: S) -> Int where S.Element == String {
        var removed = 0
        for rawPath in relativeOrAbsolutePaths {
            let absPath = layout.resolveBlobPath(rawPath)
            if posix.unlinkFile(absPath) == 0 {
                removed += 1
            }
        }
        if removed > 0 {
            lock.lock()
            _garbageCollectedBlobCount += removed
            lock.unlock()
        }
        return removed
    }

    /// Garbage-collects `@SharedState` blobs belonging to `stateKey` whose
    /// generation is strictly older than
    /// `currentGeneration - retentionGenerations` (`< currentGen - 2`), as well
    /// as any leftover `.tmp.` staging artifacts inside `blobs/`.
    @discardableResult
    public func gcStaleStateBlobs(
        stateKey: String,
        currentGeneration: Int64,
        retentionGenerations: Int64 = kDefaultStateBlobRetentionGenerations
    ) -> Int {
        let blobsDir = layout.blobsDirectoryPath
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: blobsDir) else {
            return 0
        }

        let minRetainedGen = currentGeneration - retentionGenerations
        let prefix = "state_\(stateKey)_gen_"
        var removed = 0

        for name in names {
            let fullPath = "\(blobsDir)/\(name)"
            if name.hasPrefix(".") && name.contains(".tmp.") {
                if posix.unlinkFile(fullPath) == 0 {
                    removed += 1
                }
                continue
            }

            guard name.hasPrefix(prefix) else { continue }
            let rest = name.dropFirst(prefix.count)
            guard let underscoreIdx = rest.firstIndex(of: "_"),
                  underscoreIdx > rest.startIndex
            else {
                continue
            }
            let genStr = rest[..<underscoreIdx]
            guard let blobGen = Int64(genStr, radix: 10) else { continue }

            if blobGen < minRetainedGen {
                if posix.unlinkFile(fullPath) == 0 {
                    removed += 1
                }
            }
        }

        if removed > 0 {
            lock.lock()
            _garbageCollectedBlobCount += removed
            lock.unlock()
        }
        return removed
    }

    private func nextShortNonce() -> String {
        lock.lock()
        nonceCounter &+= 1
        let seq = nonceCounter
        lock.unlock()
        let rand = UInt32.random(in: 0...0xFF_FFFF)
        return String(format: "%x%06x", seq, rand)
    }
}
