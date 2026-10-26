import Foundation

/// High-level Swift 6 container coordinator that binds a shared App Group
/// ``ContainerLayout``, ``DarwinNotifyCenter``, and ``SharedAttachmentManager``.
///
/// Generated `<Name>ExtensionKit` Swift packages instantiate an
/// ``ExtensionBridgeVault`` for their `@AppGroupSchema(groupId:)` so
/// `TimelineProvider`, `AppIntent`, `UIShareExtension`, and `ControlWidget`
/// targets can access `@SharedState`, `@SharedQueue`, and `@DarwinSignal`
/// channels through a single thread-safe, `Sendable` handle.
public final class ExtensionBridgeVault: @unchecked Sendable {
    /// App Group identifier (e.g., `"group.com.example.app"`).
    public let groupId: String

    /// Default schema version (`_schema_version`) used by stores created from
    /// this vault.
    public let schemaVersion: Int

    /// Canonical directory layout inside the shared App Group container.
    public let layout: ContainerLayout

    /// Underlying Darwin `<notify.h>` notification center.
    public let notifyCenter: DarwinNotifyCenter

    /// Zero-copy APFS `clonefile(2)` attachment manager.
    public let attachmentManager: SharedAttachmentManager

    private let posix: DarwinPosix

    /// Creates an ``ExtensionBridgeVault`` with an explicit ``ContainerLayout``.
    public init(
        groupId: String,
        layout: ContainerLayout,
        schemaVersion: Int = 1,
        notifyCenter: DarwinNotifyCenter? = nil,
        attachmentManager: SharedAttachmentManager? = nil,
        posix: DarwinPosix = .shared
    ) {
        self.groupId = groupId
        self.layout = layout
        self.schemaVersion = schemaVersion
        self.posix = posix
        self.notifyCenter = notifyCenter ?? DarwinNotifyCenter()
        self.attachmentManager = attachmentManager ?? SharedAttachmentManager(
            layout: layout,
            posix: posix
        )
    }

    /// Creates an ``ExtensionBridgeVault`` by resolving the shared container
    /// directory for `groupId` via ``AppGroupContainerResolver``.
    public convenience init(
        groupId: String,
        schemaVersion: Int = 1,
        notifyCenter: DarwinNotifyCenter? = nil,
        posix: DarwinPosix = .shared
    ) throws {
        let layout = try ContainerLayout.forAppGroup(groupId)
        self.init(
            groupId: groupId,
            layout: layout,
            schemaVersion: schemaVersion,
            notifyCenter: notifyCenter,
            posix: posix
        )
    }

    /// Computes the canonical `<notify.h>` notification channel name for a
    /// `@SharedState` `key` (`"<groupId>.eb.state.<key>"`).
    public func stateNotificationName(for key: String) -> String {
        "\(groupId).eb.state.\(key)"
    }

    /// Computes the canonical `<notify.h>` notification channel name for a
    /// `@SharedQueue` `queueKey` (`"<groupId>.eb.queue.<queueKey>"`).
    public func queueNotificationName(for queueKey: String) -> String {
        "\(groupId).eb.queue.\(queueKey)"
    }

    /// Computes the canonical `<notify.h>` notification channel name for a
    /// `@DarwinSignal` `signalName` (`"<groupId>.eb.signal.<signalName>"`).
    public func signalNotificationName(for signalName: String) -> String {
        "\(groupId).eb.signal.\(signalName)"
    }

    /// Creates an ``AtomicStateStore`` bound to this vault for any
    /// `Codable & Sendable` model type `T`.
    public func stateStore<T: Codable & Sendable>(
        key: String,
        type: T.Type = T.self,
        notificationName: String? = nil,
        schemaVersion: Int? = nil,
        reloadWidgets: [String]? = nil,
        reloadControls: [String]? = nil,
        stageAttachments: StateAttachmentStager<T>? = nil,
        resolveAttachments: AttachmentPathResolver<T>? = nil
    ) -> AtomicStateStore<T> {
        let ver = schemaVersion ?? self.schemaVersion
        return AtomicStateStore<T>(
            key: key,
            layout: layout,
            codec: .codable(T.self, key: key, maxSupportedSchemaVersion: ver),
            notifyCenter: notifyCenter,
            notificationName: notificationName ?? stateNotificationName(for: key),
            schemaVersion: ver,
            attachmentManager: attachmentManager,
            posix: posix,
            reloadWidgets: reloadWidgets,
            reloadControls: reloadControls,
            stageAttachments: stageAttachments,
            resolveAttachments: resolveAttachments
        )
    }

    /// Creates a ``SharedQueueStore`` bound to this vault for any
    /// `Codable & Sendable` item type `T`.
    public func queueStore<T: Codable & Sendable>(
        queueKey: String,
        type: T.Type = T.self,
        notificationName: String? = nil,
        schemaVersion: Int? = nil,
        maxItems: Int = 256,
        stageAttachments: QueueAttachmentStager<T>? = nil,
        resolveAttachments: AttachmentPathResolver<T>? = nil
    ) -> SharedQueueStore<T> {
        let ver = schemaVersion ?? self.schemaVersion
        return SharedQueueStore<T>(
            queueKey: queueKey,
            layout: layout,
            codec: .codable(T.self, key: queueKey, maxSupportedSchemaVersion: ver),
            notifyCenter: notifyCenter,
            notificationName: notificationName ?? queueNotificationName(for: queueKey),
            schemaVersion: ver,
            maxItems: maxItems,
            attachmentManager: attachmentManager,
            posix: posix,
            stageAttachments: stageAttachments,
            resolveAttachments: resolveAttachments
        )
    }

    /// Posts a zero-disk 32-bit `@DarwinSignal` RPC on `signalName`.
    @discardableResult
    public func postSignal(
        _ signalName: String,
        payload: Int32 = 0,
        notificationName: String? = nil
    ) throws -> KernelStateRegister {
        let channel = notificationName ?? signalNotificationName(for: signalName)
        return try notifyCenter.postSignal(channel, payload: payload)
    }

    /// Watches incoming `@DarwinSignal` events on `signalName`.
    public func watchSignal(
        _ signalName: String,
        notificationName: String? = nil
    ) -> AsyncStream<DarwinSignalEvent> {
        let channel = notificationName ?? signalNotificationName(for: signalName)
        return notifyCenter.watchSignal(channel)
    }

    /// Disposes underlying `<notify.h>` tokens.
    public func dispose() {
        notifyCenter.dispose()
    }
}
