import Darwin
import Foundation
import XCTest
@testable import ExtensionBridgeCore

final class DarwinNotifyAndClonerTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("eb_swift_test_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testStage1NotifyCheckFastPathAndStage2Register() throws {
        let center1 = DarwinNotifyCenter(writerId: 0x1111)
        let center2 = DarwinNotifyCenter(writerId: 0x2222)
        defer {
            center1.dispose()
            center2.dispose()
        }

        let channel = "dev.extension_bridge.swift_test.fast_path.\(UUID().uuidString)"

        // First check registers the token and returns false (sentinel consumed).
        XCTAssertFalse(try center1.checkChanged(channel))
        XCTAssertEqual(center1.shmFastPathHits, 1)

        for _ in 0..<1000 {
            XCTAssertFalse(try center1.checkChanged(channel))
        }
        XCTAssertEqual(center1.shmFastPathHits, 1001)

        // Publish state from center2 -> notifyd processes the one-way Mach message
        // and increments the shared-memory slot within ~10-50 us.
        let writtenReg = try center2.publishState(channel, generation: 78)
        XCTAssertTrue(writtenReg.hasValidMagic)
        XCTAssertEqual(writtenReg.writerId, 0x2222)
        XCTAssertEqual(writtenReg.generation, 78)

        var detectedChange = false
        for _ in 0..<200 {
            if try center1.checkChanged(channel) {
                detectedChange = true
                break
            }
            usleep(50)
        }
        XCTAssertTrue(detectedChange)

        // Subsequent check without new post hits ~299 ns shm fast path
        XCTAssertFalse(try center1.checkChanged(channel))

        let readReg = try center1.getRegister(channel)
        XCTAssertEqual(readReg, writtenReg)
    }

    func testColdStartSeedStateIfUnseeded() throws {
        let center1 = DarwinNotifyCenter(writerId: 0x1111)
        let center2 = DarwinNotifyCenter(writerId: 0x2222)
        defer {
            center1.dispose()
            center2.dispose()
        }

        let channel = "dev.extension_bridge.swift_test.cold_seed.\(UUID().uuidString)"

        // Unseeded initially
        let initialReg = try center1.getRegister(channel)
        XCTAssertTrue(initialReg.isUnseeded)

        // Seed state without posting
        let didSeed = try center1.seedStateIfUnseeded(channel, authoritativeGeneration: 77)
        XCTAssertTrue(didSeed)

        let seededReg = try center2.getRegister(channel)
        XCTAssertTrue(seededReg.hasValidMagic)
        XCTAssertEqual(seededReg.generation, 77)
        XCTAssertEqual(seededReg.writerId, 0x1111)

        // Subsequent seedStateIfUnseeded does not overwrite a valid register
        XCTAssertFalse(try center2.seedStateIfUnseeded(channel, authoritativeGeneration: 99))
        XCTAssertEqual(try center2.getRegister(channel).generation, 77)
    }

    func testSelfEchoSuppressionAndRemoteSignalDelivery() throws {
        let sender = DarwinNotifyCenter(writerId: 0xAAAA)
        let receiver = DarwinNotifyCenter(writerId: 0xBBBB)
        defer {
            sender.dispose()
            receiver.dispose()
        }

        let signalChannel = "com.example.eb.swift_sig.\(UUID().uuidString)"
        let senderEchoExp = expectation(description: "Sender echo should be suppressed")
        senderEchoExp.isInverted = true

        let receiverExp = expectation(description: "Receiver receives signal")

        let sub1 = try sender.onSignal(signalChannel) { _ in
            senderEchoExp.fulfill()
        }
        let sub2 = try receiver.onSignal(signalChannel) { event in
            if event.payload == -12345 && event.writerId == 0xAAAA {
                receiverExp.fulfill()
            }
        }
        defer {
            sub1.cancel()
            sub2.cancel()
        }

        _ = try sender.postSignal(signalChannel, payload: -12345)

        wait(for: [receiverExp, senderEchoExp], timeout: 0.5)
        XCTAssertGreaterThanOrEqual(sender.suppressedEchoCount, 1)
        XCTAssertEqual(receiver.deliveredWakeupCount, 1)
    }

    func testApfsFileClonerZeroCopyAndExdevStreamingFallback() throws {
        let sourceURL = tempDir.appendingPathComponent("source_media.bin")
        var payload = Data(count: 256 * 1024)
        for i in 0..<payload.count {
            payload[i] = UInt8(i & 0xFF)
        }
        try payload.write(to: sourceURL)

        // 1. Native APFS clonefile(2)
        let dstCloneURL = tempDir.appendingPathComponent("blobs/cloned_media.bin")
        let cloner = ApfsFileCloner()
        let cloneRes = try cloner.cloneFile(from: sourceURL.path, to: dstCloneURL.path)
        XCTAssertEqual(cloneRes.strategy, .apfsClonefile)
        XCTAssertNil(cloneRes.fallbackErrno)
        XCTAssertEqual(try Data(contentsOf: dstCloneURL), payload)

        // 2. Simulated EXDEV cross-volume error -> streaming fallback
        let dstStreamURL = tempDir.appendingPathComponent("blobs/streamed_media.bin")
        let fallbackCloner = ApfsFileCloner(
            clonefileOverride: { _, _, _ in EXDEV },
            chunkSizeBytes: 16 * 1024
        )
        let fallbackRes = try fallbackCloner.cloneFile(from: sourceURL.path, to: dstStreamURL.path)
        XCTAssertEqual(fallbackRes.strategy, .streamingFallback)
        XCTAssertEqual(fallbackRes.fallbackErrno, EXDEV)
        XCTAssertEqual(try Data(contentsOf: dstStreamURL), payload)
    }

    func testExtensionKitCAbiSupportAndActivityGuard() async throws {
        final class ReloadTracker: @unchecked Sendable {
            var widgetKinds: [String?] = []
            var controlKinds: [String?] = []
        }
        let tracker = ReloadTracker()
        ExtensionKitCAbiSupport.installTestReloadSpies(
            onWidgetReload: { tracker.widgetKinds.append($0) },
            onControlReload: { tracker.controlKinds.append($0) }
        )
        defer {
            ExtensionKitCAbiSupport.installTestReloadSpies()
        }

        "NowPlayingWidget".withCString { ptr in
            ExtensionKitCAbiSupport.reloadWidgetTimelines(cStringKind: ptr)
        }
        ExtensionKitCAbiSupport.reloadControlWidgets(cStringKind: nil)

        XCTAssertEqual(tracker.widgetKinds, ["NowPlayingWidget"])
        XCTAssertEqual(tracker.controlKinds, [nil])

        var buf = [CChar](repeating: 0, count: 32)
        let rc = ExtensionKitCAbiSupport.copyCString("activity-123", to: &buf, capacity: 32)
        XCTAssertEqual(rc, 0)
        XCTAssertEqual(ExtensionKitCAbiSupport.decodeOptionalCString(buf), "activity-123")

        let ok = try await ExtensionActivityGuard.performExpiringExtensionActivity {
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTAssertTrue(ok)
    }
}
