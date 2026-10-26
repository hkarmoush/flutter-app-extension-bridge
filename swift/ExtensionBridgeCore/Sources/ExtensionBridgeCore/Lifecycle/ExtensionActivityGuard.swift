import Foundation

/// Cross-platform process activity and iOS background expiration helpers for
/// App Extensions (`WidgetKit`, `AppIntents`, Share Extensions, and
/// `ControlWidget`).
///
/// Ensuring short atomic file commits run inside an activity assertion
/// prevents the system from suspending the process mid-operation while keeping
/// extension tasks responsive to Jetsam/SpringBoard expiration signals.
public enum ExtensionActivityGuard: Sendable {
    /// Executes a synchronous `operation` inside
    /// `ProcessInfo.processInfo.performActivity(options: .userInitiatedAllowingIdleSystemSleep, reason:)`
    /// across both macOS and iOS.
    @inlinable
    public static func performProtectedActivity<R>(
        reason: String = "ExtensionBridge Atomic Commit",
        _ operation: () throws -> R
    ) rethrows -> R {
        let token = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: reason
        )
        defer {
            ProcessInfo.processInfo.endActivity(token)
        }
        return try operation()
    }

    /// Executes an asynchronous extension task with OS expiration awareness.
    ///
    /// - On **iOS**, wraps execution in
    ///   `ProcessInfo.processInfo.performExpiringActivity(withReason:)` and
    ///   checks `guard !expired else { return }` before invoking `operation`.
    /// - On **macOS**, executes `operation` inside a user-initiated activity
    ///   assertion.
    ///
    /// - Returns `true` if `operation` completed before system expiration, or
    ///   `false` if the system signaled expiration.
    @discardableResult
    public static func performExpiringExtensionActivity(
        reason: String = "ExtensionBridge Background Mutation",
        _ operation: @escaping @Sendable () async throws -> Void
    ) async throws -> Bool {
        #if os(iOS)
        final class CompletionBox: @unchecked Sendable {
            let lock = NSLock()
            var resumed = false
            var capturedError: Error?
            var completed = false
        }
        let box = CompletionBox()

        return try await withCheckedThrowingContinuation { continuation in
            ProcessInfo.processInfo.performExpiringActivity(withReason: reason) { expired in
                guard !expired else {
                    box.lock.lock()
                    let shouldResume = !box.resumed
                    box.resumed = true
                    box.lock.unlock()
                    if shouldResume {
                        continuation.resume(returning: false)
                    }
                    return
                }

                let semaphore = DispatchSemaphore(value: 0)
                Task {
                    do {
                        try await operation()
                        box.lock.lock()
                        box.completed = true
                        box.lock.unlock()
                    } catch {
                        box.lock.lock()
                        box.capturedError = error
                        box.lock.unlock()
                    }
                    semaphore.signal()
                }
                semaphore.wait()

                box.lock.lock()
                let shouldResume = !box.resumed
                box.resumed = true
                let err = box.capturedError
                let ok = box.completed
                box.lock.unlock()

                if shouldResume {
                    if let err = err {
                        continuation.resume(throwing: err)
                    } else {
                        continuation.resume(returning: ok)
                    }
                }
            }
        }
        #else
        let token = ProcessInfo.processInfo.beginActivity(
            options: .userInitiatedAllowingIdleSystemSleep,
            reason: reason
        )
        defer {
            ProcessInfo.processInfo.endActivity(token)
        }
        try await operation()
        return true
        #endif
    }
}
