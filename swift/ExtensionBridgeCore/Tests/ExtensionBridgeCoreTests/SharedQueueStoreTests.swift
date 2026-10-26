import Foundation
import XCTest
@testable import ExtensionBridgeCore

private struct SharedPhotoItem: Codable, Sendable, Equatable {
    var index: Int
    var caption: String
    var photoPath: String?
}

final class SharedQueueStoreTests: XCTestCase {
    private var tempDir: URL!
    private var layout: ContainerLayout!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("eb_swift_queue_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        layout = ContainerLayout(containerRootPath: tempDir.path)
    }

    override func tearDownWithError() throws {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testMaildirQueueOrderingAttachmentLifecycleAndInflightRecovery() throws {
        let center = DarwinNotifyCenter(writerId: 0x5050)
        defer { center.dispose() }
        let channel = "com.example.eb.queue.\(UUID().uuidString)"

        let photoFile = tempDir.appendingPathComponent("shared_photo.heic")
        try Data("heic-image-payload".utf8).write(to: photoFile)

        let makeQueue = {
            SharedQueueStore<SharedPhotoItem>(
                queueKey: "inbox",
                layout: self.layout,
                codec: .codable(SharedPhotoItem.self, key: "inbox"),
                notifyCenter: center,
                notificationName: channel,
                maxItems: 3,
                stageAttachments: { item, itemUuid, mgr in
                    var copy = item
                    var blobs: [String] = []
                    if let path = copy.photoPath {
                        let rel = try mgr.stageQueueAttachment(
                            sourcePath: path,
                            itemUuid: itemUuid,
                            attachmentIndex: 0
                        )
                        copy.photoPath = rel
                        blobs.append(rel)
                    }
                    return StagedAttachments(stagedValue: copy, relativeBlobPaths: blobs)
                },
                resolveAttachments: { item, mgr in
                    var copy = item
                    if let path = copy.photoPath {
                        copy.photoPath = mgr.resolveAttachmentPath(path)
                    }
                    return copy
                }
            )
        }

        let producer = makeQueue()
        _ = try producer.enqueue(SharedPhotoItem(index: 1, caption: "One", photoPath: photoFile.path))
        _ = try producer.enqueue(SharedPhotoItem(index: 2, caption: "Two", photoPath: photoFile.path))
        XCTAssertEqual(producer.pendingReadyCount(), 2)

        // Claim item 1 into inflight/ and simulate consumer crash before ack()
        let crashedConsumer = makeQueue()
        let firstDelivery = try XCTUnwrap(try crashedConsumer.claimNextDelivery())
        XCTAssertEqual(firstDelivery.value.index, 1)
        XCTAssertFalse(firstDelivery.isRedelivery)
        XCTAssertEqual(crashedConsumer.inflightCount(), 1)
        let blob1Path = try XCTUnwrap(firstDelivery.value.photoPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: blob1Path))

        // New consumer instance recovers inflight/ on startup and delivers item 1 with isRedelivery == true
        let recoveredConsumer = makeQueue()
        let redelivered = try XCTUnwrap(try recoveredConsumer.claimNextDelivery())
        XCTAssertEqual(redelivered.value.index, 1)
        XCTAssertTrue(redelivered.isRedelivery)
        XCTAssertEqual(recoveredConsumer.recoveredInflightCount, 1)

        // Acknowledge item 1 -> unlinks inflight envelope AND attachment blob
        redelivered.ack()
        XCTAssertFalse(FileManager.default.fileExists(atPath: blob1Path))

        // Claim item 2, test nack(requeue: true), then claim again and ack()
        let secondDelivery = try XCTUnwrap(try recoveredConsumer.claimNextDelivery())
        XCTAssertEqual(secondDelivery.value.index, 2)
        secondDelivery.nack(requeue: true)
        XCTAssertEqual(recoveredConsumer.pendingReadyCount(), 1)

        let secondRedelivered = try XCTUnwrap(try recoveredConsumer.claimNextDelivery())
        XCTAssertTrue(secondRedelivered.isRedelivery)
        secondRedelivered.ack()
        XCTAssertEqual(recoveredConsumer.pendingReadyCount(), 0)
        XCTAssertEqual(recoveredConsumer.inflightCount(), 0)
    }

    func testMaxItemsBackpressureEvictsOldestAndUnlinksBlobs() throws {
        let vault = ExtensionBridgeVault(
            groupId: "group.com.example.test",
            layout: layout
        )
        defer { vault.dispose() }

        let photoFile = tempDir.appendingPathComponent("burst.jpg")
        try Data("burst-data".utf8).write(to: photoFile)

        let queue = vault.queueStore(
            queueKey: "bounded",
            type: SharedPhotoItem.self,
            maxItems: 2,
            stageAttachments: { item, itemUuid, mgr in
                var copy = item
                var blobs: [String] = []
                if let path = copy.photoPath {
                    let rel = try mgr.stageQueueAttachment(
                        sourcePath: path,
                        itemUuid: itemUuid,
                        attachmentIndex: 0
                    )
                    copy.photoPath = rel
                    blobs.append(rel)
                }
                return StagedAttachments(stagedValue: copy, relativeBlobPaths: blobs)
            },
            resolveAttachments: { item, mgr in
                var copy = item
                if let path = copy.photoPath {
                    copy.photoPath = mgr.resolveAttachmentPath(path)
                }
                return copy
            }
        )

        for i in 1...4 {
            _ = try queue.enqueue(SharedPhotoItem(index: i, caption: "Item \(i)", photoPath: photoFile.path))
        }

        XCTAssertEqual(queue.pendingReadyCount(), 2)
        XCTAssertEqual(queue.evictedBackpressureCount, 2)

        let drained = try queue.drainAvailable()
        XCTAssertEqual(drained.map(\.value.index), [3, 4])
        for d in drained {
            d.ack()
        }

        // Verify zero leaked blobs after draining and acking remaining items
        let remainingBlobs = try FileManager.default.contentsOfDirectory(atPath: layout.blobsDirectoryPath)
        XCTAssertTrue(remainingBlobs.isEmpty)
    }
}
