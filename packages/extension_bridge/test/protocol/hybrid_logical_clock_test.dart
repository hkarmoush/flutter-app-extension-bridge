import 'package:extension_bridge/extension_bridge.dart';
import 'package:test/test.dart';

void main() {
  group('HlcTimestamp & HybridLogicalClock', () {
    test('maintains strict monotonicity when wall clock advances, freezes, or drifts backward', () {
      var simulatedMicros = 1729800000100;
      final clock = HybridLogicalClock(
        writerId: 0x10,
        wallClockMicros: () => simulatedMicros,
      );

      expect(clock.lastTimestamp, isNull);

      final t1 = clock.now();
      expect(t1.wallTimeMicros, 1729800000100);
      expect(t1.logicalCounter, 0);
      expect(t1.writerId, 0x10);
      expect(clock.lastTimestamp, equals(t1));

      // Frozen wall clock (same microsecond): increments logicalCounter
      final t2 = clock.now();
      expect(t2.wallTimeMicros, 1729800000100);
      expect(t2.logicalCounter, 1);
      expect(t2 > t1, isTrue);

      // Simulated NTP backward clock drift (-500,000 us): preserves monotonicity
      simulatedMicros -= 500000;
      final t3 = clock.now();
      expect(t3.wallTimeMicros, 1729800000100);
      expect(t3.logicalCounter, 2);
      expect(t3 > t2, isTrue);

      // Wall clock catches up and advances beyond 1729800000100
      simulatedMicros = 1729800000250;
      final t4 = clock.now();
      expect(t4.wallTimeMicros, 1729800000250);
      expect(t4.logicalCounter, 0);
      expect(t4 > t3, isTrue);
    });

    test('handles counter overflow (> 0xFFFF events in 1 us) by advancing logical wall time', () {
      const frozenMicros = 1729800000500;
      final clock = HybridLogicalClock(
        writerId: 1,
        wallClockMicros: () => frozenMicros,
      );

      var previous = clock.now();
      for (var i = 0; i < kMaxHlcCounter + 5; i++) {
        final current = clock.now();
        expect(current > previous, isTrue);
        previous = current;
      }

      expect(previous.wallTimeMicros, frozenMicros + 1);
      expect(previous.logicalCounter, 4);
    });

    test('receive() merges remote causal timestamps across all branches', () {
      var physical = 1000;
      final clock = HybridLogicalClock(
        writerId: 2,
        wallClockMicros: () => physical,
      );

      final local0 = clock.now(); // (1000, 0)
      expect(local0.wallTimeMicros, 1000);

      // Branch 1: remote wallTime > physical and local
      const remoteFuture = HlcTimestamp(
        wallTimeMicros: 5000,
        logicalCounter: 7,
        writerId: 9,
      );
      final merged1 = clock.receive(remoteFuture);
      expect(merged1.wallTimeMicros, 5000);
      expect(merged1.logicalCounter, 8);
      expect(merged1 > remoteFuture, isTrue);

      // Branch 2: local wallTime == remote wallTime
      const remoteSameWall = HlcTimestamp(
        wallTimeMicros: 5000,
        logicalCounter: 20,
        writerId: 9,
      );
      final merged2 = clock.receive(remoteSameWall);
      expect(merged2.wallTimeMicros, 5000);
      expect(merged2.logicalCounter, 21);

      // Branch 3: local wallTime > remote wallTime (and physical <= local)
      const remotePast = HlcTimestamp(
        wallTimeMicros: 3000,
        logicalCounter: 99,
        writerId: 9,
      );
      final merged3 = clock.receive(remotePast);
      expect(merged3.wallTimeMicros, 5000);
      expect(merged3.logicalCounter, 22);

      // Branch 4: physical wallTime > both local and remote
      physical = 9000;
      final merged4 = clock.receive(remoteSameWall);
      expect(merged4.wallTimeMicros, 9000);
      expect(merged4.logicalCounter, 0);
    });

    test('encodes and parses lexicographically sortable Maildir queue filenames', () {
      var micros = 1729800000123;
      final clock = HybridLogicalClock(
        writerId: 1,
        wallClockMicros: () => micros,
      );

      final timestamps = <HlcTimestamp>[
        clock.now(),
        clock.now(),
        () {
          micros += 10;
          return clock.now();
        }(),
        () {
          micros -= 50; // backward jump
          return clock.now();
        }(),
      ];

      final filenames = [
        for (var i = 0; i < timestamps.length; i++)
          timestamps[i].toQueueFileName('item-$i'),
      ];

      final sortedFilenames = [...filenames]..sort();
      expect(sortedFilenames, equals(filenames));

      // Verify round-trip parsing from prefix and full filename
      for (var i = 0; i < timestamps.length; i++) {
        final parsedFromFile = HlcTimestamp.parse(filenames[i]);
        final parsedFromPrefix = HlcTimestamp.parse(
          timestamps[i].toSortablePrefix(),
        );
        expect(parsedFromFile.wallTimeMicros, timestamps[i].wallTimeMicros);
        expect(parsedFromFile.logicalCounter, timestamps[i].logicalCounter);
        expect(parsedFromPrefix.wallTimeMicros, timestamps[i].wallTimeMicros);
        expect(parsedFromPrefix.logicalCounter, timestamps[i].logicalCounter);
      }

      // Verify relational operators and invalid inputs
      expect(timestamps[0] < timestamps[1], isTrue);
      expect(timestamps[0] <= timestamps[0], isTrue);
      expect(timestamps[1] >= timestamps[0], isTrue);
      expect(timestamps[0].hashCode, equals(timestamps[0].hashCode));
      expect(timestamps[0].toString(), contains('00001729800000123_0000'));

      expect(HlcTimestamp.tryParse('short'), isNull);
      expect(HlcTimestamp.tryParse('00001729800000123-0001_uuid.json'), isNull);
      expect(HlcTimestamp.tryParse('00001729800000123_0001Xuuid.json'), isNull);
      expect(HlcTimestamp.tryParse('00001729800000123_zzzz_uuid.json'), isNull);
      expect(
        () => HlcTimestamp.parse('invalid_filename.json'),
        throwsFormatException,
      );
    });
  });
}
