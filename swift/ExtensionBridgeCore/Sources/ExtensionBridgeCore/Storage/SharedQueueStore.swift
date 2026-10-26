import Darwin
import Foundation

/// Metadata receipt returned by ``SharedQueueStore/enqueue(_:)`` when an item
/// is atomically committed to `queue/<key>/ready/`.
public struct QueueEnqueuedReceipt<T: Sendable>: Sendable {
    /// HLC-ordered Maildir filename (`<17-digit-micros>_<4-hex-counter>_<itemId>.json`).
    public let fileName: String

    /// Unique item identifier (`<pid>_<seq>_<nonce>`).
    public let itemId: String

    /// Monotonic ``HlcTimestamp`` assigned to this queue entry.
    public let timestamp: HlcTimestamp

    /// Committed ``StateEnvelope`` written to `ready/`.
    public let envelope: StateEnvelope<T>

    /// Creates a ``QueueEnqueuedReceipt``.
    public init(
        fileName: String,
        itemId: String,
        timestamp: HlcTimestamp,
        envelope: StateEnvelope<T>
    ) {
        self.fileName = fileName
        self.itemId = itemId
        self.timestamp = timestamp
        self.envelope = envelope
    }
}

/// Transactional handle for an item claimed from `queue/<key>/ready/` into
/// `queue/<key>/inflight/`.
///
/// The envelope file in `inflight/` and any associated `@SharedAttachment`
/// files in `blobs/` remain on disk until ``ack()`` is called. If the consumer
/// process crashes or terminates before calling ``ack()``, the next
/// ``SharedQueueStore`` startup automatically recovers the item from
/// `inflight/` back into `ready/` with ``isRedelivery`` set to `true`.
public final class QueueDelivery<T: Sendable>: @unchecked Sendable {
    /// HLC-ordered Maildir filename (`<17-digit-micros>_<4-hex-counter>_<itemId>.json`).
    public let fileName: String

    /// Unique identifier for this queue item.
    public let itemId: String

    /// Hybrid Logical Clock timestamp parsed from ``fileName``.
    public let timestamp: HlcTimestamp

    /// Decoded wire envelope from `inflight/<fileName>`.
    public let envelope: StateEnvelope<T>

    /// Decoded payload model with `@SharedAttachment` paths resolved to
    /// absolute filesystem paths inside the App Group container.
    public let value: T

    /// Whether this item was recovered from `inflight/` after a prior
    /// unacknowledged consumer session.
    public let isRedelivery: Bool

    private let onAck: @Sendable () -> Void
    private let onNack: @Sendable (_ requeue: Bool) -> Void
    private let lock = NSLock()
    private var settled = false

    internal init(
        fileName: String,
        itemId: String,
        timestamp: HlcTimestamp,
        envelope: StateEnvelope<T>,
        value: T,
        isRedelivery: Bool,
        onAck: @escaping @Sendable () -> Void,
        onNack: @escaping @Sendable (_ requeue: Bool) -> Void
    ) {
        self.fileName = fileName
        self.itemId = itemId
        self.timestamp = timestamp
        self.envelope = envelope
        self.value = value
        self.isRedelivery = isRedelivery
        self.onAck = onAck
        self.onNack = onNack
    }

    /// Whether ``ack()`` or ``nack(requeue:)`` has already been called on this
    /// delivery.
    public var isSettled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return settled
    }

    /// Acknowledges successful processing of ``value``, unlinking
    /// `inflight/<fileName>` and deleting all associated `@SharedAttachment`
    /// files in `blobs/`.
    public func ack() {
        lock.lock()
        if settled {
            lock.unlock()
            return
        }
        settled = true
        lock.unlock()
        onAck()
    }

    /// Negatively acknowledges this delivery.
    ///
    /// - When `requeue` is `true` (default), atomically moves
    ///   `inflight/<fileName>` back to `ready/<fileName>` (preserving its HLC
    ///   position and keeping its attachment blobs intact).
    /// - When `requeue` is `false`, discards the item and unlinks its
    ///   attachment blobs.
    public func nack(requeue: Bool = true) {
        lock.lock()
        if settled {
            lock.unlock()
            return
        }
        settled = true
        lock.unlock()
        onNack(requeue)
    }
}

