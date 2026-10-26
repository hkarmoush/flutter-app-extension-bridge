import Darwin
import Foundation
import XCTest
@testable import ExtensionBridgeCore

private struct CounterState: Codable, Sendable, Equatable {
    var count: Int
    var label: String
    var attachmentPath: String?
}

final class AtomicStateStoreTests: XCTestCase {
    private var tempDir: URL!
    private var layout: ContainerLayout!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("eb_swift_state_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        layout = ContainerLayout(containerRootPath: tempDir.path)
    }

    override func tearDownWithError() throws {
        if let tempDir = tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    func testReadWriteUpdateAndFastPathCache() throws {
        let center = DarwinNotifyCenter(writerId: 0x1010)
        defer { center.dispose() }
        let channel = "com.example.eb.state.\(UUID().uuidString)"

        let store = AtomicStateStore<CounterState>(
            key: "counter",
            layout: layout,
            codec: .codable(CounterState.self, key: "counter"),
            notifyCenter: center,
            notificationName: channel
        )

        XCTAssertNil(try store.read())

        let env1 = try store.write(CounterState(count: 1, label: "first"))
        XCTAssertEqual(env1.generation, 1)

        // Subsequent read hits ~299 ns memory cache
        let result1 = try store.readResult()
        XCTAssertTrue(result1.isFromMemoryCache)
        XCTAssertEqual(result1.valueOrNil?.count, 1)
        XCTAssertEqual(store.memoryCacheHits, 1)

        // Transactional CAS update
        let env2 = try store.update { current in
            var next = current ?? CounterState(count: 0, label: "")
            next.count += 10
            next.label = "updated"
            return next
        }
        XCTAssertEqual(env2.generation, 2)
        XCTAssertEqual(try store.read()?.count, 11)
    }

    func testDeadPidCasLeaseInstantEviction() throws {
        let center = DarwinNotifyCenter(writerId: 0x2020)
        defer { center.dispose() }
        let channel = "com.example.eb.deadpid.\(UUID().uuidString)"

        let store = AtomicStateStore<CounterState>(
            key: "counter",
            layout: layout,
            codec: .codable(CounterState.self, key: "counter"),
            notifyCenter: center,
            notificationName: channel
        )
        try layout.ensureBaseDirectories()

        // Inject an orphaned .cas symlink pointing to a non-existent PID (999999)
        // with a fresh timestamp to prove eviction happens via kill(pid, 0) == ESRCH
        // rather than waiting for the 2,000 ms timeout.
        let nowMicros = Int64(Date().timeIntervalSince1970 * 1_000_000.0)
        let deadLease = CasLeaseToken(pid: 999_999, acquiredAtMicros: nowMicros, nonce: "crashed")
        XCTAssertEqual(
            DarwinPosix.shared.createSymlink(target: deadLease.encode(), linkPath: store.casLeaseFilePath),
            0
        )

        // Also inject an orphaned .tmp staging file from dead PID 999999
        let orphanTmp = layout.stateStagingPath("counter", nonce: "999999_\(nowMicros)_1_dead")
        try Data("partial".utf8).write(to: URL(fileURLWithPath: orphanTmp))

        let start = DispatchTime.now().uptimeNanoseconds
        let committed = try store.write(CounterState(count: 42, label: "recovered"))
        let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000.0

        XCTAssertEqual(committed.generation, 1)
        XCTAssertEqual(store.evictedDeadPidLeaseCount, 1)
        XCTAssertLessThan(elapsedMs, 50.0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: orphanTmp))
        XCTAssertNil(DarwinPosix.shared.readSymlink(store.casLeaseFilePath))
    }

