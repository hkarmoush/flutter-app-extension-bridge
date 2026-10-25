import 'dart:convert';
import 'dart:typed_data';

import 'package:meta/meta.dart';

import 'bridge_exception.dart';
import 'kernel_state_register.dart';

/// Magic wire identifier (`"EB01"`) stored in the `"_eb_magic"` field of every
/// `extension_bridge` JSON envelope on disk.
const String kStateEnvelopeMagic = 'EB01';

/// {@template extension_bridge.state_envelope}
/// Immutable, versioned wire envelope wrapping a serialized `@SharedState` or
/// `@SharedQueue` [payload] inside `<AppGroupContainer>/extension_bridge/`.
///
/// ### Canonical Wire Format
/// ```json
/// {
///   "_eb_magic": "EB01",
///   "_schema_version": 1,
///   "_gen": 42,
///   "_updated_at_us": 1729785600123456,
///   "_writer_id": 18492,
///   "payload": { ... }
/// }
/// ```
/// {@endtemplate}
@immutable
final class StateEnvelope<T> {
  /// {@macro extension_bridge.state_envelope}
  const StateEnvelope({
    required this.schemaVersion,
    required this.generation,
    required this.updatedAtMicros,
    required this.writerId,
    required this.payload,
    this.attachments = const <String>[],
    this.magic = kStateEnvelopeMagic,
  })  : assert(schemaVersion >= 1, 'schemaVersion must be >= 1'),
        assert(generation >= 0, 'generation must be >= 0'),
        assert(updatedAtMicros >= 0, 'updatedAtMicros must be >= 0'),
        assert(
          writerId >= 0 && writerId <= 0xFFFF,
          'writerId must fit in 16 bits (0..0xFFFF)',
        );

  /// Wire magic string (`"EB01"`).
  final String magic;

  /// Schema version (`_schema_version`) declared on `@AppGroupSchema`.
  final int schemaVersion;

  /// Monotonic 64-bit generation counter (`_gen`) incremented on every atomic
  /// CAS commit.
  final int generation;

  /// UTC timestamp in microseconds (`_updated_at_us`) when this snapshot was
  /// committed.
  final int updatedAtMicros;

  /// 16-bit logical writer identifier (`_writer_id`) of the process/instance
  /// that committed this snapshot.
  final int writerId;

  /// Strongly-typed decoded model payload.
  final T payload;

  /// Optional list of container-relative blob paths (`blobs/...`) referenced
  /// by `@SharedAttachment` fields in [payload].
  final List<String> attachments;

  /// Converts this envelope's metadata into a 64-bit [KernelStateRegister]
  /// suitable for `notify_set_state`.
  KernelStateRegister toKernelStateRegister() => KernelStateRegister.pack(
        writerId: writerId,
        generation: generation,
      );

  /// Serializes this envelope into a JSON-compatible `Map<String, Object?>`
  /// using [payloadEncoder].
  Map<String, Object?> toJsonMap(
    Object? Function(T payload) payloadEncoder,
  ) =>
      <String, Object?>{
        '_eb_magic': magic,
        '_schema_version': schemaVersion,
        '_gen': generation,
        '_updated_at_us': updatedAtMicros,
        '_writer_id': writerId,
        if (attachments.isNotEmpty) '_attachments': attachments,
        'payload': payloadEncoder(payload),
      };

