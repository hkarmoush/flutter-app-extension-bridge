import Darwin
import Dispatch
import Foundation
import notify

/// Event emitted by ``DarwinNotifyCenter/watchState(_:)`` when a remote process
/// (or another in-process bridge instance with a distinct ``writerId``) commits
/// a new `@SharedState` or `@SharedQueue` generation.
public struct DarwinStateWakeupEvent: Sendable, Equatable, Hashable, CustomStringConvertible {
    /// The Darwin notification channel name.
    public let notificationName: String

    /// The 64-bit ``KernelStateRegister`` read from `notifyd` at wakeup time.
    public let register: KernelStateRegister

    /// 16-bit logical writer identifier extracted from ``register``.
    @inlinable
    public var writerId: UInt16 { register.writerId }

    /// 32-bit monotonic generation counter extracted from ``register``.
    @inlinable
    public var generation: UInt32 { register.generation }

    /// Creates a ``DarwinStateWakeupEvent``.
    public init(notificationName: String, register: KernelStateRegister) {
        self.notificationName = notificationName
        self.register = register
    }

    public var description: String {
        "DarwinStateWakeupEvent(name: \(notificationName), register: \(register.toHexString()))"
    }
}

/// Event emitted by ``DarwinNotifyCenter/watchSignal(_:)`` when a
/// `@DarwinSignal` is received from another process or bridge instance.
public struct DarwinSignalEvent: Sendable, Equatable, Hashable, CustomStringConvertible {
    /// The Darwin signal notification name.
    public let signalName: String

    /// 16-bit logical writer ID of the sender.
    public let writerId: UInt16

    /// Signed 32-bit integer payload unpacked from bits `31..0` of ``register``.
    public let payload: Int32

    /// Full 64-bit ``KernelStateRegister`` snapshot read from `notifyd`.
    public let register: KernelStateRegister

    /// Creates a ``DarwinSignalEvent``.
    public init(
        signalName: String,
        writerId: UInt16,
        payload: Int32,
        register: KernelStateRegister
    ) {
        self.signalName = signalName
        self.writerId = writerId
        self.payload = payload
        self.register = register
    }

    public var description: String {
        "DarwinSignalEvent(name: \(signalName), writerId: \(writerId), payload: \(payload), register: \(register.toHexString()))"
    }
}

/// Cancellable subscription handle returned by
/// ``DarwinNotifyCenter/onStateChange(_:handler:)`` and
/// ``DarwinNotifyCenter/onSignal(_:handler:)``.
public final class DarwinNotifySubscription: @unchecked Sendable {
    private let cancelClosure: @Sendable () -> Void
    private let lock = NSLock()
    private var isCanceledFlag = false

    internal init(onCancel: @escaping @Sendable () -> Void) {
        self.cancelClosure = onCancel
    }

    deinit {
        cancel()
    }

    /// Cancels this subscription and releases the underlying `<notify.h>`
    /// dispatch registration if no other listeners remain on the channel.
    public func cancel() {
        lock.lock()
        if isCanceledFlag {
            lock.unlock()
            return
        }
        isCanceledFlag = true
        lock.unlock()
        cancelClosure()
    }
}

/// High-speed cross-process Darwin `<notify.h>` signal bus implementing:
///
/// 1. **Two-Stage Shared-Memory Fast Path (`~299 ns`):**
///    - **Stage 1 (``checkChanged(_:)``):** Reads `notifyd`'s process-mapped
///      shared-memory slot via `notify_check` in ~299 ns with zero Mach IPC.
///    - **Stage 2 (``getRegister(_:)``):** Invokes `notify_get_state` (~9.3 µs
///      Mach IPC) only when `notify_check` reports a mutation or during
///      dispatch wakeups.
/// 2. **O(1) Self-Echo Cancellation:**
///    Tags every state commit and signal with `[0xEB42 | writerId | generation]`
///    in the kernel's 64-bit register before calling `notify_post`. When the
///    sender's own GCD listener wakes up, it sees `isFromWriter(writerId)` /
///    `generation <= localGen` and drops the echo in O(1) with **zero disk I/O**.
/// 3. **Cold-Start `0x0` Register Seeding (``seedStateIfUnseeded(_:authoritativeGeneration:seedWriterId:)``):**
///    Re-hydrates the kernel register from the authoritative APFS `_gen`
///    header if `notifyd` garbage-collected the register while all processes
///    were terminated.
/// 4. **Zero-Disk 32-Bit `@DarwinSignal` RPC (``postSignal(_:payload:)`` / ``watchSignal(_:)``):**
///    Transmits 32-bit command payloads directly inside the `<notify.h>`
///    register in **~19 µs P50** without touching the filesystem.
public final class DarwinNotifyCenter: @unchecked Sendable {
    /// Distinct 16-bit logical writer identifier (`1..0xFFFF`) for this bus
    /// instance.
    public let writerId: UInt16

