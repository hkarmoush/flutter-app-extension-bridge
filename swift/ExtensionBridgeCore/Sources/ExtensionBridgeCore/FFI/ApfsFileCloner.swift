import Darwin
import Foundation

/// Strategy policy for staging `@SharedAttachment` files into `<AppGroup>/extension_bridge/blobs/`.
public enum AttachmentCopyMode: String, Sendable, Equatable, Codable {
    /// Attempts zero-copy APFS `clonefile(2)` (`CLONE_NOOWNERCOPY`) first and
    /// falls back to a chunked streaming copy on cross-volume `EXDEV`,
    /// `ENOTSUP`, or `ENOSYS`.
    case cloneOrStream

    /// Forces the chunked streaming copy path without invoking `clonefile(2)`.
    case streamOnly
}

/// Strategy used by ``ApfsFileCloner`` to materialize a blob inside the App
/// Group container.
public enum CloneStrategy: String, Sendable, Equatable, Codable {
    /// Zero-copy APFS Copy-on-Write inode clone (`clonefile(2)` with
    /// `CLONE_NOOWNERCOPY`).
    case apfsClonefile

    /// Chunked streaming file copy fallback used when `clonefile(2)` returns
    /// `EXDEV` (cross-volume), `ENOTSUP` (non-APFS filesystem), or `ENOSYS`.
    case streamingFallback
}

/// Telemetry and outcome descriptor returned by ``ApfsFileCloner/cloneFile(from:to:flags:copyMode:)``.
public struct ApfsCloneResult: Sendable, Equatable, CustomStringConvertible {
    /// Original source file path.
    public let sourcePath: String

    /// Materialized destination path inside `<AppGroup>/extension_bridge/blobs/`.
    public let destinationPath: String

    /// Whether the file was cloned via zero-copy APFS `clonefile(2)` or the
    /// chunked streaming copy fallback.
    public let strategy: CloneStrategy

    /// Wall-clock execution time in microseconds.
    public let elapsedMicros: Int64

    /// If ``strategy`` is ``CloneStrategy/streamingFallback``, the POSIX `errno`
    /// (`EXDEV`, `ENOTSUP`, `ENOSYS`) that triggered the fallback, or `nil` if
    /// ``AttachmentCopyMode/streamOnly`` was explicitly requested.
    public let fallbackErrno: Int32?

    /// Creates an ``ApfsCloneResult``.
    public init(
        sourcePath: String,
        destinationPath: String,
        strategy: CloneStrategy,
        elapsedMicros: Int64,
        fallbackErrno: Int32? = nil
    ) {
        self.sourcePath = sourcePath
        self.destinationPath = destinationPath
        self.strategy = strategy
        self.elapsedMicros = elapsedMicros
        self.fallbackErrno = fallbackErrno
    }

    public var description: String {
        let errnoSuffix = fallbackErrno.map { ", fallbackErrno: \($0)" } ?? ""
        return "ApfsCloneResult(strategy: \(strategy.rawValue), elapsedMicros: \(elapsedMicros), dst: \(destinationPath)\(errnoSuffix))"
    }
}

/// Signature for an injectable `clonefile(2)` syscall used in Tier 2
/// fault-injection tests.
public typealias ClonefileSyscallHook = @Sendable (
    _ sourcePath: String,
    _ destinationPath: String,
    _ flags: UInt32
) -> Int32

/// Zero-copy APFS `clonefile(2)` media staging engine with atomic `rename(2)`
/// placement and automatic cross-volume streaming fallback.
///
/// ### Why `clonefile(src, dst, CLONE_NOOWNERCOPY)`?
/// iOS Share and Widget Extensions run under a strict **16–30 MB Jetsam RAM
/// ceiling**. Cloning a 200 MB 4K video via Darwin's `clonefile(2)` creates a
/// Copy-on-Write APFS inode sharing the same physical data extents in
/// **~0.3 ms** with **0 bytes of additional disk usage** and **< 50 KB of RAM**.
/// Passing ``kClonefileNoOwnerCopyFlag`` prevents `EPERM` when cloning across
/// extension temporary directories and the shared App Group container.
public final class ApfsFileCloner: @unchecked Sendable {
    private let posix: DarwinPosix
    private let clonefileOverride: ClonefileSyscallHook?

