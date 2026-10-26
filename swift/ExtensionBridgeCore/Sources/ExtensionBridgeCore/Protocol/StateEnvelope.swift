import Foundation

/// Magic wire identifier (`"EB01"`) stored in the `"_eb_magic"` field of every
/// `extension_bridge` JSON envelope on disk.
public let kStateEnvelopeMagic = "EB01"

/// Immutable, versioned wire envelope wrapping a serialized `@SharedState` or
/// `@SharedQueue` `payload` inside `<AppGroupContainer>/extension_bridge/`.
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
public struct StateEnvelope<T: Sendable>: Sendable {
    /// Wire magic string (`"EB01"`).
    public let magic: String

    /// Schema version (`_schema_version`) declared on `@AppGroupSchema`.
    public let schemaVersion: Int

    /// Monotonic 64-bit generation counter (`_gen`) incremented on every atomic
    /// CAS commit.
    public let generation: Int64

    /// UTC timestamp in microseconds (`_updated_at_us`) when this snapshot was
    /// committed.
    public let updatedAtMicros: Int64

    /// 16-bit logical writer identifier (`_writer_id`) of the process/instance
    /// that committed this snapshot.
    public let writerId: UInt16

    /// Strongly-typed decoded model payload.
    public let payload: T

    /// Optional list of container-relative blob paths (`blobs/...`) referenced
    /// by `@SharedAttachment` fields in `payload`.
    public let attachments: [String]

    /// Creates a ``StateEnvelope``.
    public init(
        schemaVersion: Int,
        generation: Int64,
        updatedAtMicros: Int64,
        writerId: UInt16,
        payload: T,
        attachments: [String] = [],
        magic: String = kStateEnvelopeMagic
    ) {
        precondition(schemaVersion >= 1, "schemaVersion must be >= 1")
        precondition(generation >= 0, "generation must be >= 0")
        precondition(updatedAtMicros >= 0, "updatedAtMicros must be >= 0")
        self.magic = magic
        self.schemaVersion = schemaVersion
        self.generation = generation
        self.updatedAtMicros = updatedAtMicros
        self.writerId = writerId
        self.payload = payload
        self.attachments = attachments
    }

    /// Converts this envelope's metadata into a 64-bit ``KernelStateRegister``
    /// suitable for `notify_set_state`.
    public func toKernelStateRegister() -> KernelStateRegister {
        KernelStateRegister.pack(
            writerId: writerId,
            generation: UInt64(bitPattern: generation)
        )
    }
}

extension StateEnvelope: Equatable where T: Equatable {}
extension StateEnvelope: Hashable where T: Hashable {}

/// Lightweight header-only view of a ``StateEnvelope`` used during cold-start
/// register seeding and CAS generation checks without decoding the payload.
public struct StateEnvelopeHeader: Sendable, Equatable, Hashable {
    /// Wire magic string (`_eb_magic`).
    public let magic: String

    /// Schema version (`_schema_version`).
    public let schemaVersion: Int

    /// Monotonic 64-bit generation (`_gen`).
    public let generation: Int64

    /// Commit timestamp in UTC microseconds (`_updated_at_us`).
    public let updatedAtMicros: Int64

    /// 16-bit logical writer ID (`_writer_id`).
    public let writerId: UInt16

    /// Container-relative blob paths (`_attachments`).
    public let attachments: [String]

    /// Creates a ``StateEnvelopeHeader``.
    public init(
        schemaVersion: Int,
        generation: Int64,
        updatedAtMicros: Int64,
        writerId: UInt16,
        attachments: [String] = [],
        magic: String = kStateEnvelopeMagic
    ) {
        self.magic = magic
        self.schemaVersion = schemaVersion
        self.generation = generation
        self.updatedAtMicros = updatedAtMicros
        self.writerId = writerId
        self.attachments = attachments
    }

