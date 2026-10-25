import 'package:extension_bridge/extension_bridge.dart';
import 'package:test/test.dart';

void main() {
  group('KernelStateRegister', () {
    test('packs and unpacks 16-bit magic, 16-bit writerId, and 32-bit generation', () {
      final reg = KernelStateRegister.pack(
        writerId: 0x483C,
        generation: 42,
      );

      expect(reg.magic, kKernelStateRegisterMagic);
      expect(reg.hasValidMagic, isTrue);
      expect(reg.isUnseeded, isFalse);
      expect(reg.writerId, 0x483C);
      expect(reg.generation, 42);
      expect(reg.toHexString(), '0xeb42483c0000002a');
    });

    test('handles boundary values (0 and 0xFFFFFFFF) without sign corruption', () {
      final minReg = KernelStateRegister.pack(
        writerId: 0x0001,
        generation: 0,
      );
      expect(minReg.hasValidMagic, isTrue);
      expect(minReg.writerId, 1);
      expect(minReg.generation, 0);

      final maxReg = KernelStateRegister.pack(
        writerId: 0xFFFF,
        generation: 0xFFFFFFFF,
      );
      expect(maxReg.hasValidMagic, isTrue);
      expect(maxReg.writerId, 0xFFFF);
      expect(maxReg.generation, 0xFFFFFFFF);
      expect(maxReg.signedPayload32, -1);
      expect(maxReg.toHexString(), '0xeb42ffffffffffff');
    });

    test('detects unseeded (0x0) and corrupt magic headers', () {
      expect(KernelStateRegister.zero.rawBits, 0);
      expect(KernelStateRegister.zero.hasValidMagic, isFalse);
      expect(KernelStateRegister.zero.isUnseeded, isTrue);

      final corrupt = KernelStateRegister.pack(
        writerId: 0x1234,
        generation: 99,
        magic: 0xDEAD,
      );
      expect(corrupt.magic, 0xDEAD);
      expect(corrupt.hasValidMagic, isFalse);
      expect(corrupt.isUnseeded, isTrue);
    });

    test('packs and unpacks signed 32-bit signal payloads losslessly', () {
      for (final payload in <int>[-2147483648, -42, -1, 0, 1, 42, 2147483647]) {
        final reg = KernelStateRegister.packSignal(
          writerId: 0x7777,
          payload: payload,
        );
        expect(reg.hasValidMagic, isTrue);
        expect(reg.writerId, 0x7777);
        expect(reg.signedPayload32, payload);
      }
    });

    test('evaluates O(1) self-echo and stale generation suppression', () {
      final reg = KernelStateRegister.pack(
        writerId: 0x2222,
        generation: 10,
      );

      expect(reg.isFromWriter(0x2222), isTrue);
      expect(reg.isFromWriter(0x3333), isFalse);

      // Self-echo from localWriterId is suppressed even when localGeneration is null
      expect(
        reg.shouldSuppressStateWakeup(localWriterId: 0x2222),
        isTrue,
      );

      // Same or older generation than local state -> suppress wakeup
      expect(
        reg.shouldSuppressStateWakeup(
          localWriterId: 0x3333,
          localGeneration: 10,
        ),
        isTrue,
      );
      expect(
        reg.shouldSuppressStateWakeup(
          localWriterId: 0x3333,
          localGeneration: 11,
        ),
        isTrue,
      );

      // Newer generation from remote writer -> do not suppress
      expect(
        reg.shouldSuppressStateWakeup(
          localWriterId: 0x3333,
          localGeneration: 9,
        ),
        isFalse,
      );

      // Unseeded register (0x0) -> never suppress (triggers cold-start read/seed)
      expect(
        KernelStateRegister.zero.shouldSuppressStateWakeup(
          localWriterId: 0x2222,
          localGeneration: 10,
        ),
        isFalse,
      );
    });

    test('deriveLogicalWriterId returns non-zero 16-bit IDs and separates in-process instances', () {
      final idA = deriveLogicalWriterId(pid: 41200, instanceNonce: 1);
      final idB = deriveLogicalWriterId(pid: 41200, instanceNonce: 2);
      final idAuto1 = deriveLogicalWriterId(pid: 41200);
      final idAuto2 = deriveLogicalWriterId(pid: 41200);

      expect(idA, inInclusiveRange(1, 0xFFFF));
      expect(idB, inInclusiveRange(1, 0xFFFF));
      expect(idA, isNot(equals(idB)));
      expect(idAuto1, inInclusiveRange(1, 0xFFFF));
      expect(idAuto2, inInclusiveRange(1, 0xFFFF));

      // Verify zero PID + zero nonce still produces non-zero 16-bit writerId.
      final zeroInputId = deriveLogicalWriterId(pid: 0, instanceNonce: 0);
      expect(zeroInputId, inInclusiveRange(1, 0xFFFF));
    });
  });
}
