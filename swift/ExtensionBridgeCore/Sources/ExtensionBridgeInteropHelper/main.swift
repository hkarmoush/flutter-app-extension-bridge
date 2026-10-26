import ExtensionBridgeCore
import Foundation

/// Shared model used by the Dart <-> Swift 6 cross-language interoperability
/// verification suite.
struct InteropNowPlaying: Codable, Sendable, Equatable {
    var trackId: String
    var title: String
    var playCount: Int
    var isPlaying: Bool
    var artworkPath: String?
}

/// Shared queue item model used by the Dart <-> Swift 6 cross-language
/// interoperability verification suite.
struct InteropSharedMediaItem: Codable, Sendable, Equatable {
    var caption: String
    var index: Int
    var mediaPath: String?
}

enum InteropHelperCLI {
    static func run() throws {
        let args = Array(CommandLine.arguments.dropFirst())
        guard let command = args.first else {
            fputs("Usage: eb-swift-interop-helper <command> [options]\n", stderr)
            exit(64)
        }

        switch command {
        case "cas-update-state":
            // Args: cas-update-state <containerPath> <key> <notificationName> <deltaPlayCount> <newTitle> [newArtworkSourcePath]
            guard args.count >= 6 else {
                fputs("Missing arguments for cas-update-state\n", stderr)
                exit(64)
            }
            let containerPath = args[1]
            let key = args[2]
            let notificationName = args[3]
            let delta = Int(args[4]) ?? 1
            let newTitle = args[5]
            let newArtworkSource = args.count >= 7 ? args[6] : nil

            let layout = ContainerLayout(containerRootPath: containerPath)
            let center = DarwinNotifyCenter()
            defer { center.dispose() }
            let attachmentManager = SharedAttachmentManager(layout: layout)

            let store = AtomicStateStore<InteropNowPlaying>(
                key: key,
                layout: layout,
                codec: .codable(InteropNowPlaying.self, key: key),
                notifyCenter: center,
                notificationName: notificationName,
                schemaVersion: 1,
                attachmentManager: attachmentManager,
                stageAttachments: { value, gen, mgr in
                    var copy = value
                    var blobs: [String] = []
                    if let path = copy.artworkPath, !path.isEmpty {
                        let rel = try mgr.stageStateAttachment(
                            sourcePath: path,
                            stateKey: key,
                            generation: gen
                        )
                        copy.artworkPath = rel
                        blobs.append(rel)
                    }
                    return StagedAttachments(stagedValue: copy, relativeBlobPaths: blobs)
                },
                resolveAttachments: { value, mgr in
                    var copy = value
                    if let path = copy.artworkPath, !path.isEmpty {
                        copy.artworkPath = mgr.resolveAttachmentPath(path)
                    }
                    return copy
                }
            )

            let committed = try store.update { current in
                var state = current ?? InteropNowPlaying(
                    trackId: "track:0",
                    title: "Initial",
                    playCount: 0,
                    isPlaying: false,
                    artworkPath: nil
                )
                state.playCount += delta
                state.title = newTitle
                state.isPlaying = true
                if let art = newArtworkSource {
                    state.artworkPath = art
                }
                return state
            }
            print("OK gen=\(committed.generation) writerId=\(committed.writerId) playCount=\(committed.payload.playCount)")

        case "enqueue-media":
            // Args: enqueue-media <containerPath> <queueKey> <notificationName> <caption> <index> [mediaSourcePath]
            guard args.count >= 6 else {
                fputs("Missing arguments for enqueue-media\n", stderr)
                exit(64)
            }
            let containerPath = args[1]
            let queueKey = args[2]
            let notificationName = args[3]
            let caption = args[4]
            let index = Int(args[5]) ?? 0
            let mediaSource = args.count >= 7 ? args[6] : nil

            let layout = ContainerLayout(containerRootPath: containerPath)
            let center = DarwinNotifyCenter()
            defer { center.dispose() }
            let attachmentManager = SharedAttachmentManager(layout: layout)

            let queue = SharedQueueStore<InteropSharedMediaItem>(
                queueKey: queueKey,
                layout: layout,
                codec: .codable(InteropSharedMediaItem.self, key: queueKey),
                notifyCenter: center,
                notificationName: notificationName,
                schemaVersion: 1,
                attachmentManager: attachmentManager,
                stageAttachments: { item, itemUuid, mgr in
                    var copy = item
                    var blobs: [String] = []
                    if let path = copy.mediaPath, !path.isEmpty {
                        let rel = try mgr.stageQueueAttachment(
                            sourcePath: path,
                            itemUuid: itemUuid,
                            attachmentIndex: 0
                        )
                        copy.mediaPath = rel
                        blobs.append(rel)
                    }
                    return StagedAttachments(stagedValue: copy, relativeBlobPaths: blobs)
                },
                resolveAttachments: { item, mgr in
                    var copy = item
                    if let path = copy.mediaPath, !path.isEmpty {
                        copy.mediaPath = mgr.resolveAttachmentPath(path)
                    }
                    return copy
                }
            )

            let receipt = try queue.enqueue(
                InteropSharedMediaItem(
                    caption: caption,
                    index: index,
                    mediaPath: mediaSource
                )
            )
            print("OK file=\(receipt.fileName) itemId=\(receipt.itemId)")

        case "drain-and-ack":
            // Args: drain-and-ack <containerPath> <queueKey> <notificationName>
            guard args.count >= 4 else {
                fputs("Missing arguments for drain-and-ack\n", stderr)
                exit(64)
            }
            let containerPath = args[1]
            let queueKey = args[2]
            let notificationName = args[3]

            let layout = ContainerLayout(containerRootPath: containerPath)
            let center = DarwinNotifyCenter()
            defer { center.dispose() }
            let attachmentManager = SharedAttachmentManager(layout: layout)

            let queue = SharedQueueStore<InteropSharedMediaItem>(
                queueKey: queueKey,
                layout: layout,
                codec: .codable(InteropSharedMediaItem.self, key: queueKey),
                notifyCenter: center,
                notificationName: notificationName,
                schemaVersion: 1,
                attachmentManager: attachmentManager,
                resolveAttachments: { item, mgr in
                    var copy = item
                    if let path = copy.mediaPath, !path.isEmpty {
                        copy.mediaPath = mgr.resolveAttachmentPath(path)
                    }
                    return copy
                }
            )

            let deliveries = try queue.drainAvailable()
            for d in deliveries {
                if let mediaPath = d.value.mediaPath {
                    guard FileManager.default.fileExists(atPath: mediaPath) else {
                        fputs("Missing attachment at \(mediaPath)\n", stderr)
                        exit(2)
                    }
                }
                d.ack()
            }
            print("OK drained=\(deliveries.count)")

        case "post-signal":
            // Args: post-signal <signalName> <payloadInt32>
            guard args.count >= 3 else {
                fputs("Missing arguments for post-signal\n", stderr)
                exit(64)
            }
            let signalName = args[1]
            let payload = Int32(args[2]) ?? 0
            let center = DarwinNotifyCenter()
            defer { center.dispose() }
            let reg = try center.postSignal(signalName, payload: payload)
            print("OK register=\(reg.toHexString())")

        default:
            fputs("Unknown command: \(command)\n", stderr)
            exit(64)
        }
    }
}

do {
    try InteropHelperCLI.run()
} catch {
    fputs("ERROR: \(error)\n", stderr)
    exit(1)
}
