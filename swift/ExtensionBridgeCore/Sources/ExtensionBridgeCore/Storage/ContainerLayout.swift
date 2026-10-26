import Foundation

/// Resolves the root directory path for a shared Darwin App Group container
/// (`group.*`).
///
/// ### Resolution Order
/// 1. Explicit in-memory override registered via ``registerOverride(groupId:containerPath:)``.
/// 2. Process environment variable `EXTENSION_BRIDGE_CONTAINER_PATH`.
/// 3. Native `FileManager.default.containerURL(forSecurityApplicationGroupIdentifier:)`.
public enum AppGroupContainerResolver: Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var overrides: [String: String] = [:]

    /// Registers a local directory `containerPath` override for `groupId`.
    ///
    /// Used by `extension_bridge sim --container-path`, multi-process chaos
    /// benchmarks, and standalone `swift test` / `dart test` suites running
    /// outside an Xcode-signed App Group sandbox.
    public static func registerOverride(groupId: String, containerPath: String) {
        lock.lock()
        defer { lock.unlock() }
        overrides[groupId] = containerPath
    }

    /// Clears a previously registered directory override for `groupId`.
    public static func clearOverride(groupId: String) {
        lock.lock()
        defer { lock.unlock() }
        overrides.removeValue(forKey: groupId)
    }

    /// Clears all registered App Group container directory overrides.
    public static func clearAllOverrides() {
        lock.lock()
        defer { lock.unlock() }
        overrides.removeAll()
    }

    /// Resolves the root directory path for `groupId`.
    ///
    /// Throws ``ExtensionBridgeError/appGroupContainerUnavailable(groupId:)``
    /// if the container cannot be resolved via overrides,
    /// `EXTENSION_BRIDGE_CONTAINER_PATH`, or `FileManager`.
    public static func resolve(
        groupId: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> String {
        lock.lock()
        let overridePath = overrides[groupId]
        lock.unlock()

        if let overridePath = overridePath, !overridePath.isEmpty {
            return overridePath
        }

        if let envPath = environment["EXTENSION_BRIDGE_CONTAINER_PATH"], !envPath.isEmpty {
            return envPath
        }

        if let url = FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: groupId
        ) {
            return url.path
        }

        throw ExtensionBridgeError.appGroupContainerUnavailable(groupId: groupId)
    }
}

/// Canonical on-disk directory and file path layout inside a shared Darwin
/// App Group container (`<AppGroupContainer>/extension_bridge/`).
///
/// ### Directory Layout
/// ```text
/// <AppGroupContainer>/
/// └── extension_bridge/
///     ├── state/
///     │   ├── <key>.v<version>.json          # Immutable snapshot (atomic rename)
///     │   ├── .<key>.v<version>.tmp.<nonce>  # Out-of-band staging file
///     │   └── .<key>.v<version>.cas          # Zero-FD symlink("<pid>:<ts>:<nonce>")
///     ├── queue/
///     │   └── <queue_key>/
///     │       ├── tmp/                       # Producer staging files
///     │       ├── ready/                     # Committed HLC-ordered envelopes
///     │       └── inflight/                  # Claimed by consumer awaiting ack()
///     └── blobs/
///         ├── queue_<item_uuid>_<idx>_<name>
///         └── state_<key>_gen_<gen>_<uuid>_<name>
/// ```
public struct ContainerLayout: Sendable, Equatable, Hashable, CustomStringConvertible {
    /// Root path of the shared App Group container directory.
    public let containerRootPath: String

    /// Creates a ``ContainerLayout`` rooted at `containerRootPath`.
    public init(containerRootPath: String) {
        self.containerRootPath = containerRootPath
    }