    /// Packs `writerId` and `generation` into a ``KernelStateRegister``.
    public func toKernelStateRegister() -> KernelStateRegister {
        KernelStateRegister.pack(
            writerId: writerId,
            generation: UInt64(bitPattern: generation)
        )
    }

    /// Decodes and validates only the envelope header metadata from raw UTF-8
    /// `data`.
    public static func fromData(
        _ data: Data,
        key: String? = nil,
        maxSupportedSchemaVersion: Int? = nil
    ) throws -> StateEnvelopeHeader {
        let jsonObject: Any
        do {
            jsonObject = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        } catch {
            throw ExtensionBridgeError.corruptEnvelope(
                key: key,
                message: "Malformed JSON in state envelope: \(error)"
            )
        }
        guard let dict = jsonObject as? [String: Any] else {
            throw ExtensionBridgeError.corruptEnvelope(
                key: key,
                message: "Expected JSON object at envelope root"
            )
        }
        return try fromDictionary(
            dict,
            key: key,
            maxSupportedSchemaVersion: maxSupportedSchemaVersion
        )
    }

    /// Decodes and validates only the envelope header metadata from a JSON string.
    public static func fromJSONString(
        _ jsonString: String,
        key: String? = nil,
        maxSupportedSchemaVersion: Int? = nil
    ) throws -> StateEnvelopeHeader {
        guard let data = jsonString.data(using: .utf8) else {
            throw ExtensionBridgeError.corruptEnvelope(
                key: key,
                message: "Invalid UTF-8 string in state envelope"
            )
        }
        return try fromData(
            data,
            key: key,
            maxSupportedSchemaVersion: maxSupportedSchemaVersion
        )
    }

    internal static func fromDictionary(
        _ dict: [String: Any],
        key: String?,
        maxSupportedSchemaVersion: Int?
    ) throws -> StateEnvelopeHeader {
        guard let magic = dict["_eb_magic"] as? String, magic == kStateEnvelopeMagic else {
            let found = dict["_eb_magic"].map { "\($0)" } ?? "nil"
            throw ExtensionBridgeError.corruptEnvelope(
                key: key,
                message: "Expected _eb_magic \"\(kStateEnvelopeMagic)\", found \"\(found)\""
            )
        }

        guard let schemaVersion = Self.extractStrictInt(dict["_schema_version"]),
              schemaVersion >= 1
        else {
            throw ExtensionBridgeError.corruptEnvelope(
                key: key,
                message: "Invalid or missing integer _schema_version"
            )
        }

        if let maxVer = maxSupportedSchemaVersion, schemaVersion > maxVer {
            throw ExtensionBridgeError.unsupportedSchemaVersion(
                key: key,
                foundVersion: schemaVersion,
                maxSupportedVersion: maxVer
            )
        }

        guard let generation = Self.extractStrictInt64(dict["_gen"]),
              generation >= 0
        else {
            throw ExtensionBridgeError.corruptEnvelope(
                key: key,
                message: "Invalid or missing non-negative integer _gen"
            )
        }

        guard let updatedAtMicros = Self.extractStrictInt64(dict["_updated_at_us"]),
              updatedAtMicros >= 0
        else {
            throw ExtensionBridgeError.corruptEnvelope(
                key: key,
                message: "Invalid or missing non-negative integer _updated_at_us"
            )
        }

        guard let writerIdInt = Self.extractStrictInt(dict["_writer_id"]),
              writerIdInt >= 0 && writerIdInt <= 0xFFFF
        else {
            throw ExtensionBridgeError.corruptEnvelope(
                key: key,
                message: "Invalid or missing 16-bit _writer_id"
            )
        }

        guard dict.index(forKey: "payload") != nil else {
            throw ExtensionBridgeError.corruptEnvelope(
                key: key,
                message: "Envelope is missing required \"payload\" key"
            )
        }

        var attachments: [String] = []
        if let rawAttachments = dict["_attachments"], !(rawAttachments is NSNull) {
            guard let list = rawAttachments as? [Any] else {
                throw ExtensionBridgeError.corruptEnvelope(
                    key: key,
                    message: "Expected \"_attachments\" to be a List"
                )
            }
            for item in list {
                guard let str = item as? String else {
                    throw ExtensionBridgeError.corruptEnvelope(
                        key: key,
                        message: "Expected string path in \"_attachments\""
                    )
                }
                attachments.append(str)
            }
        }

        return StateEnvelopeHeader(
            schemaVersion: schemaVersion,
            generation: generation,
            updatedAtMicros: updatedAtMicros,
            writerId: UInt16(writerIdInt),
            attachments: attachments,
            magic: magic
        )
    }

