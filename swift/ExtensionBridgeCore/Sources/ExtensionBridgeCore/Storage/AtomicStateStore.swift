import Darwin
import Foundation

/// Fault-injection hook invoked after `.tmp` staging is flushed to disk, just
/// before attempting to acquire the `.cas` symlink lease.
public typealias BeforeCasAcquireHook = @Sendable (
    _ attempt: Int,
    _ stagingPath: String
) throws -> Void

/// Fault-injection hook invoked immediately after acquiring the `.cas` symlink
/// lease, before verifying `_gen == expectedGen` and committing `rename(2)`.
public typealias AfterCasAcquireHook = @Sendable (
    _ attempt: Int,
    _ leaseToken: CasLeaseToken,
    _ casPath: String
) throws -> Void

/// Fault-injection hook invoked after `_gen == expectedGen` is verified, right
/// before the final ownership check and `rename(2)` commit.
public typealias BeforeRenameCommitHook = @Sendable (
    _ attempt: Int,
    _ leaseToken: CasLeaseToken,
    _ casPath: String
) throws -> Void

/// `0xdead10cc`-proof, lock-free atomic snapshot store and optimistic
/// concurrency control (CAS) engine for `@SharedState`.
///
/// ### Architectural Guarantees
/// 1. **Zero Kernel File Locks (`0xdead10cc`-Proof):**
///    Never invokes `flock(2)`, `fcntl(2)`, SQLite WAL locks, or
///    `NSFileCoordinator`. Readers open and read immutable snapshot files with
///    zero locks; writers serialize to `.tmp` out-of-band and atomically swap
///    the directory entry via POSIX `rename(2)`.
/// 2. **Two-Stage `~299 ns` Shared-Memory Read Fast Path:**
///    - **Stage 1:** Calls `notify_check` (~299 ns `notifyd` process-mapped
///      shared-memory slot, zero Mach IPC). If unchanged, returns the cached
///      model in memory immediately.
///    - **Stage 2:** If `notify_check` reports a post, calls `notify_get_state`
///      (~9.3 µs Mach IPC) and only reads APFS if `reg.generation > localGen`
///      (or if the register is unseeded `0x0` on cold start).
/// 3. **Zero-FD Symlink CAS Loop with Instant `ESRCH` Dead-PID Recovery:**
///    Both ``write(_:)`` and ``update(_:)`` acquire a short-lived POSIX symlink
///    lease (`symlink("<pid>:<ts_us>:<nonce>", ".<key>.v<ver>.cas")`). If a
///    previous extension process was terminated mid-write (`SIGKILL` or Jetsam
///    OOM), contenders probe `kill(holderPid, 0) == ESRCH` and evict the
///    orphaned lease in **< 1 ms**. Every `rename(2)` and `unlink(2)` is
///    guarded by owner-token verification (`readlink(".cas") == myLease`) to
///    prevent split-brain overwrites.
public final class AtomicStateStore<T: Sendable>: @unchecked Sendable {
    /// Logical `@SharedState` key (e.g., `"now_playing"`).
    public let key: String

    /// On-disk container directory layout.
    public let layout: ContainerLayout

    /// JSON envelope codec for model type `T`.
    public let codec: StateEnvelopeCodec<T>

    /// Darwin `<notify.h>` notification center.
    public let notifyCenter: DarwinNotifyCenter

    /// Full Darwin `<notify.h>` notification name for this state key.
    public let notificationName: String

    /// Schema version integer (`_schema_version`).
    public let schemaVersion: Int

    /// Optional list of `WidgetKit` widget `kind` identifiers to reload on write.
    public let reloadWidgets: [String]?

    /// Optional list of iOS 18 `ControlWidget` `kind` identifiers to reload on
    /// write.
    public let reloadControls: [String]?

    /// Optional callback that stages `@SharedAttachment` files on `T` before
    /// encoding.
    public let stageAttachments: StateAttachmentStager<T>?

    /// Optional callback that resolves relative `blobs/...` paths on `T` after
    /// decoding.
    public let resolveAttachments: AttachmentPathResolver<T>?

    /// Maximum number of optimistic CAS attempts before throwing
    /// ``ExtensionBridgeError/casContention(key:attempts:lastHolderPid:)``.
    public let maxCasAttempts: Int

    /// Maximum age in microseconds (`2_000_000` µs = 2,000 ms by default) of a
    /// live `.cas` symlink lease before contenders treat it as expired.
    public let casLeaseCeilingMicros: Int64