    func testAdversarialCasContentionAndSplitBrainProtection() throws {
        let center1 = DarwinNotifyCenter(writerId: 0x3001)
        let center2 = DarwinNotifyCenter(writerId: 0x3002)
        defer {
            center1.dispose()
            center2.dispose()
        }
        let channel = "com.example.eb.cas.\(UUID().uuidString)"

        let rivalStore = AtomicStateStore<CounterState>(
            key: "counter",
            layout: layout,
            codec: .codable(CounterState.self, key: "counter"),
            notifyCenter: center2,
            notificationName: channel
        )
        _ = try rivalStore.write(CounterState(count: 10, label: "initial"))

        // Fault 1: On attempt 1, rival commits a new generation after store reads
        // snapshot but before store acquires .cas. Store must detect _gen mismatch
        // and retry pure mutator against rival's new value!
        // Fault 2: On attempt 2, simulate split-brain lease theft right before rename.
        let store = AtomicStateStore<CounterState>(
            key: "counter",
            layout: layout,
            codec: .codable(CounterState.self, key: "counter"),
            notifyCenter: center1,
            notificationName: channel,
            onBeforeCasAcquire: { attempt, _ in
                if attempt == 1 {
                    _ = try rivalStore.update { cur in
                        CounterState(count: (cur?.count ?? 0) + 5, label: "rival")
                    }
                }
            },
            onBeforeRenameCommit: { attempt, _, casPath in
                if attempt == 2 {
                    _ = DarwinPosix.shared.unlinkFile(casPath)
                    let stolen = CasLeaseToken(
                        pid: DarwinPosix.shared.currentPid(),
                        acquiredAtMicros: 1,
                        nonce: "stolen_lease"
                    )
                    _ = DarwinPosix.shared.createSymlink(target: stolen.encode(), linkPath: casPath)
                }
            }
        )

        let finalEnv = try store.update { cur in
            CounterState(count: (cur?.count ?? 0) + 1, label: "winner")
        }

        // 10 (initial) + 5 (rival) + 1 (store after retry) = 16! Zero lost updates!
        XCTAssertEqual(finalEnv.payload.count, 16)
        XCTAssertEqual(finalEnv.generation, 3)
        XCTAssertEqual(store.splitBrainPreventedCount, 1)
        XCTAssertGreaterThanOrEqual(store.casRetryCount, 2)
    }

    func testStateAttachmentBlobGarbageCollectionKeepsTwoPreviousGenerations() throws {
        let center = DarwinNotifyCenter(writerId: 0x4040)
        defer { center.dispose() }
        let channel = "com.example.eb.blobs.\(UUID().uuidString)"

        let sourceImg = tempDir.appendingPathComponent("cover.jpg")
        try Data("artwork-bytes".utf8).write(to: sourceImg)

        let store = AtomicStateStore<CounterState>(
            key: "track",
            layout: layout,
            codec: .codable(CounterState.self, key: "track"),
            notifyCenter: center,
            notificationName: channel,
            stageAttachments: { value, gen, mgr in
                var copy = value
                var blobs: [String] = []
                if let path = copy.attachmentPath {
                    let rel = try mgr.stageStateAttachment(
                        sourcePath: path,
                        stateKey: "track",
                        generation: gen
                    )
                    copy.attachmentPath = rel
                    blobs.append(rel)
                }
                return StagedAttachments(stagedValue: copy, relativeBlobPaths: blobs)
            },
            resolveAttachments: { value, mgr in
                var copy = value
                if let path = copy.attachmentPath {
                    copy.attachmentPath = mgr.resolveAttachmentPath(path)
                }
                return copy
            }
        )

        for i in 1...4 {
            _ = try store.write(
                CounterState(count: i, label: "g\(i)", attachmentPath: sourceImg.path)
            )
        }

        // At generation 4, blobs for gen 1 (< 4 - 2) must be GC'd, while gen 2, 3, 4 remain.
        let remaining = try FileManager.default.contentsOfDirectory(atPath: layout.blobsDirectoryPath)
        XCTAssertFalse(remaining.contains(where: { $0.contains("_gen_1_") }))
        XCTAssertTrue(remaining.contains(where: { $0.contains("_gen_2_") }))
        XCTAssertTrue(remaining.contains(where: { $0.contains("_gen_3_") }))
        XCTAssertTrue(remaining.contains(where: { $0.contains("_gen_4_") }))

        let readBack = try store.read()
        XCTAssertNotNil(readBack?.attachmentPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: readBack!.attachmentPath!))
    }
}