    private let lock = NSLock()
    private let dispatchQueue: DispatchQueue
    private var checkTokens: [String: Int32] = [:]
    private var dispatchTokens: [String: Int32] = [:]
    private var localGenerations: [String: UInt32] = [:]
    private var stateHandlers: [String: [UUID: @Sendable (DarwinStateWakeupEvent) -> Void]] = [:]
    private var signalHandlers: [String: [UUID: @Sendable (DarwinSignalEvent) -> Void]] = [:]
    private var disposed = false

    private var _shmFastPathHits: Int = 0
    private var _machIpcStateReads: Int = 0
    private var _suppressedEchoCount: Int = 0
    private var _deliveredWakeupCount: Int = 0

    /// Creates a ``DarwinNotifyCenter`` with an optional explicit `writerId`.
    public init(
        writerId: UInt16? = nil,
        qos: DispatchQoS = .userInteractive
    ) {
        let resolvedId = writerId ?? KernelStateRegister.deriveLogicalWriterId()
        self.writerId = resolvedId == 0 ? 1 : resolvedId
        self.dispatchQueue = DispatchQueue(
            label: "dev.extension_bridge.notify.\(self.writerId)",
            qos: qos
        )
    }

    deinit {
        dispose()
    }

    /// Number of times Stage 1 ``checkChanged(_:)`` returned `false` (`check == 0`
    /// in `~299 ns` shared memory without needing Mach IPC or disk I/O).
    public var shmFastPathHits: Int {
        lock.lock()
        defer { lock.unlock() }
        return _shmFastPathHits
    }

    /// Number of times Stage 2 ``getRegister(_:)`` executed `notify_get_state`
    /// Mach IPC.
    public var machIpcStateReads: Int {
        lock.lock()
        defer { lock.unlock() }
        return _machIpcStateReads
    }