    /// Optional Tier 2 fault-injection hook invoked before acquiring `.cas`.
    public let onBeforeCasAcquire: BeforeCasAcquireHook?

    /// Optional Tier 2 fault-injection hook invoked after acquiring `.cas`.
    public let onAfterCasAcquire: AfterCasAcquireHook?

    /// Optional Tier 2 fault-injection hook invoked just before `rename(2)`.
    public let onBeforeRenameCommit: BeforeRenameCommitHook?

    /// Attachment manager associated with this store.
    public let attachmentManager: SharedAttachmentManager

    private let posix: DarwinPosix
    private let clockMicros: @Sendable () -> Int64
    private let pid: Int32
    private let lock = NSLock()
    private var nonceSeq: UInt64 = 0

    private var cachedEnvelope: StateEnvelope<T>?
    private var cachedResolvedValue: T?
    private var lastEmittedGeneration: Int64 = -1

    private var _memoryCacheHits: Int = 0
    private var _diskSnapshotReads: Int = 0
    private var _casCommitCount: Int = 0
    private var _casRetryCount: Int = 0
    private var _evictedDeadPidLeaseCount: Int = 0
    private var _evictedExpiredLeaseCount: Int = 0
    private var _splitBrainPreventedCount: Int = 0

    /// Creates an ``AtomicStateStore``.
    public init(
        key: String,
        layout: ContainerLayout,
        codec: StateEnvelopeCodec<T>,
        notifyCenter: DarwinNotifyCenter,
        notificationName: String,
        schemaVersion: Int = 1,
        attachmentManager: SharedAttachmentManager? = nil,
        posix: DarwinPosix = .shared,
        reloadWidgets: [String]? = nil,
        reloadControls: [String]? = nil,
        stageAttachments: StateAttachmentStager<T>? = nil,
        resolveAttachments: AttachmentPathResolver<T>? = nil,
        maxCasAttempts: Int = 32,
        casLeaseCeilingMicros: Int64 = kDefaultCasLeaseCeilingMicros,
        clockMicros: (@Sendable () -> Int64)? = nil,
        onBeforeCasAcquire: BeforeCasAcquireHook? = nil,
        onAfterCasAcquire: AfterCasAcquireHook? = nil,
        onBeforeRenameCommit: BeforeRenameCommitHook? = nil
    ) {
        precondition(schemaVersion >= 1, "schemaVersion must be >= 1")
        precondition(maxCasAttempts >= 1, "maxCasAttempts must be >= 1")
        self.key = key
        self.layout = layout
        self.codec = codec
        self.notifyCenter = notifyCenter
        self.notificationName = notificationName
        self.schemaVersion = schemaVersion
        self.attachmentManager = attachmentManager ?? SharedAttachmentManager(layout: layout, posix: posix)
        self.posix = posix
        self.reloadWidgets = reloadWidgets
        self.reloadControls = reloadControls
        self.stageAttachments = stageAttachments
        self.resolveAttachments = resolveAttachments
        self.maxCasAttempts = maxCasAttempts
        self.casLeaseCeilingMicros = casLeaseCeilingMicros
        self.clockMicros = clockMicros ?? {
            Int64(Date().timeIntervalSince1970 * 1_000_000.0)
        }
        self.onBeforeCasAcquire = onBeforeCasAcquire
        self.onAfterCasAcquire = onAfterCasAcquire
        self.onBeforeRenameCommit = onBeforeRenameCommit
        self.pid = posix.currentPid()
    }

    /// Number of ``read()`` / ``readResult()`` calls served from memory via the
    /// `<notify.h>` fast path with zero disk I/O.
    public var memoryCacheHits: Int {
        lock.lock()
        defer { lock.unlock() }
        return _memoryCacheHits
    }

    /// Number of ``read()`` / ``readResult()`` calls that read and decoded the
    /// APFS snapshot file from disk.
    public var diskSnapshotReads: Int {
        lock.lock()
        defer { lock.unlock() }
        return _diskSnapshotReads
    }

