import 'dart:convert';
import 'dart:typed_data';

import 'package:extension_bridge/extension_bridge.dart';
import 'package:test/test.dart';

void main() {
  group('StateEnvelope & StateEnvelopeCodec', () {
    final mapCodec = StateEnvelopeCodec<Map<String, Object?>>(
      key: 'now_playing',
      maxSupportedSchemaVersion: 2,
      encodePayload: (value) => value,
      decodePayload: (raw) => Map<String, Object?>.from(raw! as Map),
    );

    test('round-trips canonical JSON string and UTF-8 bytes without attachments', () {
      const envelope = StateEnvelope<Map<String, Object?>>(
        schemaVersion: 1,
        generation: 42,
        updatedAtMicros: 1729785600123456,
        writerId: 18492,
        payload: <String, Object?>{
          'trackId': 'spotify:track:4cOdK2wGLETKBW3PvgPWqT',
          'title': 'Never Gonna Give You Up',
          'isPlaying': true,
          'progressMs': 45200,
        },
      );

      final jsonStr = mapCodec.encodeToString(envelope);
      final rawMap = jsonDecode(jsonStr) as Map<String, Object?>;
      expect(rawMap['_eb_magic'], 'EB01');
      expect(rawMap['_schema_version'], 1);
      expect(rawMap['_gen'], 42);
      expect(rawMap['_updated_at_us'], 1729785600123456);
      expect(rawMap['_writer_id'], 18492);
      expect(rawMap.containsKey('_attachments'), isFalse);

      final decodedFromStr = mapCodec.decodeFromString(jsonStr);
      expect(decodedFromStr.magic, 'EB01');
      expect(decodedFromStr.schemaVersion, 1);
      expect(decodedFromStr.generation, 42);
      expect(decodedFromStr.updatedAtMicros, 1729785600123456);
      expect(decodedFromStr.writerId, 18492);
      expect(decodedFromStr.attachments, isEmpty);
      expect(decodedFromStr.payload, equals(envelope.payload));

      final reg = decodedFromStr.toKernelStateRegister();
      expect(reg.hasValidMagic, isTrue);
      expect(reg.writerId, 18492);
      expect(reg.generation, 42);

      final bytes = mapCodec.encodeToBytes(envelope);
      final decodedFromBytes = mapCodec.decodeFromBytes(bytes);
      expect(decodedFromBytes.generation, 42);
      expect(decodedFromBytes.payload['title'], 'Never Gonna Give You Up');
    });

    test('preserves _attachments list and decodes StateEnvelopeHeader', () {
      const envelope = StateEnvelope<Map<String, Object?>>(
        schemaVersion: 2,
        generation: 105,
        updatedAtMicros: 1729785600999999,
        writerId: 77,
        attachments: <String>[
          'blobs/state_now_playing_gen_105_cover.jpg',
        ],
        payload: <String, Object?>{'title': 'Song'},
      );

      final jsonStr = mapCodec.encodeToString(envelope);
      final decoded = mapCodec.decodeFromString(jsonStr);
      expect(
        decoded.attachments,
        equals(<String>['blobs/state_now_playing_gen_105_cover.jpg']),
      );

      final header = StateEnvelopeHeader.fromJsonString(
        jsonStr,
        key: 'now_playing',
      );
      final headerFromBytes = StateEnvelopeHeader.fromBytes(
        mapCodec.encodeToBytes(envelope),
        key: 'now_playing',
        maxSupportedSchemaVersion: 2,
      );
      expect(header, equals(headerFromBytes));
      expect(header.hashCode, equals(headerFromBytes.hashCode));
      expect(header.toString(), contains('gen: 105'));
      expect(decoded.toString(), contains('gen: 105'));
      expect(header.schemaVersion, 2);
      expect(header.generation, 105);
      expect(header.updatedAtMicros, 1729785600999999);
      expect(header.writerId, 77);
      expect(
        header.attachments,
        equals(<String>['blobs/state_now_playing_gen_105_cover.jpg']),
      );
      expect(header.toKernelStateRegister().generation, 105);
      expect(header.toKernelStateRegister().writerId, 77);
    });

    test('throws UnsupportedSchemaVersionException when _schema_version exceeds maxSupportedSchemaVersion', () {
      final futureJson = jsonEncode(<String, Object?>{
        '_eb_magic': 'EB01',
        '_schema_version': 99,
        '_gen': 1,
        '_updated_at_us': 1000,
        '_writer_id': 1,
        'payload': <String, Object?>{},
      });

      expect(
        () => mapCodec.decodeFromString(futureJson),
        throwsA(
          isA<UnsupportedSchemaVersionException>()
              .having((e) => e.foundVersion, 'foundVersion', 99)
              .having((e) => e.maxSupportedVersion, 'maxSupportedVersion', 2)
              .having((e) => e.key, 'key', 'now_playing'),
        ),
      );
    });

    test('throws CorruptEnvelopeException on malformed JSON, UTF-8, or invalid headers', () {
      // Invalid UTF-8 bytes
      expect(
        () => mapCodec.decodeFromBytes(Uint8List.fromList(<int>[0xFF, 0xFE])),
        throwsA(isA<CorruptEnvelopeException>()),
      );

      // Malformed JSON string
      expect(
        () => mapCodec.decodeFromString('{truncated'),
        throwsA(isA<CorruptEnvelopeException>()),
      );
      expect(
        () => StateEnvelopeHeader.fromJsonString('{truncated'),
        throwsA(isA<CorruptEnvelopeException>()),
      );

      // Non-map JSON root
      expect(
        () => mapCodec.decodeFromString('[1, 2, 3]'),
        throwsA(isA<CorruptEnvelopeException>()),
      );
      expect(
        () => StateEnvelopeHeader.fromJsonString('[1, 2, 3]'),
        throwsA(isA<CorruptEnvelopeException>()),
      );

      // Corrupt magic header
      expect(
        () => mapCodec.decodeFromString(
          jsonEncode(<String, Object?>{
            '_eb_magic': 'BAD!',
            '_schema_version': 1,
            '_gen': 1,
            '_updated_at_us': 1,
            '_writer_id': 1,
            'payload': <String, Object?>{},
          }),
        ),
        throwsA(isA<CorruptEnvelopeException>()),
      );

      // Invalid _schema_version (0)
      expect(
        () => mapCodec.decodeFromString(
          jsonEncode(<String, Object?>{
            '_eb_magic': 'EB01',
            '_schema_version': 0,
            '_gen': 1,
            '_updated_at_us': 1,
            '_writer_id': 1,
            'payload': <String, Object?>{},
          }),
        ),
        throwsA(isA<CorruptEnvelopeException>()),
      );

      // Negative _gen
      expect(
        () => mapCodec.decodeFromString(
          jsonEncode(<String, Object?>{
            '_eb_magic': 'EB01',
            '_schema_version': 1,
            '_gen': -1,
            '_updated_at_us': 1,
            '_writer_id': 1,
            'payload': <String, Object?>{},
          }),
        ),
        throwsA(isA<CorruptEnvelopeException>()),
      );

      // Invalid _updated_at_us
      expect(
        () => mapCodec.decodeFromString(
          jsonEncode(<String, Object?>{
            '_eb_magic': 'EB01',
            '_schema_version': 1,
            '_gen': 1,
            '_updated_at_us': -5,
            '_writer_id': 1,
            'payload': <String, Object?>{},
          }),
        ),
        throwsA(isA<CorruptEnvelopeException>()),
      );

      // Out-of-range _writer_id
      expect(
        () => mapCodec.decodeFromString(
          jsonEncode(<String, Object?>{
            '_eb_magic': 'EB01',
            '_schema_version': 1,
            '_gen': 1,
            '_updated_at_us': 1,
            '_writer_id': 0x1FFFF,
            'payload': <String, Object?>{},
          }),
        ),
        throwsA(isA<CorruptEnvelopeException>()),
      );

      // Missing payload key
      expect(
        () => mapCodec.decodeFromString(
          jsonEncode(<String, Object?>{
            '_eb_magic': 'EB01',
            '_schema_version': 1,
            '_gen': 1,
            '_updated_at_us': 1,
            '_writer_id': 1,
          }),
        ),
        throwsA(isA<CorruptEnvelopeException>()),
      );

      // Non-list _attachments
      expect(
        () => mapCodec.decodeFromString(
          jsonEncode(<String, Object?>{
            '_eb_magic': 'EB01',
            '_schema_version': 1,
            '_gen': 1,
            '_updated_at_us': 1,
            '_writer_id': 1,
            '_attachments': 'not-a-list',
            'payload': <String, Object?>{},
          }),
        ),
        throwsA(isA<CorruptEnvelopeException>()),
      );

      // Non-string item in _attachments
      expect(
        () => mapCodec.decodeFromString(
          jsonEncode(<String, Object?>{
            '_eb_magic': 'EB01',
            '_schema_version': 1,
            '_gen': 1,
            '_updated_at_us': 1,
            '_writer_id': 1,
            '_attachments': <Object?>[123],
            'payload': <String, Object?>{},
          }),
        ),
        throwsA(isA<CorruptEnvelopeException>()),
      );

      // Payload decoder throwing an exception
      expect(
        () => mapCodec.decodeFromString(
          jsonEncode(<String, Object?>{
            '_eb_magic': 'EB01',
            '_schema_version': 1,
            '_gen': 1,
            '_updated_at_us': 1,
            '_writer_id': 1,
            'payload': 'not-a-map',
          }),
        ),
        throwsA(
          isA<CorruptEnvelopeException>().having(
            (e) => e.toString(),
            'toString',
            contains('now_playing'),
          ),
        ),
      );
    });
  });

  group('CasLeaseToken & ExtensionBridgeException', () {
    test('encodes, parses, and checks expiration of .cas symlink lease tokens', () {
      const token = CasLeaseToken(
        pid: 48219,
        acquiredAtMicros: 1729785600000000,
        nonce: '9b1deb4d-3b7d-4bad',
      );

      final encoded = token.encode();
      expect(encoded, '48219:1729785600000000:9b1deb4d-3b7d-4bad');

      final parsed = CasLeaseToken.parse(encoded);
      expect(parsed, equals(token));
      expect(parsed.hashCode, equals(token.hashCode));
      expect(parsed.toString(), contains(encoded));

      // Within 2,000 ms (2,000,000 us) ceiling -> not expired
      expect(
        token.isExpired(nowMicros: 1729785601500000),
        isFalse,
      );
      // Beyond 2,000 ms ceiling -> expired
      expect(
        token.isExpired(nowMicros: 1729785602500000),
        isTrue,
      );

      expect(CasLeaseToken.tryParse('invalid'), isNull);
      expect(CasLeaseToken.tryParse(':100:abc'), isNull);
      expect(CasLeaseToken.tryParse('100::abc'), isNull);
      expect(CasLeaseToken.tryParse('100:200:'), isNull);
      expect(CasLeaseToken.tryParse('0:200:abc'), isNull);
      expect(
        () => CasLeaseToken.parse('malformed'),
        throwsFormatException,
      );
    });

    test('constructs all sealed ExtensionBridgeException variants', () {
      const exceptions = <ExtensionBridgeException>[
        CorruptEnvelopeException('bad header', key: 'k'),
        UnsupportedSchemaVersionException(
          foundVersion: 3,
          maxSupportedVersion: 1,
          key: 'k',
        ),
        CasContentionException(key: 'k', attempts: 16, lastHolderPid: 999),
        StorageIoException('io failed', path: '/tmp/x', errno: 13),
        AttachmentCloneException(
          'clone failed',
          sourcePath: '/a',
          destinationPath: '/b',
          errno: 18,
        ),
        DarwinNotificationException(
          operation: 'notify_post',
          notificationName: 'com.app.sig',
          statusCode: 1,
        ),
      ];

      for (final ex in exceptions) {
        final description = switch (ex) {
          CorruptEnvelopeException(:final message) => message,
          UnsupportedSchemaVersionException(:final foundVersion) =>
            'v$foundVersion',
          CasContentionException(:final attempts) => '$attempts',
          StorageIoException(:final errno) => '$errno',
          AttachmentCloneException(:final destinationPath) => destinationPath,
          DarwinNotificationException(:final operation) => operation,
        };
        expect(description, isNotEmpty);
        expect(ex.toString(), isNotEmpty);
      }
    });
  });
}
