import Foundation
import XCTest
@testable import ExtensionBridgeCore

private struct SampleTrack: Codable, Sendable, Equatable {
    var id: String
    var title: String
    var durationMs: Int
}

final class ProtocolTests: XCTestCase {
    // MARK: - KernelStateRegister Tests

    func testKernelStateRegisterPackingAndUnpacking() {
        let reg = KernelStateRegister.pack(writerId: 0x483C, generation: 42)
        XCTAssertEqual(reg.magic, kKernelStateRegisterMagic)
        XCTAssertTrue(reg.hasValidMagic)
        XCTAssertFalse(reg.isUnseeded)
        XCTAssertEqual(reg.writerId, 0x483C)
        XCTAssertEqual(reg.generation, 42)
        XCTAssertEqual(reg.toHexString(), "0xeb42483c0000002a")
    }

    func testKernelStateRegisterBoundaryValuesAndSignals() {
        let zero = KernelStateRegister.zero
        XCTAssertEqual(zero.rawBits, 0)
        XCTAssertFalse(zero.hasValidMagic)
        XCTAssertTrue(zero.isUnseeded)

        let maxGen = KernelStateRegister.pack(writerId: 0xFFFF, generation: 0xFFFF_FFFF)
        XCTAssertTrue(maxGen.hasValidMagic)
        XCTAssertEqual(maxGen.writerId, 0xFFFF)
        XCTAssertEqual(maxGen.generation, 0xFFFF_FFFF)
        XCTAssertEqual(maxGen.signedPayload32, -1)

        let negSignal = KernelStateRegister.packSignal(writerId: 0x1234, payload: -420)
        XCTAssertTrue(negSignal.hasValidMagic)
        XCTAssertEqual(negSignal.writerId, 0x1234)
        XCTAssertEqual(negSignal.signedPayload32, -420)
    }

    func testKernelStateRegisterEchoSuppression() {
        let reg = KernelStateRegister.pack(writerId: 100, generation: 15)
        // Same writer -> suppress
        XCTAssertTrue(reg.shouldSuppressStateWakeup(localWriterId: 100, localGeneration: nil))
        // Different writer, older or equal generation -> suppress
        XCTAssertTrue(reg.shouldSuppressStateWakeup(localWriterId: 200, localGeneration: 15))
        XCTAssertTrue(reg.shouldSuppressStateWakeup(localWriterId: 200, localGeneration: 20))
        // Different writer, newer generation -> deliver
        XCTAssertFalse(reg.shouldSuppressStateWakeup(localWriterId: 200, localGeneration: 14))
        XCTAssertFalse(reg.shouldSuppressStateWakeup(localWriterId: 200, localGeneration: nil))
        // Corrupt magic -> never suppress so cold-start reader inspects APFS
        let unseeded = KernelStateRegister(rawBits: 0)
        XCTAssertFalse(unseeded.shouldSuppressStateWakeup(localWriterId: 100, localGeneration: 999))
    }

    func testDeriveLogicalWriterIdProducesNonZeroDistinctIds() {
        let id1 = KernelStateRegister.deriveLogicalWriterId(pid: 12345, instanceNonce: 1)
        let id2 = KernelStateRegister.deriveLogicalWriterId(pid: 12345, instanceNonce: 2)
        XCTAssertNotEqual(id1, 0)
        XCTAssertNotEqual(id2, 0)
        XCTAssertNotEqual(id1, id2)
    }

    // MARK: - HybridLogicalClock Tests

    func testHlcMonotonicityUnderBackwardClockDriftAndBurst() {
        final class MockClock: @unchecked Sendable {
            var currentMicros: Int64 = 1_729_800_000_000_000
        }
        let mock = MockClock()
        let hlc = HybridLogicalClock(writerId: 7) { mock.currentMicros }

        let t1 = hlc.now()
        let t2 = hlc.now()
        XCTAssertEqual(t1.wallTimeMicros, 1_729_800_000_000_000)
        XCTAssertEqual(t1.logicalCounter, 0)
        XCTAssertEqual(t2.wallTimeMicros, 1_729_800_000_000_000)
        XCTAssertEqual(t2.logicalCounter, 1)
        XCTAssertTrue(t1 < t2)

        // Simulate NTP backward clock jump of 5 seconds
        mock.currentMicros -= 5_000_000
        let t3 = hlc.now()
        XCTAssertEqual(t3.wallTimeMicros, 1_729_800_000_000_000)
        XCTAssertEqual(t3.logicalCounter, 2)
        XCTAssertTrue(t2 < t3)

        // Receive remote timestamp ahead of local wall clock
        let remote = HlcTimestamp(
            wallTimeMicros: 1_729_800_010_000_000,
            logicalCounter: 5,
            writerId: 99
        )
        let t4 = hlc.receive(remote)
        XCTAssertEqual(t4.wallTimeMicros, 1_729_800_010_000_000)
        XCTAssertEqual(t4.logicalCounter, 6)
        XCTAssertTrue(remote < t4)
    }