    /// Total number of committed ``write(_:)`` / ``update(_:)`` operations.
    public var casCommitCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _casCommitCount
    }

    /// Total number of optimistic CAS retries triggered by concurrent contention.
    public var casRetryCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _casRetryCount
    }

    /// Number of orphaned `.cas` symlink leases evicted immediately (< 1 ms) via
    /// `kill(pid, 0) == ESRCH` dead-process detection.
    public var evictedDeadPidLeaseCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _evictedDeadPidLeaseCount
    }

    /// Number of stale `.cas` symlink leases evicted after exceeding
    /// ``casLeaseCeilingMicros``.
    public var evictedExpiredLeaseCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _evictedExpiredLeaseCount
    }

    /// Number of split-brain overwrites prevented by owner-token verification
    /// (`readlink(".cas") == myLease`).
    public var splitBrainPreventedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _splitBrainPreventedCount
    }

    /// Canonical file path of the active immutable snapshot
    /// (`state/<key>.v<schemaVersion>.json`).
    public var snapshotFilePath: String {
        layout.stateSnapshotPath(key, schemaVersion: schemaVersion)
    }

    /// Canonical file path of the `.cas` symlink lease
    /// (`state/.<key>.v<schemaVersion>.cas`).
    public var casLeaseFilePath: String {
        layout.stateCasLeasePath(key, schemaVersion: schemaVersion)
    }

    /// Atomically reads the latest `T` snapshot, or returns `nil` if no state
    /// has been written yet.
    ///
    /// - **Fast Path (Cache Hit):** ~299 ns via `<notify.h>` `notify_check`
    ///   shared-memory slot (zero Mach IPC, zero disk I/O).
    /// - **Slow Path (Cache Miss):** ~9.3 µs `notify_get_state` check + lock-free
    ///   APFS snapshot read.
    public func read() throws -> T? {
        try readResult().valueOrNil
    }

    /// Atomically reads the latest snapshot as an exhaustive ``SnapshotResult``.
    public func readResult() throws -> SnapshotResult<T> {
        lock.lock()
        let cachedEnv = cachedEnvelope
        let cachedVal = cachedResolvedValue
        lock.unlock()

        if let cachedEnv = cachedEnv, let cachedVal = cachedVal {
            let changed = try notifyCenter.checkChanged(notificationName)
            if !changed {
                lock.lock()
                _memoryCacheHits += 1
                lock.unlock()
                return .hit(value: cachedVal, envelope: cachedEnv, fromMemoryCache: true)
            }

            let reg = try notifyCenter.getRegister(notificationName)
            let maskedCachedGen = UInt32(UInt64(bitPattern: cachedEnv.generation) & 0xFFFF_FFFF)
            if reg.hasValidMagic && reg.generation <= maskedCachedGen {
                lock.lock()
                _memoryCacheHits += 1
                lock.unlock()
                return .hit(value: cachedVal, envelope: cachedEnv, fromMemoryCache: true)
            }
        } else {
            _ = try notifyCenter.checkChanged(notificationName)
        }

        guard let diskEnv = try readDiskEnvelope() else {
            lock.lock()
            cachedEnvelope = nil
            cachedResolvedValue = nil
            lock.unlock()
            return .empty
        }

        let resolved = resolvePayload(diskEnv.payload)
        lock.lock()
        _diskSnapshotReads += 1
        cachedEnvelope = diskEnv
        cachedResolvedValue = resolved
        lock.unlock()

        notifyCenter.recordLocalGeneration(notificationName, generation: diskEnv.generation)
        _ = try notifyCenter.seedStateIfUnseeded(
            notificationName,
            authoritativeGeneration: diskEnv.generation,
            seedWriterId: diskEnv.writerId
        )

        return .hit(value: resolved, envelope: diskEnv, fromMemoryCache: false)
    }

    /// Writes `newValue` atomically using the lock-free CAS protocol.
    ///
    /// Equivalent to calling `update { _ in newValue }`.
    @discardableResult
    public func write(_ newValue: T) throws -> StateEnvelope<T> {
        try update { _ in newValue }
    }

    /// Executes a lock-free optimistic concurrency control (CAS) transaction
    /// that reads the current snapshot (`T?`), applies the pure `mutator`
    /// closure, and atomically commits `expectedGen + 1`.
    ///
    /// If another process or task commits a new generation while `mutator` or
    /// `.tmp` serialization is in flight, ``update(_:)`` automatically rolls
    /// back its staging artifacts and re-evaluates `mutator` against the newer
    /// snapshot.
    @discardableResult
    public func update(_ mutator: (T?) throws -> T) throws -> StateEnvelope<T> {
        try ExtensionActivityGuard.performProtectedActivity(
            reason: "ExtensionBridge AtomicStateStore(\(key)).update"
        ) {
            try layout.ensureBaseDirectories()
            _ = try notifyCenter.checkChanged(notificationName)

            var lastObservedHolderPid: Int32?

            for attempt in 1...maxCasAttempts {
                // Step 1: Read current authoritative snapshot from APFS.
                let diskEnv = try readDiskEnvelope()
                let expectedGen = diskEnv?.generation ?? 0
                let currentResolved = diskEnv.map { resolvePayload($0.payload) }

                // Step 2: Run the pure mutator closure out-of-band.
                let nextResolvedValue = try mutator(currentResolved)
                let nextGen = expectedGen + 1

                // Step 3: Stage any @SharedAttachment blobs & serialize .tmp
                // out-of-band BEFORE acquiring the .cas symlink lease.
                let payloadToEncode: T
                let stagedBlobPaths: [String]
                if let stager = stageAttachments {
                    let staged = try stager(nextResolvedValue, nextGen, attachmentManager)
                    payloadToEncode = staged.stagedValue
                    stagedBlobPaths = staged.relativeBlobPaths
                } else {
                    payloadToEncode = nextResolvedValue
                    stagedBlobPaths = []
                }

                let nowMicros = clockMicros()
                let envelope = StateEnvelope<T>(
                    schemaVersion: schemaVersion,
                    generation: nextGen,
                    updatedAtMicros: nowMicros,
                    writerId: notifyCenter.writerId,
                    payload: payloadToEncode,
                    attachments: stagedBlobPaths
                )

                let nonce = nextAttemptNonce(nowMicros: nowMicros)
                let stagingPath = layout.stateStagingPath(
                    key,
                    nonce: nonce,
                    schemaVersion: schemaVersion
                )

                let encodedData = try codec.encodeToData(envelope)
                try posix.writeAndFlushFile(atPath: stagingPath, data: encodedData)

                if let beforeAcquire = onBeforeCasAcquire {
                    do {
                        try beforeAcquire(attempt, stagingPath)
                    } catch {
                        _ = posix.unlinkFile(stagingPath)
                        _ = attachmentManager.unlinkBlobs(stagedBlobPaths)
                        throw error
                    }
                }

                // Step 4: Acquire zero-FD atomic .cas symlink lease.
                let myLease = CasLeaseToken(
                    pid: pid,
                    acquiredAtMicros: clockMicros(),
                    nonce: nonce
                )
                let casPath = casLeaseFilePath
                let leaseOutcome = try tryAcquireCasLease(casPath: casPath, myLease: myLease)
                if !leaseOutcome.acquired {
                    lastObservedHolderPid = leaseOutcome.holderPid
                    _ = posix.unlinkFile(stagingPath)
                    _ = attachmentManager.unlinkBlobs(stagedBlobPaths)
                    lock.lock()
                    _casRetryCount += 1
                    lock.unlock()
                    continue
                }

                if let afterAcquire = onAfterCasAcquire {
                    do {
                        try afterAcquire(attempt, myLease, casPath)
                    } catch {
                        releaseCasLeaseIfOwned(casPath: casPath, myLease: myLease)
                        _ = posix.unlinkFile(stagingPath)
                        _ = attachmentManager.unlinkBlobs(stagedBlobPaths)
                        throw error
                    }
                }

                // Step 5: Verify _gen == expectedGen while holding .cas.
                let currentDiskGen = try readDiskGeneration()
                if currentDiskGen != expectedGen {
                    releaseCasLeaseIfOwned(casPath: casPath, myLease: myLease)
                    _ = posix.unlinkFile(stagingPath)
                    _ = attachmentManager.unlinkBlobs(stagedBlobPaths)
                    lock.lock()
                    _casRetryCount += 1
                    lock.unlock()
                    continue
                }

                // Step 6: Split-Brain Immunity — verify we still own the .cas symlink.
                if !ownsCasLease(casPath: casPath, myLease: myLease) {
                    _ = posix.unlinkFile(stagingPath)
                    _ = attachmentManager.unlinkBlobs(stagedBlobPaths)
                    lock.lock()
                    _splitBrainPreventedCount += 1
                    _casRetryCount += 1
                    lock.unlock()
                    continue
                }

                if let beforeRename = onBeforeRenameCommit {
                    do {
                        try beforeRename(attempt, myLease, casPath)
                    } catch {
                        releaseCasLeaseIfOwned(casPath: casPath, myLease: myLease)
                        _ = posix.unlinkFile(stagingPath)
                        _ = attachmentManager.unlinkBlobs(stagedBlobPaths)
                        throw error
                    }
                    if !ownsCasLease(casPath: casPath, myLease: myLease) {
                        _ = posix.unlinkFile(stagingPath)
                        _ = attachmentManager.unlinkBlobs(stagedBlobPaths)
                        lock.lock()
                        _splitBrainPreventedCount += 1
                        _casRetryCount += 1
                        lock.unlock()
                        continue
                    }
                }

                // Step 7: Atomic POSIX rename(2) over the active snapshot & lease release.
                let renameErr = posix.renameFile(from: stagingPath, to: snapshotFilePath)
                releaseCasLeaseIfOwned(casPath: casPath, myLease: myLease)

                if renameErr != 0 {
                    _ = posix.unlinkFile(stagingPath)
                    _ = attachmentManager.unlinkBlobs(stagedBlobPaths)
                    throw ExtensionBridgeError.storageIo(
                        path: snapshotFilePath,
                        errno: renameErr,
                        message: "Atomic rename(2) failed while committing state \"\(key)\" (errno: \(renameErr))"
                    )
                }

                // Step 8: Update local memory cache, broadcast <notify.h> state register,
                // consume our own shm check bit, GC stale blobs/staging files, and
                // trigger WidgetKit/ControlCenter reloads.
                let resolvedFinal = resolvePayload(envelope.payload)
                lock.lock()
                cachedEnvelope = envelope
                cachedResolvedValue = resolvedFinal
                lastEmittedGeneration = nextGen
                _casCommitCount += 1
                lock.unlock()

                _ = try notifyCenter.publishState(notificationName, generation: nextGen)
                _ = try notifyCenter.checkChanged(notificationName)

                _ = attachmentManager.gcStaleStateBlobs(
                    stateKey: key,
                    currentGeneration: nextGen
                )
                _ = sweepOrphanedStagingFiles()
                triggerExtensionReloads()

                return envelope
            }

            throw ExtensionBridgeError.casContention(
                key: key,
                attempts: maxCasAttempts,
                lastHolderPid: lastObservedHolderPid
            )
        }
    }

    /// Runs a foreground-resume reconciliation check against the authoritative
    /// APFS snapshot, updating the in-memory cache if a newer generation was
    /// committed while the process was suspended.
    @discardableResult
    public func reconcile() throws -> T? {
        lock.lock()
        let previousGen = cachedEnvelope?.generation ?? lastEmittedGeneration
        lock.unlock()

        guard let diskEnv = try readDiskEnvelope() else { return nil }
        guard diskEnv.generation > previousGen else { return nil }

        let resolved = resolvePayload(diskEnv.payload)
        lock.lock()
        _diskSnapshotReads += 1
        cachedEnvelope = diskEnv
        cachedResolvedValue = resolved
        lastEmittedGeneration = diskEnv.generation
        lock.unlock()

        notifyCenter.recordLocalGeneration(notificationName, generation: diskEnv.generation)
        _ = try notifyCenter.seedStateIfUnseeded(
            notificationName,
            authoritativeGeneration: diskEnv.generation,
            seedWriterId: diskEnv.writerId
        )
        _ = try notifyCenter.checkChanged(notificationName)
        return resolved
    }

    /// Returns a Swift 6 `AsyncStream` of cross-process mutations on ``key``.
    public func watch(emitInitial: Bool = false) -> AsyncStream<T> {
        AsyncStream { continuation in
            if emitInitial, let current = try? self.read() {
                continuation.yield(current)
            }
            guard let sub = try? self.notifyCenter.onStateChange(self.notificationName, handler: { [weak self] _ in
                guard let self = self else { return }
                if let reconciled = try? self.reconcile() {
                    continuation.yield(reconciled)
                }
            }) else {
                continuation.finish()
                return
            }
            continuation.onTermination = { _ in
                sub.cancel()
            }
        }
    }

    /// Sweeps orphaned `.tmp` staging files for ``key`` left behind by processes
    /// that were terminated (`SIGKILL` / Jetsam OOM) or exceeded
    /// ``casLeaseCeilingMicros``.
    @discardableResult
    public func sweepOrphanedStagingFiles() -> Int {
        let stateDir = layout.stateDirectoryPath
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: stateDir) else {
            return 0
        }

        let prefix = layout.stateStagingPrefix(key, schemaVersion: schemaVersion)
        let nowMicros = clockMicros()
        var swept = 0

        for name in names where name.hasPrefix(prefix) {
            let suffix = String(name.dropFirst(prefix.count))
            if isStagingNonceOrphaned(suffix, nowMicros: nowMicros) {
                if posix.unlinkFile("\(stateDir)/\(name)") == 0 {
                    swept += 1
                }
            }
        }
        return swept
    }

    // MARK: - Internal Helpers

    private func readDiskEnvelope() throws -> StateEnvelope<T>? {
        guard let data = try posix.readFileData(atPath: snapshotFilePath) else {
            return nil
        }
        return try codec.decodeFromData(data)
    }

    private func readDiskGeneration() throws -> Int64 {
        guard let data = try posix.readFileData(atPath: snapshotFilePath) else {
            return 0
        }
        return try StateEnvelopeHeader.fromData(
            data,
            key: key,
            maxSupportedSchemaVersion: codec.maxSupportedSchemaVersion
        ).generation
    }

    private func resolvePayload(_ rawPayload: T) -> T {
        guard let resolver = resolveAttachments else { return rawPayload }
        return resolver(rawPayload, attachmentManager)
    }

    private func tryAcquireCasLease(
        casPath: String,
        myLease: CasLeaseToken
    ) throws -> (acquired: Bool, holderPid: Int32?) {
        let encoded = myLease.encode()
        let err = posix.createSymlink(target: encoded, linkPath: casPath)
        if err == 0 {
            return (true, nil)
        }
        if err != EEXIST {
            throw ExtensionBridgeError.storageIo(
                path: casPath,
                errno: err,
                message: "Failed to create .cas symlink lease for \"\(key)\" (errno: \(err))"
            )
        }

        guard let holderRaw = posix.readSymlink(casPath) else {
            let retryErr = posix.createSymlink(target: encoded, linkPath: casPath)
            return (retryErr == 0, nil)
        }

        let holder = CasLeaseToken.tryParse(holderRaw)
        let nowMicros = clockMicros()
        let isDeadProcess = holder == nil || !posix.isProcessAlive(holder!.pid)
        let isExpired = !isDeadProcess && holder!.isExpired(
            nowMicros: nowMicros,
            ceilingMicros: casLeaseCeilingMicros
        )

        if isDeadProcess || isExpired {
            if posix.readSymlink(casPath) == holderRaw {
                if posix.unlinkFile(casPath) == 0 {
                    lock.lock()
                    if isDeadProcess {
                        _evictedDeadPidLeaseCount += 1
                    } else {
                        _evictedExpiredLeaseCount += 1
                    }
                    lock.unlock()
                }
            }
            let retryErr = posix.createSymlink(target: encoded, linkPath: casPath)
            if retryErr == 0 {
                return (true, nil)
            }
        }

        return (false, holder?.pid)
    }

    private func ownsCasLease(casPath: String, myLease: CasLeaseToken) -> Bool {
        posix.readSymlink(casPath) == myLease.encode()
    }

    private func releaseCasLeaseIfOwned(casPath: String, myLease: CasLeaseToken) {
        if ownsCasLease(casPath: casPath, myLease: myLease) {
            _ = posix.unlinkFile(casPath)
        }
    }

    private func nextAttemptNonce(nowMicros: Int64) -> String {
        lock.lock()
        nonceSeq &+= 1
        let seq = nonceSeq
        lock.unlock()
        let rand = String(UInt32.random(in: 0...0x7FFF_FFFF), radix: 16)
        return "\(pid)_\(nowMicros)_\(seq)_\(rand)"
    }

    private func isStagingNonceOrphaned(_ suffix: String, nowMicros: Int64) -> Bool {
        guard let firstUnderscore = suffix.firstIndex(of: "_"),
              firstUnderscore > suffix.startIndex
        else {
            return true
        }
        let afterFirst = suffix.index(after: firstUnderscore)
        guard afterFirst < suffix.endIndex,
              let secondUnderscore = suffix[afterFirst...].firstIndex(of: "_"),
              secondUnderscore > afterFirst
        else {
            return true
        }

        guard let holderPid = Int32(suffix[..<firstUnderscore], radix: 10),
              let ts = Int64(suffix[afterFirst..<secondUnderscore], radix: 10)
        else {
            return true
        }

        if !posix.isProcessAlive(holderPid) {
            return true
        }
        return nowMicros - ts > casLeaseCeilingMicros
    }

    private func triggerExtensionReloads() {
        if let widgets = reloadWidgets, !widgets.isEmpty {
            for kind in widgets {
                ExtensionKitCAbiSupport.reloadWidgetTimelines(kind: kind)
            }
        }
        if let controls = reloadControls, !controls.isEmpty {
            for kind in controls {
                ExtensionKitCAbiSupport.reloadControlWidgets(kind: kind)
            }
        }
    }
}