  /// Parses and validates a [StateEnvelope] from a decoded JSON [map] using
  /// [payloadDecoder].
  ///
  /// Throws:
  /// - [CorruptEnvelopeException] if any required header field is missing,
  ///   has an invalid type, or `_eb_magic != "EB01"`.
  /// - [UnsupportedSchemaVersionException] if [maxSupportedSchemaVersion] is
  ///   provided and `_schema_version > maxSupportedSchemaVersion`.
  factory StateEnvelope.fromJsonMap(
    Map<String, Object?> map, {
    required T Function(Object? rawPayload) payloadDecoder,
    String? key,
    int? maxSupportedSchemaVersion,
  }) {
    final magic = map['_eb_magic'];
    if (magic != kStateEnvelopeMagic) {
      throw CorruptEnvelopeException(
        'Expected _eb_magic "$kStateEnvelopeMagic", found "$magic"',
        key: key,
      );
    }

    final schemaVersion = map['_schema_version'];
    if (schemaVersion is! int || schemaVersion < 1) {
      throw CorruptEnvelopeException(
        'Invalid or missing integer _schema_version: $schemaVersion',
        key: key,
      );
    }

    if (maxSupportedSchemaVersion != null &&
        schemaVersion > maxSupportedSchemaVersion) {
      throw UnsupportedSchemaVersionException(
        key: key,
        foundVersion: schemaVersion,
        maxSupportedVersion: maxSupportedSchemaVersion,
      );
    }

    final generation = map['_gen'];
    if (generation is! int || generation < 0) {
      throw CorruptEnvelopeException(
        'Invalid or missing non-negative integer _gen: $generation',
        key: key,
      );
    }

    final updatedAtMicros = map['_updated_at_us'];
    if (updatedAtMicros is! int || updatedAtMicros < 0) {
      throw CorruptEnvelopeException(
        'Invalid or missing non-negative integer _updated_at_us: '
        '$updatedAtMicros',
        key: key,
      );
    }

    final writerId = map['_writer_id'];
    if (writerId is! int || writerId < 0 || writerId > 0xFFFF) {
      throw CorruptEnvelopeException(
        'Invalid or missing 16-bit _writer_id: $writerId',
        key: key,
      );
    }

    if (!map.containsKey('payload')) {
      throw CorruptEnvelopeException(
        'Envelope is missing required "payload" key',
        key: key,
      );
    }

    final rawAttachments = map['_attachments'];
    final attachments = <String>[];
    if (rawAttachments != null) {
      if (rawAttachments is! List<Object?>) {
        throw CorruptEnvelopeException(
          'Expected "_attachments" to be a List, found '
          '${rawAttachments.runtimeType}',
          key: key,
        );
      }
      for (final item in rawAttachments) {
        if (item is! String) {
          throw CorruptEnvelopeException(
            'Expected string path in "_attachments", found $item',
            key: key,
          );
        }
        attachments.add(item);
      }
    }

    final T decodedPayload;
    try {
      decodedPayload = payloadDecoder(map['payload']);
    } on ExtensionBridgeException {
      rethrow;
    } on Object catch (error) {
      throw CorruptEnvelopeException(
        'Failed to decode envelope payload: $error',
        key: key,
        cause: error,
      );
    }

    return StateEnvelope<T>(
      magic: magic as String,
      schemaVersion: schemaVersion,
      generation: generation,
      updatedAtMicros: updatedAtMicros,
      writerId: writerId,
      payload: decodedPayload,
      attachments: List<String>.unmodifiable(attachments),
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StateEnvelope<T> &&
          other.magic == magic &&
          other.schemaVersion == schemaVersion &&
          other.generation == generation &&
          other.updatedAtMicros == updatedAtMicros &&
          other.writerId == writerId &&
          other.payload == payload &&
          _stringListEquals(other.attachments, attachments);

  @override
  int get hashCode => Object.hash(
        magic,
        schemaVersion,
        generation,
        updatedAtMicros,
        writerId,
        payload,
        Object.hashAll(attachments),
      );

  @override
  String toString() => 'StateEnvelope('
      'schemaVersion: $schemaVersion, '
      'gen: $generation, '
      'writerId: $writerId, '
      'updatedAtMicros: $updatedAtMicros, '
      'attachments: $attachments, '
      'payload: $payload)';
}

/// Lightweight header-only view of a [StateEnvelope] used during cold-start
/// register seeding and CAS generation checks without decoding the payload.
@immutable
final class StateEnvelopeHeader {
  /// Creates a [StateEnvelopeHeader].
  const StateEnvelopeHeader({
    required this.schemaVersion,
    required this.generation,
    required this.updatedAtMicros,
    required this.writerId,
    this.attachments = const <String>[],
  });

  /// Schema version (`_schema_version`).
  final int schemaVersion;

  /// Monotonic 64-bit generation (`_gen`).
  final int generation;

  /// Commit timestamp in UTC microseconds (`_updated_at_us`).
  final int updatedAtMicros;

  /// 16-bit logical writer ID (`_writer_id`).
  final int writerId;

  /// Container-relative blob paths (`_attachments`).
  final List<String> attachments;

  /// Packs [writerId] and [generation] into a [KernelStateRegister].
  KernelStateRegister toKernelStateRegister() => KernelStateRegister.pack(
        writerId: writerId,
        generation: generation,
      );

  /// Decodes only the envelope header metadata from a JSON string.
  factory StateEnvelopeHeader.fromJsonString(
    String jsonString, {
    String? key,
    int? maxSupportedSchemaVersion,
  }) {
    final Object? decoded;
    try {
      decoded = jsonDecode(jsonString);
    } on FormatException catch (error) {
      throw CorruptEnvelopeException(
        'Malformed JSON in state envelope',
        key: key,
        rawContent: jsonString,
        cause: error,
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw CorruptEnvelopeException(
        'Expected JSON object at envelope root, found ${decoded.runtimeType}',
        key: key,
        rawContent: jsonString,
      );
    }
    final envelope = StateEnvelope<Object?>.fromJsonMap(
      decoded,
      payloadDecoder: (raw) => raw,
      key: key,
      maxSupportedSchemaVersion: maxSupportedSchemaVersion,
    );
    return StateEnvelopeHeader(
      schemaVersion: envelope.schemaVersion,
      generation: envelope.generation,
      updatedAtMicros: envelope.updatedAtMicros,
      writerId: envelope.writerId,
      attachments: envelope.attachments,
    );
  }

  /// Decodes only the envelope header metadata from raw UTF-8 [bytes].
  factory StateEnvelopeHeader.fromBytes(
    Uint8List bytes, {
    String? key,
    int? maxSupportedSchemaVersion,
  }) {
    final String jsonString;
    try {
      jsonString = const Utf8Codec().decode(bytes);
    } on FormatException catch (error) {
      throw CorruptEnvelopeException(
        'Invalid UTF-8 byte sequence in state envelope',
        key: key,
        cause: error,
      );
    }
    return StateEnvelopeHeader.fromJsonString(
      jsonString,
      key: key,
      maxSupportedSchemaVersion: maxSupportedSchemaVersion,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is StateEnvelopeHeader &&
          other.schemaVersion == schemaVersion &&
          other.generation == generation &&
          other.updatedAtMicros == updatedAtMicros &&
          other.writerId == writerId &&
          _stringListEquals(other.attachments, attachments);

  @override
  int get hashCode => Object.hash(
        schemaVersion,
        generation,
        updatedAtMicros,
        writerId,
        Object.hashAll(attachments),
      );

  @override
  String toString() => 'StateEnvelopeHeader('
      'schemaVersion: $schemaVersion, '
      'gen: $generation, '
      'writerId: $writerId, '
      'updatedAtMicros: $updatedAtMicros, '
      'attachments: $attachments)';
}

bool _stringListEquals(List<String> a, List<String> b) {
  if (identical(a, b)) return true;
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// {@template extension_bridge.state_envelope_codec}
/// Stateless UTF-8 JSON codec that encodes and decodes [StateEnvelope]
/// instances for a specific model type [T].
/// {@endtemplate}
final class StateEnvelopeCodec<T> {
  /// {@macro extension_bridge.state_envelope_codec}
  const StateEnvelopeCodec({
    required this.encodePayload,
    required this.decodePayload,
    this.key,
    this.maxSupportedSchemaVersion,
  });

  /// Converts a typed model [T] into a JSON-encodable object (`Map`, `List`,
  /// primitive, or `null`).
  final Object? Function(T value) encodePayload;

  /// Reconstructs a typed model [T] from a decoded JSON value.
  final T Function(Object? json) decodePayload;

  /// Optional logical key attached to diagnostic exceptions.
  final String? key;

  /// Optional maximum `_schema_version` accepted by this codec.
  final int? maxSupportedSchemaVersion;

  static const _utf8Codec = Utf8Codec();
  static final _jsonUtf8Encoder = JsonUtf8Encoder();

  /// Encodes [envelope] to a compact JSON string.
  String encodeToString(StateEnvelope<T> envelope) =>
      jsonEncode(envelope.toJsonMap(encodePayload));

  /// Encodes [envelope] directly to a UTF-8 byte buffer (`Uint8List`) for
  /// atomic `.tmp` staging writes.
  Uint8List encodeToBytes(StateEnvelope<T> envelope) {
    final bytes = _jsonUtf8Encoder.convert(envelope.toJsonMap(encodePayload));
    return bytes is Uint8List ? bytes : Uint8List.fromList(bytes);
  }

  /// Decodes and validates a [StateEnvelope] from a JSON string.
  StateEnvelope<T> decodeFromString(String jsonString) {
    final Object? decoded;
    try {
      decoded = jsonDecode(jsonString);
    } on FormatException catch (error) {
      throw CorruptEnvelopeException(
        'Malformed JSON in state envelope',
        key: key,
        rawContent: jsonString,
        cause: error,
      );
    }
    if (decoded is! Map<String, Object?>) {
      throw CorruptEnvelopeException(
        'Expected JSON object at envelope root, found ${decoded.runtimeType}',
        key: key,
        rawContent: jsonString,
      );
    }
    return StateEnvelope<T>.fromJsonMap(
      decoded,
      payloadDecoder: decodePayload,
      key: key,
      maxSupportedSchemaVersion: maxSupportedSchemaVersion,
    );
  }

  /// Decodes and validates a [StateEnvelope] from raw UTF-8 bytes read from an
  /// APFS snapshot file.
  StateEnvelope<T> decodeFromBytes(Uint8List bytes) {
    final String jsonString;
    try {
      jsonString = _utf8Codec.decode(bytes);
    } on FormatException catch (error) {
      throw CorruptEnvelopeException(
        'Invalid UTF-8 byte sequence in state envelope',
        key: key,
        cause: error,
      );
    }
    return decodeFromString(jsonString);
  }
}