    /// Resolves the App Group container for `groupId` via
    /// ``AppGroupContainerResolver`` and returns its ``ContainerLayout``.
    public static func forAppGroup(
        _ groupId: String,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> ContainerLayout {
        let root = try AppGroupContainerResolver.resolve(groupId: groupId, environment: environment)
        return ContainerLayout(containerRootPath: root)
    }

    /// Root `extension_bridge/` namespace directory inside ``containerRootPath``.
    public var bridgeRootPath: String {
        "\(containerRootPath)/extension_bridge"
    }

    /// Directory storing `@SharedState` snapshots, `.tmp` staging files, and
    /// `.cas` symlink leases (`<container>/extension_bridge/state`).
    public var stateDirectoryPath: String {
        "\(bridgeRootPath)/state"
    }

    /// Root directory storing all `@SharedQueue` Maildir queues
    /// (`<container>/extension_bridge/queue`).
    public var queueRootDirectoryPath: String {
        "\(bridgeRootPath)/queue"
    }

    /// Directory storing zero-copy APFS `clonefile(2)` media attachments
    /// (`<container>/extension_bridge/blobs`).
    public var blobsDirectoryPath: String {
        "\(bridgeRootPath)/blobs"
    }

    /// Ensures `state/` and `blobs/` directories exist on disk.
    public func ensureBaseDirectories() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: stateDirectoryPath, withIntermediateDirectories: true)
        try fm.createDirectory(atPath: blobsDirectoryPath, withIntermediateDirectories: true)
    }

    /// Ensures the Maildir subdirectories (`tmp/`, `ready/`, `inflight/`) exist
    /// for `queueKey`.
    public func ensureQueueDirectories(for queueKey: String) throws {
        try ensureBaseDirectories()
        let fm = FileManager.default
        for dir in [
            queueTmpDirectoryPath(queueKey),
            queueReadyDirectoryPath(queueKey),
            queueInflightDirectoryPath(queueKey),
        ] {
            try fm.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
    }

    /// Canonical file path for the active `@SharedState` snapshot of `key` at
    /// `schemaVersion` (`state/<key>.v<schemaVersion>.json`).
    public func stateSnapshotPath(_ key: String, schemaVersion: Int = 1) -> String {
        "\(stateDirectoryPath)/\(key).v\(schemaVersion).json"
    }

    /// Hidden staging file path written and flushed before entering the `.cas`
    /// critical section (`state/.<key>.v<schemaVersion>.tmp.<nonce>`).
    public func stateStagingPath(
        _ key: String,
        nonce: String,
        schemaVersion: Int = 1
    ) -> String {
        "\(stateDirectoryPath)/.\(key).v\(schemaVersion).tmp.\(nonce)"
    }

    /// Filename prefix for any `.tmp.` staging file belonging to `key` at
    /// `schemaVersion`.
    public func stateStagingPrefix(_ key: String, schemaVersion: Int = 1) -> String {
        ".\(key).v\(schemaVersion).tmp."
    }

    /// Atomic POSIX symlink lease path for `key` at `schemaVersion`
    /// (`state/.<key>.v<schemaVersion>.cas`).
    public func stateCasLeasePath(_ key: String, schemaVersion: Int = 1) -> String {
        "\(stateDirectoryPath)/.\(key).v\(schemaVersion).cas"
    }

    /// Root directory for a specific `@SharedQueue` `queueKey`
    /// (`queue/<queueKey>`).
    public func queueDirectoryPath(_ queueKey: String) -> String {
        "\(queueRootDirectoryPath)/\(queueKey)"
    }

    /// Producer staging directory for `queueKey` (`queue/<queueKey>/tmp`).
    public func queueTmpDirectoryPath(_ queueKey: String) -> String {
        "\(queueDirectoryPath(queueKey))/tmp"
    }

    /// Committed items directory for `queueKey` (`queue/<queueKey>/ready`).
    public func queueReadyDirectoryPath(_ queueKey: String) -> String {
        "\(queueDirectoryPath(queueKey))/ready"
    }

    /// Consumer in-flight directory for `queueKey` (`queue/<queueKey>/inflight`).
    public func queueInflightDirectoryPath(_ queueKey: String) -> String {
        "\(queueDirectoryPath(queueKey))/inflight"
    }

    /// Container-relative path (`blobs/state_<stateKey>_gen_<generation>_<nonce>_<name>`)
    /// for a `@SharedState` attachment blob.
    public func stateBlobRelativePath(
        stateKey: String,
        generation: Int64,
        nonce: String,
        originalFileName: String
    ) -> String {
        let safeName = Self.sanitizeFileName(originalFileName)
        return "blobs/state_\(stateKey)_gen_\(generation)_\(nonce)_\(safeName)"
    }

    /// Container-relative path (`blobs/queue_<itemUuid>_<index>_<name>`) for a
    /// `@SharedQueue` attachment blob.
    public func queueBlobRelativePath(
        itemUuid: String,
        attachmentIndex: Int,
        originalFileName: String
    ) -> String {
        let safeName = Self.sanitizeFileName(originalFileName)
        return "blobs/queue_\(itemUuid)_\(attachmentIndex)_\(safeName)"
    }

    /// Converts a container-relative blob path (`blobs/...`) into an absolute
    /// filesystem path inside ``bridgeRootPath``.
    ///
    /// If `relativeOrAbsolutePath` is already an absolute path, returns it
    /// unchanged.
    public func resolveBlobPath(_ relativeOrAbsolutePath: String) -> String {
        if relativeOrAbsolutePath.hasPrefix("/") {
            return relativeOrAbsolutePath
        }
        return URL(fileURLWithPath: bridgeRootPath)
            .appendingPathComponent(relativeOrAbsolutePath)
            .standardized
            .path
    }

    internal static func sanitizeFileName(_ rawName: String) -> String {
        let base = URL(fileURLWithPath: rawName).lastPathComponent.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return "blob.bin" }
        var chars: [Character] = []
        chars.reserveCapacity(base.count)
        for ch in base {
            if ch.isASCII && (ch.isLetter || ch.isNumber || ch == "." || ch == "_" || ch == "-") {
                chars.append(ch)
            } else {
                chars.append("_")
            }
        }
        return String(chars)
    }

    public var description: String {
        "ContainerLayout(\(containerRootPath))"
    }
}