    /// Buffer size in bytes (`64 KB` by default) used when falling back to a
    /// chunked streaming copy on `EXDEV` / `ENOTSUP`.
    public let chunkSizeBytes: Int

    private let lock = NSLock()
    private var stagingCounter: UInt64 = 0

    /// Creates an ``ApfsFileCloner``.
    public init(
        posix: DarwinPosix = .shared,
        clonefileOverride: ClonefileSyscallHook? = nil,
        chunkSizeBytes: Int = 64 * 1024
    ) {
        self.posix = posix
        self.clonefileOverride = clonefileOverride
        self.chunkSizeBytes = max(4096, chunkSizeBytes)
    }

    /// Synchronously clones `sourcePath` to `destinationPath` using APFS
    /// `clonefile(2)` (`CLONE_NOOWNERCOPY`), falling back to a chunked streaming
    /// copy if `clonefile(2)` returns `EXDEV`, `ENOTSUP`, or `ENOSYS` (or when
    /// `copyMode` is ``AttachmentCopyMode/streamOnly``).
    ///
    /// The file is staged to a hidden sibling `.tmp` path and committed via
    /// atomic POSIX `rename(2)` so readers of `destinationPath` never observe a
    /// partially written file.
    @discardableResult
    public func cloneFile(
        from sourcePath: String,
        to destinationPath: String,
        flags: UInt32 = kClonefileNoOwnerCopyFlag,
        copyMode: AttachmentCopyMode = .cloneOrStream
    ) throws -> ApfsCloneResult {
        let startTime = DispatchTime.now().uptimeNanoseconds

        let exists = sourcePath.withCString { Darwin.access($0, F_OK) == 0 }
        guard exists else {
            throw ExtensionBridgeError.attachmentCloneFailed(
                sourcePath: sourcePath,
                destinationPath: destinationPath,
                errno: ENOENT,
                message: "Source attachment file does not exist: \"\(sourcePath)\""
            )
        }

        let parentURL = URL(fileURLWithPath: destinationPath).deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: parentURL,
            withIntermediateDirectories: true
        )

        let stagingPath = buildStagingPath(for: destinationPath)
        _ = posix.unlinkFile(stagingPath)

        if copyMode == .streamOnly {
            try streamCopy(
                sourcePath: sourcePath,
                stagingPath: stagingPath,
                destinationPath: destinationPath
            )
            let elapsedUs = Int64((DispatchTime.now().uptimeNanoseconds - startTime) / 1_000)
            return ApfsCloneResult(
                sourcePath: sourcePath,
                destinationPath: destinationPath,
                strategy: .streamingFallback,
                elapsedMicros: elapsedUs,
                fallbackErrno: nil
            )
        }

        let errno: Int32
        if let hook = clonefileOverride {
            errno = hook(sourcePath, stagingPath, flags)
        } else {
            errno = posix.cloneFile(source: sourcePath, destination: stagingPath, flags: flags)
        }

        if errno == 0 {
            let renameErr = posix.renameFile(from: stagingPath, to: destinationPath)
            if renameErr != 0 {
                _ = posix.unlinkFile(stagingPath)
                throw ExtensionBridgeError.attachmentCloneFailed(
                    sourcePath: sourcePath,
                    destinationPath: destinationPath,
                    errno: renameErr,
                    message: "Atomic rename after clonefile(2) failed with errno \(renameErr)"
                )
            }
            let elapsedUs = Int64((DispatchTime.now().uptimeNanoseconds - startTime) / 1_000)
            return ApfsCloneResult(
                sourcePath: sourcePath,
                destinationPath: destinationPath,
                strategy: .apfsClonefile,
                elapsedMicros: elapsedUs,
                fallbackErrno: nil
            )
        }

        _ = posix.unlinkFile(stagingPath)

        guard Self.shouldFallbackToStreaming(errno) else {
            throw ExtensionBridgeError.attachmentCloneFailed(
                sourcePath: sourcePath,
                destinationPath: destinationPath,
                errno: errno,
                message: "APFS clonefile(2) failed with unrecoverable errno \(errno)"
            )
        }