/// Lock-free, multi-producer Maildir queue (`tmp/` → `ready/` → `inflight/`)
/// ordered by a Hybrid Logical Clock (``HybridLogicalClock``) with zero-copy
/// APFS `clonefile(2)` attachments.
///
/// ### Why a Maildir Queue Instead of a JSON Array?
/// iOS Share Extensions and Interactive Widgets operate under a strict
/// **16–30 MB Jetsam RAM ceiling**. Appending to a shared JSON array in
/// `UserDefaults` or a single file causes both write contention and
/// `EXC_RESOURCE (MEMORY)` crashes as the queue grows.
///
/// With ``SharedQueueStore``:
/// 1. Each producer writes an independent `<hlc_ts>_<uuid>.json` file into
///    `tmp/` and atomically `rename(2)`s it into `ready/` with **zero locks**
///    and **O(1) memory**.
/// 2. Media attachments are cloned into `blobs/` via
///    `clonefile(src, dst, CLONE_NOOWNERCOPY)` (~0.3 ms, 0 extra disk bytes).
/// 3. The consumer claims items by atomically `rename(2)`ing them from `ready/`
///    to `inflight/`, and only unlinks the envelope + blobs when
///    ``QueueDelivery/ack()`` is invoked.
public final class SharedQueueStore<T: Sendable>: @unchecked Sendable {
    /// Logical queue directory key (`queue/<queueKey>/`).
    public let queueKey: String

    /// On-disk container layout.
    public let layout: ContainerLayout

    /// Envelope JSON codec for item type `T`.
    public let codec: StateEnvelopeCodec<T>

    /// Darwin `<notify.h>` notification center.
    public let notifyCenter: DarwinNotifyCenter

    /// Full `<notify.h>` notification channel name for this queue.
    public let notificationName: String

    /// Schema version integer (`_schema_version`).
    public let schemaVersion: Int

    /// Maximum number of pending items retained in `ready/` before oldest-item
    /// eviction applies.
    public let maxItems: Int

    /// Optional callback that stages `@SharedAttachment` fields on `T` before
    /// enqueueing.
    public let stageAttachments: QueueAttachmentStager<T>?

    /// Optional callback that resolves container-relative `blobs/...` paths on
    /// `T` when claiming a delivery.
    public let resolveAttachments: AttachmentPathResolver<T>?

    /// Maximum age in microseconds before an uncommitted file in `tmp/` from a
    /// live PID is treated as orphaned.
    public let staleTmpCeilingMicros: Int64

    /// Attachment manager used by this queue.
    public let attachmentManager: SharedAttachmentManager

    /// Hybrid Logical Clock used to order items in this queue.
    public let clock: HybridLogicalClock

    private let posix: DarwinPosix
    private let pid: Int32
    private let lock = NSLock()
    private var enqueueSeq: Int64 = 0
    private var wakeupGeneration: Int64 = 0
    private var hasRunStartupRecovery = false
    private var recoveredFileNames: Set<String> = []

    private var _enqueuedCount: Int = 0
    private var _acknowledgedCount: Int = 0
    private var _recoveredInflightCount: Int = 0
    private var _evictedBackpressureCount: Int = 0

    /// Creates a ``SharedQueueStore``.
    public init(
        queueKey: String,
        layout: ContainerLayout,
        codec: StateEnvelopeCodec<T>,
        notifyCenter: DarwinNotifyCenter,
        notificationName: String,
        schemaVersion: Int = 1,
        maxItems: Int = 256,
        attachmentManager: SharedAttachmentManager? = nil,
        clock: HybridLogicalClock? = nil,
        posix: DarwinPosix = .shared,
        stageAttachments: QueueAttachmentStager<T>? = nil,
        resolveAttachments: AttachmentPathResolver<T>? = nil,
        staleTmpCeilingMicros: Int64 = kDefaultCasLeaseCeilingMicros
    ) {
        precondition(schemaVersion >= 1, "schemaVersion must be >= 1")
        precondition(maxItems >= 1, "maxItems must be >= 1")
        self.queueKey = queueKey
        self.layout = layout
        self.codec = codec
        self.notifyCenter = notifyCenter
        self.notificationName = notificationName
        self.schemaVersion = schemaVersion
        self.maxItems = maxItems
        self.attachmentManager = attachmentManager ?? SharedAttachmentManager(layout: layout, posix: posix)
        self.clock = clock ?? HybridLogicalClock(writerId: notifyCenter.writerId)
        self.posix = posix
        self.stageAttachments = stageAttachments
        self.resolveAttachments = resolveAttachments
        self.staleTmpCeilingMicros = staleTmpCeilingMicros
        self.pid = posix.currentPid()
    }