    private static func extractStrictInt(_ value: Any?) -> Int? {
        guard let num = value as? NSNumber else { return nil }
        if CFGetTypeID(num) == CFBooleanGetTypeID() { return nil }
        let d = num.doubleValue
        guard d.rounded() == d else { return nil }
        return num.intValue
    }

    private static func extractStrictInt64(_ value: Any?) -> Int64? {
        guard let num = value as? NSNumber else { return nil }
        if CFGetTypeID(num) == CFBooleanGetTypeID() { return nil }
        let d = num.doubleValue
        guard d.rounded() == d else { return nil }
        return num.int64Value
    }
}

/// Internal Codable wire container used to decode/encode the strongly-typed
/// `payload` after ``StateEnvelopeHeader`` has validated the envelope headers.
private struct _CodableEnvelopePayloadBox<P: Codable>: Codable {
    let _eb_magic: String
    let _schema_version: Int
    let _gen: Int64
    let _updated_at_us: Int64
    let _writer_id: UInt16
    let _attachments: [String]?
    let payload: P
}

/// Stateless UTF-8 JSON codec that encodes and decodes ``StateEnvelope``
/// instances for a model type `T`.
public struct StateEnvelopeCodec<T: Sendable>: Sendable {
    private let encodeFn: @Sendable (StateEnvelope<T>) throws -> Data
    private let decodeFn: @Sendable (Data, String?, Int?) throws -> StateEnvelope<T>

    /// Optional logical key attached to diagnostic errors.
    public let key: String?

    /// Optional maximum `_schema_version` accepted by this codec.
    public let maxSupportedSchemaVersion: Int?

    /// Creates a ``StateEnvelopeCodec`` with custom payload encoder and decoder
    /// closures.
    public init(
        key: String? = nil,
        maxSupportedSchemaVersion: Int? = nil,
        encodePayload: @escaping @Sendable (T) throws -> Data,
        decodePayload: @escaping @Sendable (Data) throws -> T
    ) {
        self.key = key
        self.maxSupportedSchemaVersion = maxSupportedSchemaVersion
        self.encodeFn = { envelope in
            let payloadData = try encodePayload(envelope.payload)
            let payloadObj = try JSONSerialization.jsonObject(
                with: payloadData,
                options: [.fragmentsAllowed]
            )
            var map: [String: Any] = [
                "_eb_magic": envelope.magic,
                "_schema_version": envelope.schemaVersion,
                "_gen": envelope.generation,
                "_updated_at_us": envelope.updatedAtMicros,
                "_writer_id": Int(envelope.writerId),
                "payload": payloadObj,
            ]
            if !envelope.attachments.isEmpty {
                map["_attachments"] = envelope.attachments
            }
            return try JSONSerialization.data(withJSONObject: map, options: [])
        }
        self.decodeFn = { data, key, maxVer in
            guard let jsonObject = try? JSONSerialization.jsonObject(
                with: data,
                options: [.fragmentsAllowed]
            ),
                let dict = jsonObject as? [String: Any]
            else {
                throw ExtensionBridgeError.corruptEnvelope(
                    key: key,
                    message: "Malformed JSON object at state envelope root"
                )
            }
            let header = try StateEnvelopeHeader.fromDictionary(
                dict,
                key: key,
                maxSupportedSchemaVersion: maxVer
            )
            let rawPayload = dict["payload"] ?? NSNull()
            let payloadData: Data
            if rawPayload is NSNull {
                payloadData = Data("null".utf8)
            } else if JSONSerialization.isValidJSONObject(rawPayload) {
                payloadData = try JSONSerialization.data(withJSONObject: rawPayload, options: [])
            } else {
                payloadData = try JSONSerialization.data(
                    withJSONObject: [rawPayload],
                    options: []
                )
                // Strip outer '[' and ']' for primitive fragments
                let stripped = payloadData.dropFirst().dropLast()
                return try Self.decodeWithHeader(
                    header: header,
                    payloadData: Data(stripped),
                    key: key,
                    decodePayload: decodePayload
                )
            }
            return try Self.decodeWithHeader(
                header: header,
                payloadData: payloadData,
                key: key,
                decodePayload: decodePayload
            )
        }
    }