    /// Number of self-echo or already-processed wakeups suppressed in O(1) with
    /// zero disk I/O.
    public var suppressedEchoCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _suppressedEchoCount
    }

    /// Number of remote state or signal wakeups delivered to listeners.
    public var deliveredWakeupCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return _deliveredWakeupCount
    }

    /// Returns the last known 32-bit generation recorded locally for
    /// `notificationName`, or `nil` if unknown.
    public func localGeneration(for notificationName: String) -> UInt32? {
        lock.lock()
        defer { lock.unlock() }
        return localGenerations[notificationName]
    }

    /// Updates the locally cached generation for `notificationName` (for
    /// example, after reading a snapshot from APFS).
    public func recordLocalGeneration(_ notificationName: String, generation: Int64) {
        lock.lock()
        defer { lock.unlock() }
        localGenerations[notificationName] = UInt32(UInt64(bitPattern: generation) & 0xFFFF_FFFF)
    }

    /// **Stage 1 (`~299 ns` Shared-Memory Fast Path):** Checks whether any
    /// notification has been posted to `notificationName` since the previous
    /// check on this center.
    ///
    /// Reads `notifyd`'s shared-memory (`shm`) generation slot mapped directly
    /// into the process address space—zero Mach IPC and zero syscalls.
    public func checkChanged(_ notificationName: String) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let token = try ensureCheckTokenLocked(notificationName)
        var check: Int32 = 0
        let status = notify_check(token, &check)
        guard status == UInt32(NOTIFY_STATUS_OK) else {
            throw ExtensionBridgeError.darwinNotificationFailed(
                operation: "notify_check",
                notificationName: notificationName,
                statusCode: status
            )
        }
        let changed = check != 0
        if !changed {
            _shmFastPathHits += 1
        }
        return changed
    }

    /// **Stage 2 (`~9.3 µs` Mach IPC):** Reads the 64-bit ``KernelStateRegister``
    /// stored in `notifyd` for `notificationName`.
    public func getRegister(_ notificationName: String) throws -> KernelStateRegister {
        lock.lock()
        defer { lock.unlock() }

        let token = try ensureCheckTokenLocked(notificationName)
        return try getRegisterLocked(notificationName: notificationName, token: token)
    }

    /// Seeds the 64-bit kernel register for `notificationName` with
    /// `authoritativeGeneration` if and only if the kernel register is currently
    /// uninitialized (`0x0` / `!hasValidMagic`).
    ///
    /// Does **not** call `notify_post`. Returns `true` if the register was
    /// unseeded and has now been seeded.
    @discardableResult
    public func seedStateIfUnseeded(
        _ notificationName: String,
        authoritativeGeneration: Int64,
        seedWriterId: UInt16? = nil
    ) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let token = try ensureCheckTokenLocked(notificationName)
        let current = try getRegisterLocked(notificationName: notificationName, token: token)
        let unsignedGen = UInt64(bitPattern: authoritativeGeneration)
        localGenerations[notificationName] = UInt32(unsignedGen & 0xFFFF_FFFF)

        guard current.isUnseeded else {
            return false
        }

        let seeded = KernelStateRegister.pack(
            writerId: seedWriterId ?? writerId,
            generation: unsignedGen
        )
        let status = notify_set_state(token, seeded.rawBits)
        guard status == UInt32(NOTIFY_STATUS_OK) else {
            throw ExtensionBridgeError.darwinNotificationFailed(
                operation: "notify_set_state",
                notificationName: notificationName,
                statusCode: status
            )
        }
        return true
    }

    /// Publishes a newly committed `generation` for `notificationName` by
    /// writing `[0xEB42 | writerId | generation]` via `notify_set_state` and
    /// broadcasting `notify_post`.
    @discardableResult
    public func publishState(
        _ notificationName: String,
        generation: Int64
    ) throws -> KernelStateRegister {
        lock.lock()
        defer { lock.unlock() }

        let token = try ensureCheckTokenLocked(notificationName)
        let unsignedGen = UInt64(bitPattern: generation) & 0xFFFF_FFFF
        localGenerations[notificationName] = UInt32(unsignedGen)

        let reg = KernelStateRegister.pack(
            writerId: writerId,
            generation: unsignedGen
        )
        let setStatus = notify_set_state(token, reg.rawBits)
        guard setStatus == UInt32(NOTIFY_STATUS_OK) else {
            throw ExtensionBridgeError.darwinNotificationFailed(
                operation: "notify_set_state",
                notificationName: notificationName,
                statusCode: setStatus
            )
        }

        let postStatus = notificationName.withCString { notify_post($0) }
        guard postStatus == UInt32(NOTIFY_STATUS_OK) else {
            throw ExtensionBridgeError.darwinNotificationFailed(
                operation: "notify_post",
                notificationName: notificationName,
                statusCode: postStatus
            )
        }
        return reg
    }

    /// Sends a zero-disk `@DarwinSignal` RPC on `signalName` carrying an
    /// optional signed 32-bit `payload` directly inside the `<notify.h>` 64-bit
    /// kernel register.
    @discardableResult
    public func postSignal(
        _ signalName: String,
        payload: Int32 = 0
    ) throws -> KernelStateRegister {
        lock.lock()
        defer { lock.unlock() }

        let token = try ensureCheckTokenLocked(signalName)
        let reg = KernelStateRegister.packSignal(
            writerId: writerId,
            payload: payload
        )
        let setStatus = notify_set_state(token, reg.rawBits)
        guard setStatus == UInt32(NOTIFY_STATUS_OK) else {
            throw ExtensionBridgeError.darwinNotificationFailed(
                operation: "notify_set_state",
                notificationName: signalName,
                statusCode: setStatus
            )
        }

        let postStatus = signalName.withCString { notify_post($0) }
        guard postStatus == UInt32(NOTIFY_STATUS_OK) else {
            throw ExtensionBridgeError.darwinNotificationFailed(
                operation: "notify_post",
                notificationName: signalName,
                statusCode: postStatus
            )
        }
        return reg
    }

    /// Registers a callback listener for cross-process state mutations on
    /// `notificationName`, suppressing self-echoes in O(1).
    public func onStateChange(
        _ notificationName: String,
        handler: @escaping @Sendable (DarwinStateWakeupEvent) -> Void
    ) throws -> DarwinNotifySubscription {
        let id = UUID()
        lock.lock()
        do {
            _ = try ensureCheckTokenLocked(notificationName)
            try ensureDispatchTokenLocked(notificationName)
            var map = stateHandlers[notificationName] ?? [:]
            map[id] = handler
            stateHandlers[notificationName] = map
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }

        return DarwinNotifySubscription { [weak self] in
            self?.removeStateHandler(notificationName: notificationName, id: id)
        }
    }

    /// Registers a callback listener for incoming `@DarwinSignal` events on
    /// `signalName`, suppressing self-echoes in O(1).
    public func onSignal(
        _ signalName: String,
        handler: @escaping @Sendable (DarwinSignalEvent) -> Void
    ) throws -> DarwinNotifySubscription {
        let id = UUID()
        lock.lock()
        do {
            _ = try ensureCheckTokenLocked(signalName)
            try ensureDispatchTokenLocked(signalName)
            var map = signalHandlers[signalName] ?? [:]
            map[id] = handler
            signalHandlers[signalName] = map
            lock.unlock()
        } catch {
            lock.unlock()
            throw error
        }

        return DarwinNotifySubscription { [weak self] in
            self?.removeSignalHandler(signalName: signalName, id: id)
        }
    }

    /// Returns a Swift 6 `AsyncStream` of cross-process ``DarwinStateWakeupEvent``
    /// notifications for `notificationName`.
    public func watchState(_ notificationName: String) -> AsyncStream<DarwinStateWakeupEvent> {
        AsyncStream { continuation in
            guard let sub = try? self.onStateChange(notificationName, handler: { event in
                continuation.yield(event)
            }) else {
                continuation.finish()
                return
            }
            continuation.onTermination = { _ in
                sub.cancel()
            }
        }
    }

    /// Returns a Swift 6 `AsyncStream` of incoming ``DarwinSignalEvent`` RPCs
    /// for `signalName`.
    public func watchSignal(_ signalName: String) -> AsyncStream<DarwinSignalEvent> {
        AsyncStream { continuation in
            guard let sub = try? self.onSignal(signalName, handler: { event in
                continuation.yield(event)
            }) else {
                continuation.finish()
                return
            }
            continuation.onTermination = { _ in
                sub.cancel()
            }
        }
    }

    /// Cancels all registered `<notify.h>` check and dispatch tokens.
    public func dispose() {
        lock.lock()
        if disposed {
            lock.unlock()
            return
        }
        disposed = true
        let dTokens = Array(dispatchTokens.values)
        let cTokens = Array(checkTokens.values)
        dispatchTokens.removeAll()
        checkTokens.removeAll()
        stateHandlers.removeAll()
        signalHandlers.removeAll()
        lock.unlock()

        for t in dTokens where notify_is_valid_token(t) {
            _ = notify_cancel(t)
        }
        for t in cTokens where notify_is_valid_token(t) {
            _ = notify_cancel(t)
        }
    }

    // MARK: - Internal Helpers

    private func ensureCheckTokenLocked(_ notificationName: String) throws -> Int32 {
        if let existing = checkTokens[notificationName], notify_is_valid_token(existing) {
            return existing
        }
        var token: Int32 = -1
        let status = notificationName.withCString { notify_register_check($0, &token) }
        guard status == UInt32(NOTIFY_STATUS_OK), notify_is_valid_token(token) else {
            throw ExtensionBridgeError.darwinNotificationFailed(
                operation: "notify_register_check",
                notificationName: notificationName,
                statusCode: status
            )
        }
        // Consume initial check=1 sentinel upon registration
        var initialCheck: Int32 = 0
        _ = notify_check(token, &initialCheck)
        checkTokens[notificationName] = token
        return token
    }

    private func ensureDispatchTokenLocked(_ notificationName: String) throws {
        if let existing = dispatchTokens[notificationName], notify_is_valid_token(existing) {
            return
        }
        var token: Int32 = -1
        let status = notificationName.withCString { namePtr in
            notify_register_dispatch(namePtr, &token, dispatchQueue) { [weak self] rawToken in
                self?.handleDispatchWakeup(notificationName: notificationName, rawToken: rawToken)
            }
        }
        guard status == UInt32(NOTIFY_STATUS_OK), notify_is_valid_token(token) else {
            throw ExtensionBridgeError.darwinNotificationFailed(
                operation: "notify_register_dispatch",
                notificationName: notificationName,
                statusCode: status
            )
        }
        dispatchTokens[notificationName] = token
    }

    private func getRegisterLocked(
        notificationName: String,
        token: Int32
    ) throws -> KernelStateRegister {
        _machIpcStateReads += 1
        var state64: UInt64 = 0
        let status = notify_get_state(token, &state64)
        guard status == UInt32(NOTIFY_STATUS_OK) else {
            throw ExtensionBridgeError.darwinNotificationFailed(
                operation: "notify_get_state",
                notificationName: notificationName,
                statusCode: status
            )
        }
        return KernelStateRegister(rawBits: state64)
    }

    private func handleDispatchWakeup(notificationName: String, rawToken: Int32) {
        lock.lock()
        if disposed {
            lock.unlock()
            return
        }

        guard let reg = try? getRegisterLocked(notificationName: notificationName, token: rawToken) else {
            lock.unlock()
            return
        }

        let sHandlers = stateHandlers[notificationName].map { Array($0.values) } ?? []
        let sigHandlers = signalHandlers[notificationName].map { Array($0.values) } ?? []

        var stateEventToDeliver: DarwinStateWakeupEvent?
        if !sHandlers.isEmpty {
            let localGen = localGenerations[notificationName].map(UInt64.init)
            if reg.shouldSuppressStateWakeup(localWriterId: writerId, localGeneration: localGen) {
                _suppressedEchoCount += 1
            } else {
                if reg.hasValidMagic {
                    localGenerations[notificationName] = reg.generation
                }
                _deliveredWakeupCount += 1
                stateEventToDeliver = DarwinStateWakeupEvent(
                    notificationName: notificationName,
                    register: reg
                )
            }
        }

        var signalEventToDeliver: DarwinSignalEvent?
        if !sigHandlers.isEmpty {
            if reg.isFromWriter(writerId) {
                _suppressedEchoCount += 1
            } else {
                _deliveredWakeupCount += 1
                signalEventToDeliver = DarwinSignalEvent(
                    signalName: notificationName,
                    writerId: reg.writerId,
                    payload: reg.signedPayload32,
                    register: reg
                )
            }
        }
        lock.unlock()

        if let event = stateEventToDeliver {
            for handler in sHandlers {
                handler(event)
            }
        }
        if let sig = signalEventToDeliver {
            for handler in sigHandlers {
                handler(sig)
            }
        }
    }

    private func removeStateHandler(notificationName: String, id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        stateHandlers[notificationName]?[id] = nil
        if stateHandlers[notificationName]?.isEmpty == true {
            stateHandlers.removeValue(forKey: notificationName)
        }
        cleanupDispatchTokenIfUnusedLocked(notificationName)
    }

    private func removeSignalHandler(signalName: String, id: UUID) {
        lock.lock()
        defer { lock.unlock() }
        signalHandlers[signalName]?[id] = nil
        if signalHandlers[signalName]?.isEmpty == true {
            signalHandlers.removeValue(forKey: signalName)
        }
        cleanupDispatchTokenIfUnusedLocked(signalName)
    }

    private func cleanupDispatchTokenIfUnusedLocked(_ name: String) {
        let hasState = !(stateHandlers[name]?.isEmpty ?? true)
        let hasSignal = !(signalHandlers[name]?.isEmpty ?? true)
        if !hasState && !hasSignal, let token = dispatchTokens.removeValue(forKey: name) {
            if notify_is_valid_token(token) {
                _ = notify_cancel(token)
            }
        }
    }
}