    /// Total number of items enqueued through this store instance.
    public var enqueuedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _enqueuedCount
    }

    /// Total number of deliveries acknowledged via ``QueueDelivery/ack()``.
    public var acknowledgedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _acknowledgedCount
    }

    /// Total number of unacknowledged items recovered from `inflight/` back into
    /// `ready/`.
    public var recoveredInflightCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _recoveredInflightCount
    }

    /// Total number of oldest `ready/` items evicted due to ``maxItems``
    /// backpressure.
    public var evictedBackpressureCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _evictedBackpressureCount
    }

    /// Path to `queue/<queueKey>/tmp`.
    public var tmpDirectoryPath: String {
        layout.queueTmpDirectoryPath(queueKey)
    }

    /// Path to `queue/<queueKey>/ready`.
    public var readyDirectoryPath: String {
        layout.queueReadyDirectoryPath(queueKey)
    }

    /// Path to `queue/<queueKey>/inflight`.
    public var inflightDirectoryPath: String {
        layout.queueInflightDirectoryPath(queueKey)
    }

    /// Returns the number of committed items currently waiting in `ready/`.
    public func pendingReadyCount() -> Int {
        listSortedJsonFileNames(in: readyDirectoryPath).count
    }

    /// Returns the number of items currently claimed in `inflight/`.
    public func inflightCount() -> Int {
        listSortedJsonFileNames(in: inflightDirectoryPath).count
    }

    /// Synchronously enqueues `item` into `queue/<queueKey>/ready/` using a
    /// monotonic ``HlcTimestamp``, staging any `@SharedAttachment` blobs via
    /// APFS `clonefile(2)` and broadcasting a `<notify.h>` wakeup.
    @discardableResult
    public func enqueue(_ item: T) throws -> QueueEnqueuedReceipt<T> {
        try ExtensionActivityGuard.performProtectedActivity(
            reason: "ExtensionBridge SharedQueueStore(\(queueKey)).enqueue"
        ) {
            try layout.ensureQueueDirectories(for: queueKey)

            let ts = clock.now()
            lock.lock()
            enqueueSeq += 1
            let seq = enqueueSeq
            lock.unlock()

            let rand = String(UInt32.random(in: 0...0x7FFF_FFFF), radix: 16)
            let itemId = "\(pid)_\(seq)_\(rand)"
            let fileName = ts.toQueueFileName(itemId)

            let payloadToEncode: T
            let stagedBlobPaths: [String]
            if let stager = stageAttachments {
                let staged = try stager(item, itemId, attachmentManager)
                payloadToEncode = staged.stagedValue
                stagedBlobPaths = staged.relativeBlobPaths
            } else {
                payloadToEncode = item
                stagedBlobPaths = []
            }

            let envelope = StateEnvelope<T>(
                schemaVersion: schemaVersion,
                generation: seq,
                updatedAtMicros: ts.wallTimeMicros,
                writerId: notifyCenter.writerId,
                payload: payloadToEncode,
                attachments: stagedBlobPaths
            )

            let tmpPath = "\(tmpDirectoryPath)/\(fileName)"
            let readyPath = "\(readyDirectoryPath)/\(fileName)"

            let encodedData = try codec.encodeToData(envelope)
            try posix.writeAndFlushFile(atPath: tmpPath, data: encodedData)

            enforceMaxItemsBackpressure()

            let renameErr = posix.renameFile(from: tmpPath, to: readyPath)
            if renameErr != 0 {
                _ = posix.unlinkFile(tmpPath)
                _ = attachmentManager.unlinkBlobs(stagedBlobPaths)
                throw ExtensionBridgeError.storageIo(
                    path: readyPath,
                    errno: renameErr,
                    message: "Atomic rename(2) from tmp/ to ready/ failed for queue \"\(queueKey)\" (errno: \(renameErr))"
                )
            }

            let wakeupGen = nextWakeupGeneration()
            lock.lock()
            _enqueuedCount += 1
            lock.unlock()

            _ = try notifyCenter.publishState(notificationName, generation: wakeupGen)

            return QueueEnqueuedReceipt(
                fileName: fileName,
                itemId: itemId,
                timestamp: ts,
                envelope: envelope
            )
        }
    }

    /// Recovers any unacknowledged items left in `queue/<key>/inflight/` from a
    /// prior crashed or terminated consumer session back into `ready/`
    /// (preserving their original HLC filenames and causal order), and sweeps
    /// orphaned staging files in `tmp/`.
    @discardableResult
    public func recoverInflightItems() throws -> Int {
        try layout.ensureQueueDirectories(for: queueKey)
        lock.lock()
        hasRunStartupRecovery = true
        lock.unlock()

        let inflightNames = listSortedJsonFileNames(in: inflightDirectoryPath)
        var recovered = 0

        for fileName in inflightNames {
            let srcPath = "\(inflightDirectoryPath)/\(fileName)"
            let dstPath = "\(readyDirectoryPath)/\(fileName)"
            if posix.renameFile(from: srcPath, to: dstPath) == 0 {
                lock.lock()
                recoveredFileNames.insert(fileName)
                _recoveredInflightCount += 1
                lock.unlock()
                recovered += 1
            }
        }

        sweepOrphanedTmpFiles()
        return recovered
    }

    /// Atomically claims the oldest available item in `ready/`, moving it to
    /// `inflight/` and returning its ``QueueDelivery`` handle (or `nil` if
    /// `ready/` is empty).
    public func claimNextDelivery() throws -> QueueDelivery<T>? {
        lock.lock()
        let needsRecovery = !hasRunStartupRecovery
        lock.unlock()

        if needsRecovery {
            _ = try recoverInflightItems()
        } else {
            try layout.ensureQueueDirectories(for: queueKey)
        }

        let readyNames = listSortedJsonFileNames(in: readyDirectoryPath)
        for fileName in readyNames {
            let readyPath = "\(readyDirectoryPath)/\(fileName)"
            let inflightPath = "\(inflightDirectoryPath)/\(fileName)"

            let renameErr = posix.renameFile(from: readyPath, to: inflightPath)
            if renameErr != 0 {
                continue
            }

            let envelope: StateEnvelope<T>
            do {
                guard let data = try posix.readFileData(atPath: inflightPath) else {
                    continue
                }
                envelope = try codec.decodeFromData(data)
            } catch {
                _ = posix.unlinkFile(inflightPath)
                throw error
            }

            let ts = HlcTimestamp.tryParse(fileName) ?? HlcTimestamp(
                wallTimeMicros: envelope.updatedAtMicros,
                logicalCounter: 0,
                writerId: envelope.writerId
            )
            clock.receive(ts)

            let resolvedValue = resolvePayload(envelope.payload)
            let itemId = Self.extractItemId(fileName)

            lock.lock()
            let wasRecovered = recoveredFileNames.remove(fileName) != nil
            lock.unlock()

            return QueueDelivery<T>(
                fileName: fileName,
                itemId: itemId,
                timestamp: ts,
                envelope: envelope,
                value: resolvedValue,
                isRedelivery: wasRecovered,
                onAck: { [weak self] in
                    guard let self = self else { return }
                    _ = self.posix.unlinkFile(inflightPath)
                    _ = self.attachmentManager.unlinkBlobs(envelope.attachments)
                    self.lock.lock()
                    self._acknowledgedCount += 1
                    self.lock.unlock()
                },
                onNack: { [weak self] requeue in
                    guard let self = self else { return }
                    if requeue {
                        let targetReadyPath = "\(self.readyDirectoryPath)/\(fileName)"
                        self.lock.lock()
                        self.recoveredFileNames.insert(fileName)
                        self.lock.unlock()
                        _ = self.posix.renameFile(from: inflightPath, to: targetReadyPath)
                    } else {
                        _ = self.posix.unlinkFile(inflightPath)
                        _ = self.attachmentManager.unlinkBlobs(envelope.attachments)
                    }
                }
            )
        }

        return nil
    }

    /// Claims all currently available items in `ready/` in strict HLC causal
    /// order, moving each to `inflight/`.
    public func drainAvailable() throws -> [QueueDelivery<T>] {
        var deliveries: [QueueDelivery<T>] = []
        while let next = try claimNextDelivery() {
            deliveries.append(next)
        }
        return deliveries
    }

    /// Returns a Swift 6 `AsyncStream` of ``QueueDelivery`` items in strict HLC
    /// causal order.
    public func consume() -> AsyncStream<QueueDelivery<T>> {
        AsyncStream { continuation in
            let drainAvailableToStream: @Sendable () -> Void = { [weak self] in
                guard let self = self else { return }
                while let delivery = try? self.claimNextDelivery() {
                    continuation.yield(delivery)
                }
            }

            guard let sub = try? self.notifyCenter.onStateChange(self.notificationName, handler: { _ in
                drainAvailableToStream()
            }) else {
                continuation.finish()
                return
            }

            drainAvailableToStream()

            continuation.onTermination = { _ in
                sub.cancel()
            }
        }
    }

    // MARK: - Internal Helpers

    private func enforceMaxItemsBackpressure() {
        let readyNames = listSortedJsonFileNames(in: readyDirectoryPath)
        guard readyNames.count >= maxItems else { return }

        let toEvictCount = readyNames.count - maxItems + 1
        for i in 0..<toEvictCount {
            let victimName = readyNames[i]
            let victimPath = "\(readyDirectoryPath)/\(victimName)"
            if let data = try? posix.readFileData(atPath: victimPath),
               let header = try? StateEnvelopeHeader.fromData(data, key: queueKey)
            {
                if posix.unlinkFile(victimPath) == 0 {
                    _ = attachmentManager.unlinkBlobs(header.attachments)
                    lock.lock()
                    _evictedBackpressureCount += 1
                    lock.unlock()
                }
            } else if posix.unlinkFile(victimPath) == 0 {
                lock.lock()
                _evictedBackpressureCount += 1
                lock.unlock()
            }
        }
    }

    private func sweepOrphanedTmpFiles() {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: tmpDirectoryPath) else {
            return
        }
        let nowMicros = Int64(Date().timeIntervalSince1970 * 1_000_000.0)
        for fileName in names {
            let fullPath = "\(tmpDirectoryPath)/\(fileName)"
            let ts = HlcTimestamp.tryParse(fileName)
            let itemId = Self.extractItemId(fileName)
            let holderPid: Int32?
            if let underscore = itemId.firstIndex(of: "_"), underscore > itemId.startIndex {
                holderPid = Int32(itemId[..<underscore], radix: 10)
            } else {
                holderPid = nil
            }

            let isDeadPid = holderPid == nil || !posix.isProcessAlive(holderPid!)
            let isExpired = ts == nil || (nowMicros - ts!.wallTimeMicros > staleTmpCeilingMicros)

            if isDeadPid || isExpired {
                _ = posix.unlinkFile(fullPath)
            }
        }
    }

    private func listSortedJsonFileNames(in dirPath: String) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dirPath) else {
            return []
        }
        return names.filter { $0.hasSuffix(".json") }.sorted()
    }

    private func resolvePayload(_ rawPayload: T) -> T {
        guard let resolver = resolveAttachments else { return rawPayload }
        return resolver(rawPayload, attachmentManager)
    }

    private func nextWakeupGeneration() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        if let reg = try? notifyCenter.getRegister(notificationName),
           reg.hasValidMagic,
           Int64(reg.generation) > wakeupGeneration
        {
            wakeupGeneration = Int64(reg.generation)
        }
        wakeupGeneration = (wakeupGeneration + 1) & 0xFFFF_FFFF
        if wakeupGeneration == 0 {
            wakeupGeneration = 1
        }
        return wakeupGeneration
    }

    private static func extractItemId(_ fileName: String) -> String {
        let withoutExt = fileName.hasSuffix(".json")
            ? String(fileName.dropLast(5))
            : fileName
        let utf8 = Array(withoutExt.utf8)
        if utf8.count > 23 && utf8[22] == 0x5F /* '_' */ {
            return String(decoding: utf8[23...], as: UTF8.self)
        }
        return withoutExt
    }
}

/// Type alias matching the `SharedQueueWriter` terminology used in App
/// Extensions (`UIShareExtension`, `AppIntent`, `TimelineProvider`).
public typealias SharedQueueWriter<T: Sendable> = SharedQueueStore<T>
