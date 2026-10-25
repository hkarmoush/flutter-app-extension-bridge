import 'dart:io';
import 'dart:typed_data';

import 'package:extension_bridge/extension_bridge.dart';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  group('ApfsFileCloner', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('eb_clonefile_test_');
    });

    tearDown(() {
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    test(
        'clones files via zero-copy APFS clonefile(2) with Copy-on-Write isolation',
        () async {
      final srcPath = p.join(tempDir.path, 'source_photo.heic');
      final dstPath = p.join(
        tempDir.path,
        'blobs',
        'queue_item_0_source_photo.heic',
      );

      final payload = Uint8List.fromList(
        List<int>.generate(128 * 1024, (i) => (i * 31) & 0xFF),
      );
      File(srcPath).writeAsBytesSync(payload, flush: true);

      final cloner = ApfsFileCloner();
      final result = await cloner.cloneFile(
        sourcePath: srcPath,
        destinationPath: dstPath,
      );

      expect(result.strategy, equals(CloneStrategy.apfsClonefile));
      expect(result.fallbackErrno, isNull);
      expect(File(dstPath).existsSync(), isTrue);
      expect(File(dstPath).readAsBytesSync(), equals(payload));

      // Mutating the source file after clonefile(2) does not mutate the cloned
      // blob (Copy-on-Write isolation).
      File(srcPath).writeAsBytesSync(Uint8List.fromList(<int>[1, 2, 3]));
      expect(File(dstPath).readAsBytesSync(), equals(payload));

      // Verify zero leftover staging (.tmp) files in blobs/.
      final blobEntries = Directory(p.dirname(dstPath))
          .listSync()
          .map((e) => p.basename(e.path))
          .toList();
      expect(blobEntries, equals(<String>['queue_item_0_source_photo.heic']));
    });

    test(
        'Tier 2 Fault Injection: falls back to chunked streaming copy on EXDEV / ENOTSUP',
        () {
      final srcPath = p.join(tempDir.path, 'video_4k.mov');
      final payload = Uint8List.fromList(
        List<int>.generate(200 * 1024 + 17, (i) => (i * 73 + 11) & 0xFF),
      );
      File(srcPath).writeAsBytesSync(payload, flush: true);

      for (final simulatedErrno in <int>[
        DarwinErrno.exdev,
        DarwinErrno.enotsup,
        DarwinErrno.enosys,
      ]) {
        final dstPath = p.join(
          tempDir.path,
          'blobs',
          'fallback_$simulatedErrno.mov',
        );
        final cloner = ApfsFileCloner(
          chunkSizeBytes: 16 * 1024,
          clonefileOverride: (src, dst, flags) => simulatedErrno,
        );

        final result = cloner.cloneFileSync(
          sourcePath: srcPath,
          destinationPath: dstPath,
        );

        expect(result.strategy, equals(CloneStrategy.streamingFallback));
        expect(result.fallbackErrno, equals(simulatedErrno));
        expect(File(dstPath).readAsBytesSync(), equals(payload));
      }
    });

    test('throws AttachmentCloneException on missing source or fatal errno', () {
      final cloner = ApfsFileCloner();
      expect(
        () => cloner.cloneFileSync(
          sourcePath: p.join(tempDir.path, 'missing.jpg'),
          destinationPath: p.join(tempDir.path, 'blobs', 'out.jpg'),
        ),
        throwsA(
          isA<AttachmentCloneException>().having(
            (AttachmentCloneException e) => e.errno,
            'errno',
            DarwinErrno.enoent,
          ),
        ),
      );

      final srcPath = p.join(tempDir.path, 'valid.jpg');
      File(srcPath).writeAsStringSync('image-bytes');

      final failingCloner = ApfsFileCloner(
        clonefileOverride: (src, dst, flags) => DarwinErrno.eperm,
      );
      expect(
        () => failingCloner.cloneFileSync(
          sourcePath: srcPath,
          destinationPath: p.join(tempDir.path, 'blobs', 'denied.jpg'),
        ),
        throwsA(
          isA<AttachmentCloneException>().having(
            (AttachmentCloneException e) => e.errno,
            'errno',
            DarwinErrno.eperm,
          ),
        ),
      );
    });
  });
}