    func testHlcQueueFilenameFormattingAndParsing() throws {
        let ts = HlcTimestamp(wallTimeMicros: 1_729_800_000_123, logicalCounter: 0x001A, writerId: 3)
        XCTAssertEqual(ts.toSortablePrefix(), "00001729800000123_001a")
        let fileName = ts.toQueueFileName("4821_1_deadbeef")
        XCTAssertEqual(fileName, "00001729800000123_001a_4821_1_deadbeef.json")

        let parsed = try HlcTimestamp.parse("/tmp/queue/ready/\(fileName)")
        XCTAssertEqual(parsed.wallTimeMicros, ts.wallTimeMicros)
        XCTAssertEqual(parsed.logicalCounter, ts.logicalCounter)

        XCTAssertNil(HlcTimestamp.tryParse("invalid_filename.json"))
    }

    // MARK: - CasLeaseToken Tests

    func testCasLeaseTokenRoundTripAndExpiration() throws {
        let token = CasLeaseToken(pid: 48219, acquiredAtMicros: 1_000_000, nonce: "abc_123")
        let encoded = token.encode()
        XCTAssertEqual(encoded, "48219:1000000:abc_123")

        let parsed = try CasLeaseToken.parse(encoded)
        XCTAssertEqual(parsed, token)
        XCTAssertFalse(parsed.isExpired(nowMicros: 2_500_000, ceilingMicros: 2_000_000))
        XCTAssertTrue(parsed.isExpired(nowMicros: 3_000_001, ceilingMicros: 2_000_000))

        XCTAssertNil(CasLeaseToken.tryParse("0:1000:abc"))
        XCTAssertNil(CasLeaseToken.tryParse("bad"))
    }

    // MARK: - StateEnvelope & Codec Tests

    func testStateEnvelopeCodecRoundTripAndValidation() throws {
        let codec = StateEnvelopeCodec<SampleTrack>.codable(
            SampleTrack.self,
            key: "now_playing",
            maxSupportedSchemaVersion: 2
        )
        let original = StateEnvelope(
            schemaVersion: 1,
            generation: 42,
            updatedAtMicros: 1_729_785_600_123_456,
            writerId: 18492,
            payload: SampleTrack(id: "t1", title: "Synthwave", durationMs: 210_000),
            attachments: ["blobs/state_now_playing_gen_42_cover.jpg"]
        )

        let data = try codec.encodeToData(original)
        let decoded = try codec.decodeFromData(data)
        XCTAssertEqual(decoded, original)

        let header = try StateEnvelopeHeader.fromData(data, key: "now_playing")
        XCTAssertEqual(header.generation, 42)
        XCTAssertEqual(header.writerId, 18492)
        XCTAssertEqual(header.attachments, ["blobs/state_now_playing_gen_42_cover.jpg"])

        // Test unsupported schema version rejection
        let v3Json = """
        {
          "_eb_magic": "EB01",
          "_schema_version": 3,
          "_gen": 1,
          "_updated_at_us": 100,
          "_writer_id": 1,
          "payload": {"id": "t1", "title": "Future", "durationMs": 100}
        }
        """
        XCTAssertThrowsError(try codec.decodeFromString(v3Json)) { error in
            guard case let ExtensionBridgeError.unsupportedSchemaVersion(key, found, maxVer) = error else {
                XCTFail("Expected unsupportedSchemaVersion, got \(error)")
                return
            }
            XCTAssertEqual(key, "now_playing")
            XCTAssertEqual(found, 3)
            XCTAssertEqual(maxVer, 2)
        }
    }
}
