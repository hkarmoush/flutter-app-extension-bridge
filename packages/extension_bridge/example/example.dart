/// Example demonstrating low-level wire protocol primitives in
/// `package:extension_bridge`.
library;

import 'package:extension_bridge/extension_bridge.dart';

void main() {
  // 1. Derive a 16-bit logical writer ID and pack a 64-bit <notify.h> register.
  final writerId = deriveLogicalWriterId(pid: 48210, instanceNonce: 1);
  final register = KernelStateRegister.pack(
    writerId: writerId,
    generation: 7,
  );
  assert(register.hasValidMagic);
  assert(register.writerId == writerId);
  assert(register.generation == 7);

  // 2. Generate strictly monotonic Hybrid Logical Clock (HLC) timestamps for
  //    Maildir queue ordering.
  final clock = HybridLogicalClock(writerId: writerId);
  final ts1 = clock.now();
  final ts2 = clock.now();
  assert(ts2 > ts1);

  // 3. Encode and decode a versioned StateEnvelope<Map<String, Object?>>.
  final codec = StateEnvelopeCodec<Map<String, Object?>>(
    key: 'now_playing',
    encodePayload: (map) => map,
    decodePayload: (raw) => Map<String, Object?>.from(raw! as Map),
  );
  final envelope = StateEnvelope<Map<String, Object?>>(
    schemaVersion: 1,
    generation: register.generation,
    updatedAtMicros: ts2.wallTimeMicros,
    writerId: writerId,
    payload: const <String, Object?>{
      'title': 'Starlight',
      'isPlaying': true,
    },
  );
  final bytes = codec.encodeToBytes(envelope);
  final decoded = codec.decodeFromBytes(bytes);
  assert(decoded.generation == 7);
}