    /// Creates a ``StateEnvelopeCodec`` for any `Codable & Sendable` model type `T`.
    public static func codable(
        _ type: T.Type = T.self,
        key: String? = nil,
        maxSupportedSchemaVersion: Int? = nil
    ) -> StateEnvelopeCodec<T> where T: Codable {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        return StateEnvelopeCodec<T>(
            key: key,
            maxSupportedSchemaVersion: maxSupportedSchemaVersion,
            encodePayload: { value in
                try encoder.encode(value)
            },
            decodePayload: { data in
                try decoder.decode(T.self, from: data)
            }
        )
    }

    private static func decodeWithHeader(
        header: StateEnvelopeHeader,
        payloadData: Data,
        key: String?,
        decodePayload: @Sendable (Data) throws -> T
    ) throws -> StateEnvelope<T> {
        let decodedPayload: T
        do {
            decodedPayload = try decodePayload(payloadData)
        } catch let error as ExtensionBridgeError {
            throw error
        } catch {
            throw ExtensionBridgeError.corruptEnvelope(
                key: key,
                message: "Failed to decode envelope payload: \(error)"
            )
        }
        return StateEnvelope<T>(
            schemaVersion: header.schemaVersion,
            generation: header.generation,
            updatedAtMicros: header.updatedAtMicros,
            writerId: header.writerId,
            payload: decodedPayload,
            attachments: header.attachments,
            magic: header.magic
        )
    }

    /// Encodes `envelope` directly to a UTF-8 `Data` buffer for atomic `.tmp`
    /// staging writes.
    public func encodeToData(_ envelope: StateEnvelope<T>) throws -> Data {
        try encodeFn(envelope)
    }

    /// Encodes `envelope` to a compact UTF-8 JSON `String`.
    public func encodeToString(_ envelope: StateEnvelope<T>) throws -> String {
        let data = try encodeToData(envelope)
        return String(decoding: data, as: UTF8.self)
    }

    /// Decodes and validates a ``StateEnvelope`` from raw UTF-8 `data` read
    /// from an APFS snapshot file.
    public func decodeFromData(_ data: Data) throws -> StateEnvelope<T> {
        // Verify valid UTF-8 first
        guard String(data: data, encoding: .utf8) != nil else {
            throw ExtensionBridgeError.corruptEnvelope(
                key: key,
                message: "Invalid UTF-8 byte sequence in state envelope"
            )
        }
        return try decodeFn(data, key, maxSupportedSchemaVersion)
    }

    /// Decodes and validates a ``StateEnvelope`` from a JSON string.
    public func decodeFromString(_ jsonString: String) throws -> StateEnvelope<T> {
        guard let data = jsonString.data(using: .utf8) else {
            throw ExtensionBridgeError.corruptEnvelope(
                key: key,
                message: "Invalid UTF-8 string in state envelope"
            )
        }
        return try decodeFromData(data)
    }
}
