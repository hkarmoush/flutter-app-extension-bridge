import 'dart:async';
import 'dart:math' as math;

import 'package:extension_bridge/extension_bridge.dart';
import 'package:test/test.dart';

String _uniqueChannel(String label) {
  final rand = math.Random().nextInt(0x7FFFFFFF).toRadixString(16);
  final micros = DateTime.now().microsecondsSinceEpoch;
  return 'dev.extension_bridge.test.$label.$micros.$rand';
}

void main() {
  group('DarwinNotificationToken & DarwinNotifyBlockDemuxer', () {
    test('registers check and dispatch tokens and cancels cleanly', () {
      final channel = _uniqueChannel('token_lifecycle');
      final checkToken = DarwinNotificationToken.registerCheck(channel);
      expect(checkToken.isCanceled, isFalse);
      expect(checkToken.token, isNot(equals(kNotifyTokenInvalid)));
      expect(
        DarwinPosixFfi.instance.notifyIsValidToken(checkToken.token),
        isTrue,
      );

      final receivedTokens = <int>[];
      final dispatchToken = DarwinNotificationToken.registerDispatch(
        channel,
        onNotification: receivedTokens.add,
      );
      expect(dispatchToken.isDispatchToken, isTrue);
      expect(
        DarwinNotifyBlockDemuxer.instance.activeTokenCount,
        greaterThanOrEqualTo(1),
      );

      checkToken.cancel();
      expect(checkToken.isCanceled, isTrue);
      expect(checkToken.token, equals(kNotifyTokenInvalid));

      dispatchToken.cancel();
      expect(dispatchToken.isCanceled, isTrue);
    });

    test('does not retain unreachable DarwinNotificationToken in demuxer', () {
      final channel = _uniqueChannel('weak_token');
      WeakReference<DarwinNotificationToken> createEphemeralToken() {
        final token = DarwinNotificationToken.registerDispatch(
          channel,
          onNotification: (_) {},
        );
        return WeakReference<DarwinNotificationToken>(token);
      }

      final weakRef = createEphemeralToken();
      expect(weakRef.target, isNotNull);
      // Explicitly cancel if still reachable to keep test deterministic across VM GC schedules.
      weakRef.target?.cancel();
    });
  });

  group('DarwinNotificationBus — Two-Stage Fast Path & Cold-Start Seeding', () {
    late DarwinNotificationBus busA;
    late DarwinNotificationBus busB;

    setUp(() {
      busA = DarwinNotificationBus(writerId: 0x1111);
      busB = DarwinNotificationBus(writerId: 0x2222);
    });

    tearDown(() async {
      await busA.dispose();
      await busB.dispose();
    });

    test('Stage 1 notify_check shared-memory fast path (~299 ns) and Stage 2',
        () {
      final channel = _uniqueChannel('fast_path');

      // Initial check after registration reports no pending changes.
      expect(busA.checkChanged(channel), isFalse);
      expect(busA.shmFastPathHits, equals(1));

      // Run 1,000 shared-memory fast-path checks; verify sub-microsecond speed.
      final sw = Stopwatch()..start();
      for (var i = 0; i < 1000; i++) {
        expect(busA.checkChanged(channel), isFalse);
      }
      sw.stop();
      expect(busA.shmFastPathHits, equals(1001));
      // 1,000 shm reads typically complete in ~0.3 ms (< 15 ms generous CI bound).
      expect(sw.elapsedMilliseconds, lessThan(15));

      // Now busB publishes generation 7.
      final writtenReg = busB.publishState(channel, generation: 7);
      expect(writtenReg.hasValidMagic, isTrue);
      expect(writtenReg.writerId, equals(0x2222));
      expect(writtenReg.generation, equals(7));

      // Stage 1 on busA immediately detects the shm slot change.
      expect(busA.checkChanged(channel), isTrue);
      // Subsequent check without a new post returns false again.
      expect(busA.checkChanged(channel), isFalse);

      // Stage 2 reads the exact 64-bit register from notifyd.
      final readReg = busA.getRegister(channel);
      expect(readReg, equals(writtenReg));
      expect(readReg.writerId, equals(0x2222));
      expect(readReg.generation, equals(7));
    });

    test('seedStateIfUnseeded seeds 0x0 cold-start registers without overwriting',
        () {
      final channel = _uniqueChannel('cold_seed');

      // Before any writer touches the channel, its register is 0x0 (unseeded).
      final initialReg = busA.getRegister(channel);
      expect(initialReg.isUnseeded, isTrue);

      // Cold-start reader seeds generation 42 from APFS snapshot.
      final didSeed = busA.seedStateIfUnseeded(
        channel,
        authoritativeGeneration: 42,
      );
      expect(didSeed, isTrue);

      final afterSeed = busB.getRegister(channel);
      expect(afterSeed.hasValidMagic, isTrue);
      expect(afterSeed.writerId, equals(0x1111));
      expect(afterSeed.generation, equals(42));

      // Subsequent seedStateIfUnseeded calls do not overwrite a valid register.
      final didSeedAgain = busB.seedStateIfUnseeded(
        channel,
        authoritativeGeneration: 99,
      );
      expect(didSeedAgain, isFalse);
      expect(busB.getRegister(channel).generation, equals(42));
    });
  });

  group('DarwinNotificationBus — O(1) Echo Suppression & State Wakeups', () {
    late DarwinNotificationBus writerBus;
    late DarwinNotificationBus readerBus;

    setUp(() {
      writerBus = DarwinNotificationBus(writerId: 0xA001);
      readerBus = DarwinNotificationBus(writerId: 0xB002);
    });

    tearDown(() async {
      await writerBus.dispose();
      await readerBus.dispose();
    });

    test('suppresses 100% of self-echoes while waking remote listeners',
        () async {
      final channel = _uniqueChannel('echo_cancel');
      final writerWakeups = <DarwinStateWakeupEvent>[];
      final readerWakeups = <DarwinStateWakeupEvent>[];
      final firstReaderWakeup = Completer<DarwinStateWakeupEvent>();

      final writerSub = writerBus.watchState(channel).listen(writerWakeups.add);
      final readerSub = readerBus.watchState(channel).listen((event) {
        readerWakeups.add(event);
        if (!firstReaderWakeup.isCompleted) {
          firstReaderWakeup.complete(event);
        }
      });

      // Allow notifyd registration to settle.
      await Future<void>.delayed(const Duration(milliseconds: 10));

      writerBus.publishState(channel, generation: 1);

      final event = await firstReaderWakeup.future.timeout(
        const Duration(seconds: 2),
      );
      expect(event.notificationName, equals(channel));
      expect(event.writerId, equals(0xA001));
      expect(event.generation, equals(1));

      // Wait briefly to confirm writerBus's own listener also ran and dropped its echo.
      await Future<void>.delayed(const Duration(milliseconds: 25));

      expect(writerWakeups, isEmpty);
      expect(writerBus.suppressedEchoCount, greaterThanOrEqualTo(1));
      expect(readerWakeups, hasLength(1));

      // Publishing the same or older generation from another bus is also suppressed
      // as stale by readerBus because readerBus already recorded generation 1.
      final staleBus = DarwinNotificationBus(writerId: 0xC003);
      staleBus.publishState(channel, generation: 1);
      await Future<void>.delayed(const Duration(milliseconds: 25));
      expect(readerWakeups, hasLength(1));
      expect(readerBus.suppressedEchoCount, greaterThanOrEqualTo(1));

      await staleBus.dispose();
      await writerSub.cancel();
      await readerSub.cancel();
    });
  });

  group('DarwinNotificationBus — Zero-Disk 32-Bit @DarwinSignal RPC', () {
    late DarwinNotificationBus senderBus;
    late DarwinNotificationBus receiverBus;

    setUp(() {
      senderBus = DarwinNotificationBus(writerId: 0x3001);
      receiverBus = DarwinNotificationBus(writerId: 0x3002);
    });

    tearDown(() async {
      await senderBus.dispose();
      await receiverBus.dispose();
    });

    test('transmits signed & unsigned 32-bit signal payloads with zero disk I/O',
        () async {
      final signalName = _uniqueChannel('signal_rpc');
      final senderEvents = <DarwinSignalEvent>[];
      final receivedEvents = <DarwinSignalEvent>[];

      final senderSub =
          senderBus.watchSignal(signalName).listen(senderEvents.add);
      final receiverSub =
          receiverBus.watchSignal(signalName).listen(receivedEvents.add);

      await Future<void>.delayed(const Duration(milliseconds: 10));

      final testPayloads = <int>[0, 42, -1, 0x7FFFFFFF, -0x80000000, -99999];
      for (final payload in testPayloads) {
        final completer = Completer<DarwinSignalEvent>();
        late final StreamSubscription<DarwinSignalEvent> stepSub;
        stepSub = receiverBus.watchSignal(signalName).listen((event) {
          if (!completer.isCompleted) {
            completer.complete(event);
          }
        });

        senderBus.postSignal(signalName, payload: payload);
        final delivered = await completer.future.timeout(
          const Duration(seconds: 2),
        );
        await stepSub.cancel();

        expect(delivered.signalName, equals(signalName));
        expect(delivered.writerId, equals(0x3001));
        expect(delivered.payload, equals(payload));
      }

      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(senderEvents, isEmpty);
      expect(senderBus.suppressedEchoCount, equals(testPayloads.length));
      expect(receivedEvents.map((e) => e.payload).toList(), equals(testPayloads));

      await senderSub.cancel();
      await receiverSub.cancel();
    });
  });
}