        try streamCopy(
            sourcePath: sourcePath,
            stagingPath: stagingPath,
            destinationPath: destinationPath
        )
        let elapsedUs = Int64((DispatchTime.now().uptimeNanoseconds - startTime) / 1_000)
        return ApfsCloneResult(
            sourcePath: sourcePath,
            destinationPath: destinationPath,
            strategy: .streamingFallback,
            elapsedMicros: elapsedUs,
            fallbackErrno: errno
        )
    }

    private static func shouldFallbackToStreaming(_ errno: Int32) -> Bool {
        errno == EXDEV || errno == ENOTSUP || errno == ENOSYS
    }

    private func buildStagingPath(for destinationPath: String) -> String {
        let url = URL(fileURLWithPath: destinationPath)
        let dir = url.deletingLastPathComponent().path
        let base = url.lastPathComponent
        lock.lock()
        stagingCounter &+= 1
        let seq = stagingCounter
        lock.unlock()
        let nonce = String(UInt32.random(in: 0...0x7FFF_FFFF), radix: 16)
        return "\(dir)/.\(base).tmp.\(seq).\(nonce)"
    }

    private func streamCopy(
        sourcePath: String,
        stagingPath: String,
        destinationPath: String
    ) throws {
        let readFd = sourcePath.withCString { Darwin.open($0, O_RDONLY | O_CLOEXEC) }
        guard readFd >= 0 else {
            let err = Darwin.errno
            throw ExtensionBridgeError.attachmentCloneFailed(
                sourcePath: sourcePath,
                destinationPath: destinationPath,
                errno: err,
                message: "Failed to open source file for streaming fallback (errno \(err))"
            )
        }

        let writeFd = stagingPath.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, mode_t(0o644))
        }
        guard writeFd >= 0 else {
            let err = Darwin.errno
            _ = Darwin.close(readFd)
            throw ExtensionBridgeError.attachmentCloneFailed(
                sourcePath: sourcePath,
                destinationPath: destinationPath,
                errno: err,
                message: "Failed to open staging file for streaming fallback (errno \(err))"
            )
        }

        do {
            var buffer = [UInt8](repeating: 0, count: chunkSizeBytes)
            while true {
                let bytesRead = buffer.withUnsafeMutableBytes { rawBuf -> Int in
                    Darwin.read(readFd, rawBuf.baseAddress!, chunkSizeBytes)
                }
                if bytesRead < 0 {
                    let err = Darwin.errno
                    if err == EINTR { continue }
                    throw ExtensionBridgeError.attachmentCloneFailed(
                        sourcePath: sourcePath,
                        destinationPath: destinationPath,
                        errno: err,
                        message: "Streaming fallback read(2) failed with errno \(err)"
                    )
                }
                if bytesRead == 0 { break }

                var offset = 0
                while offset < bytesRead {
                    let written = buffer.withUnsafeBytes { rawBuf -> Int in
                        Darwin.write(writeFd, rawBuf.baseAddress!.advanced(by: offset), bytesRead - offset)
                    }
                    if written < 0 {
                        let err = Darwin.errno
                        if err == EINTR { continue }
                        throw ExtensionBridgeError.attachmentCloneFailed(
                            sourcePath: sourcePath,
                            destinationPath: destinationPath,
                            errno: err,
                            message: "Streaming fallback write(2) failed with errno \(err)"
                        )
                    }
                    offset += written
                }
            }

            if Darwin.fsync(writeFd) != 0 {
                let err = Darwin.errno
                throw ExtensionBridgeError.attachmentCloneFailed(
                    sourcePath: sourcePath,
                    destinationPath: destinationPath,
                    errno: err,
                    message: "Streaming fallback fsync(2) failed with errno \(err)"
                )
            }

            _ = Darwin.close(writeFd)
            _ = Darwin.close(readFd)

            let renameErr = posix.renameFile(from: stagingPath, to: destinationPath)
            if renameErr != 0 {
                _ = posix.unlinkFile(stagingPath)
                throw ExtensionBridgeError.attachmentCloneFailed(
                    sourcePath: sourcePath,
                    destinationPath: destinationPath,
                    errno: renameErr,
                    message: "Atomic rename after streaming fallback failed with errno \(renameErr)"
                )
            }
        } catch {
            _ = Darwin.close(writeFd)
            _ = Darwin.close(readFd)
            _ = posix.unlinkFile(stagingPath)
            throw error
        }
    }
}
