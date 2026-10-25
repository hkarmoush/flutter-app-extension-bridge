import 'dart:io';

import 'package:extension_bridge/extension_bridge.dart';
import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('DarwinPosixFfi', () {
    final posix = DarwinPosixFfi.instance;
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('eb_posix_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test('getpid returns positive OS process ID and isProcessAlive is true', () {
      final pid = posix.getpid();
      expect(pid, greaterThan(0));
      expect(pid, equals( getpidFromIo));
      expect(posix.isProcessAlive(pid), isTrue);
    });

    test('isProcessAlive returns false for non-existent / dead PIDs (ESRCH)', () {
      expect(posix.isProcessAlive(0), isFalse);
      expect(posix.isProcessAlive(-42), isFalse);
      // PID 999998 is above Darwin PID_MAX (99999) and guaranteed not to exist.
      expect(posix.isProcessAlive(999998), isFalse);
      expect(posix.lastErrno, equals(DarwinErrno.esrch));
    });

    test('atomic symlink, readlink, EEXIST contention, and unlink work', () {
      final casPath = p.join(tempDir.path, '.now_playing.v1.cas');
      final token = CasLeaseToken(
        pid: posix.getpid(),
        acquiredAtMicros: 1729785600123456,
        nonce: 'lease-uuid-001',
      );

      final createErr = posix.symlink(
        target: token.encode(),
        linkPath: casPath,
      );
      expect(createErr, equals(0));

      // Contending writer attempting to acquire the same symlink gets EEXIST.
      final contendErr = posix.symlink(
        target: '99999:1729785600999999:other',
        linkPath: casPath,
      );
      expect(contendErr, equals(DarwinErrno.eexist));

      // Reading the symlink returns the exact holder lease token.
      final rawTarget = posix.readlink(casPath);
      expect(rawTarget, equals(token.encode()));
      expect(CasLeaseToken.parse(rawTarget!), equals(token));

      // Unlinking removes the lease cleanly.
      expect(posix.unlink(casPath), equals(0));
      expect(posix.readlink(casPath), isNull);
      expect(posix.unlink(casPath), equals(DarwinErrno.enoent));
    });

    test('atomic rename replaces target snapshot atomically', () {
      final stagingPath = p.join(tempDir.path, '.state.v1.tmp.1');
      final snapshotPath = p.join(tempDir.path, 'state.v1.json');

      File(stagingPath).writeAsStringSync('{"_gen":1}');
      expect(posix.rename(stagingPath, snapshotPath), equals(0));
      expect(File(stagingPath).existsSync(), isFalse);
      expect(File(snapshotPath).readAsStringSync(), equals('{"_gen":1}'));

      // Overwrite existing snapshot via a second staging file.
      final stagingPath2 = p.join(tempDir.path, '.state.v1.tmp.2');
      File(stagingPath2).writeAsStringSync('{"_gen":2}');
      expect(posix.rename(stagingPath2, snapshotPath), equals(0));
      expect(File(snapshotPath).readAsStringSync(), equals('{"_gen":2}'));
    });
  });

  group('ObjCRuntimeFfi & AppGroupContainerResolver', () {
    final objc = ObjCRuntimeFfi.instance;
    final createdGroupDirs = <String>[
      '/Users/farisarmoush/Library/Group Containers/group.dev.extension_bridge.nonexistent_test_suite',
      '/Users/farisarmoush/Library/Group Containers/group.com.example.unentitled',
    ];

    tearDown(() {
      AppGroupContainerResolver.clearAllOverrides();
      for (final dirPath in createdGroupDirs) {
        final dir = Directory(dirPath);
        if (dir.existsSync()) {
          dir.deleteSync(recursive: true);
        }
      }
      createdGroupDirs.clear();
    });

    test('NSString UTF-8 conversion and NSFileManager App Group resolution work',
        () {
      objc.withAutoreleasePool(() {
        using((Arena arena) {
          const sample = 'PulseHub — 🎵 Live Activity & WidgetKit 🚀';
          final nsStr = objc.toNSString(sample, allocator: arena);
          expect(nsStr.address, isNot(equals(0)));
          expect(objc.fromNSString(nsStr), equals(sample));
        });
      });

      const testGroupId = 'group.dev.extension_bridge.objc_ffi_test';
      final resolvedPath = objc.containerPathForAppGroup(testGroupId);
      if (resolvedPath != null) {
        createdGroupDirs.add(resolvedPath);
        expect(resolvedPath, contains(testGroupId));
      }

      expect(objc.containerPathForAppGroup(''), isNull);
    });

    test('AppGroupContainerResolver resolves overrides and environment vars', () {
      const groupId = 'group.com.example.pulsehub';
      AppGroupContainerResolver.registerOverride(groupId, '/tmp/custom_group');
      expect(
        AppGroupContainerResolver.resolve(groupId),
        equals('/tmp/custom_group'),
      );

      AppGroupContainerResolver.clearOverride(groupId);
      expect(
        AppGroupContainerResolver.resolve(
          groupId,
          environment: const <String, String>{
            'EXTENSION_BRIDGE_CONTAINER_PATH': '/tmp/env_group',
          },
        ),
        equals('/tmp/env_group'),
      );

      expect(
        () => AppGroupContainerResolver.resolve(
          '',
          environment: const <String, String>{},
        ),
        throwsA(isA<StorageIoException>()),
      );
    });
  });

  group('DarwinLifecycleObserver', () {
    test('delivers NSNotificationCenter foreground resume events via GlobalBlock',
        () async {
      final observer = DarwinLifecycleObserver();
      final events = <String>[];
      final sub = observer.onDidBecomeActive.listen(events.add);

      expect(observer.isObserving, isTrue);

      observer.simulateDidBecomeActive();
      await Future<void>.delayed(const Duration(milliseconds: 30));

      expect(events, isNotEmpty);
      expect(observer.resumeCount, greaterThanOrEqualTo(1));

      await sub.cancel();
      expect(observer.isObserving, isFalse);
      await observer.dispose();
    });
  });

  group('ExtensionKitHooks', () {
    test('gracefully no-ops in standalone Dart VM and invokes spy callbacks', () {
      final reloadedWidgets = <String?>[];
      final reloadedControls = <String?>[];

      final hooks = ExtensionKitHooks(
        onReloadWidgetTimelines: reloadedWidgets.add,
        onReloadControlWidgets: reloadedControls.add,
      );

      expect(hooks.hasReloadWidgetTimelinesSymbol, isFalse);
      expect(hooks.hasReloadControlWidgetsSymbol, isFalse);

      hooks.reloadWidgetTimelines(kind: 'NowPlayingWidget');
      hooks.reloadWidgetTimelines();
      hooks.reloadControlWidgets(kind: 'PlaybackControl');

      expect(reloadedWidgets, equals(<String?>['NowPlayingWidget', null]));
      expect(reloadedControls, equals(<String?>['PlaybackControl']));

      expect(
        hooks.startLiveActivity(
          activityKey: 'delivery',
          attributesJson: '{}',
          contentStateJson: '{}',
        ),
        isNull,
      );
      expect(
        hooks.updateLiveActivity(
          activityKey: 'delivery',
          contentStateJson: '{}',
        ),
        isFalse,
      );
      expect(
        hooks.endLiveActivity(activityKey: 'delivery'),
        isFalse,
      );
    });
  });
}

int get getpidFromIo => pid;
