import Darwin
import Darwin.sys.clonefile
import Foundation

/// Flag passed to `clonefile(2)` (`CLONE_NOOWNERCOPY = 0x0002`) so that cloning
/// a file from an extension's temporary directory into the shared App Group
/// container does not attempt to copy ownership metadata (`EPERM`).
public let kClonefileNoOwnerCopyFlag: UInt32 = UInt32(CLONE_NOOWNERCOPY)

/// Direct Darwin POSIX syscall wrapper used by `ExtensionBridgeCore` to avoid
/// `NSFileCoordinator` and kernel file locks (`0xdead10cc` immunity).
///
/// Every file operation in the shared App Group container uses direct POSIX
/// descriptors (`open`, `read`, `write`, `fsync`, `close`, `rename`, `unlink`,
/// `symlink`, `readlink`, `clonefile`, `kill`).
public struct DarwinPosix: Sendable {
    /// Default shared instance backed by the Darwin kernel (`libSystem.B.dylib`).
    public static let shared = DarwinPosix()

    /// Creates a ``DarwinPosix`` instance.
    public init() {}

    /// Returns the calling process's OS PID (`getpid()`).
    @inlinable
    public func currentPid() -> Int32 {
        Darwin.getpid()
    }

    /// Probes whether an OS process with `pid` is still alive in the kernel
    /// process table via `kill(pid, 0)`.
    ///
    /// - Returns `true` if `kill(pid, 0) == 0` or `errno == EPERM` (alive in
    ///   another sandbox/UID).
    /// - Returns `false` if `pid <= 0` or `errno == ESRCH` (no such process).
    public func isProcessAlive(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        let res = Darwin.kill(pid, 0)
        if res == 0 {
            return true
        }
        return Darwin.errno != ESRCH
    }

    /// Atomically creates a symbolic link at `linkPath` pointing to `target`.
    ///
    /// - Returns `0` on success, or the positive POSIX `errno` (`EEXIST`, etc.)
    ///   on failure.
    public func createSymlink(target: String, linkPath: String) -> Int32 {
        let rc = target.withCString { targetPtr in
            linkPath.withCString { linkPtr in
                Darwin.symlink(targetPtr, linkPtr)
            }
        }
        return rc == 0 ? 0 : Darwin.errno
    }

    /// Reads the symbolic link target at `linkPath`, returning `nil` if the
    /// symlink does not exist (`ENOENT`) or cannot be read.
    public func readSymlink(_ linkPath: String) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let len = linkPath.withCString { linkPtr in
            Darwin.readlink(linkPtr, &buffer, Int(PATH_MAX))
        }
        guard len >= 0 else { return nil }
        let bytes = buffer.prefix(len).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    /// Atomically renames `sourcePath` over `destinationPath` via POSIX
    /// `rename(2)`.
    ///
    /// - Returns `0` on success, or the positive POSIX `errno` on failure.
    public func renameFile(from sourcePath: String, to destinationPath: String) -> Int32 {
        let rc = sourcePath.withCString { srcPtr in
            destinationPath.withCString { dstPtr in
                Darwin.rename(srcPtr, dstPtr)
            }
        }
        return rc == 0 ? 0 : Darwin.errno
    }

    /// Unlinks the directory entry at `path` via POSIX `unlink(2)`.
    ///
    /// - Returns `0` on success, or the positive POSIX `errno` on failure.
    @discardableResult
    public func unlinkFile(_ path: String) -> Int32 {
        let rc = path.withCString { ptr in
            Darwin.unlink(ptr)
        }
        return rc == 0 ? 0 : Darwin.errno
    }

    /// Clones `sourcePath` to `destinationPath` using APFS Copy-on-Write
    /// `clonefile(2)`.
    ///
    /// - Returns `0` on success, or the positive POSIX `errno` (`EXDEV`,
    ///   `ENOTSUP`, `ENOSYS`, `ENOENT`, etc.) on failure.
    public func cloneFile(
        source sourcePath: String,
        destination destinationPath: String,
        flags: UInt32 = kClonefileNoOwnerCopyFlag
    ) -> Int32 {
        let rc = sourcePath.withCString { srcPtr in
            destinationPath.withCString { dstPtr in
                Darwin.clonefile(srcPtr, dstPtr, flags)
            }
        }
        return rc == 0 ? 0 : Darwin.errno
    }

    /// Writes `data` to a new or truncated file at `path`, flushes kernel
    /// buffers via `fsync(2)`, and closes the descriptor—without acquiring any
    /// advisory file lock or `NSFileCoordinator`.
    public func writeAndFlushFile(atPath path: String, data: Data) throws {
        let fd = path.withCString { ptr in
            Darwin.open(ptr, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, mode_t(0o644))
        }
        guard fd >= 0 else {
            let err = Darwin.errno
            throw ExtensionBridgeError.storageIo(
                path: path,
                errno: err,
                message: "open(2) for staging write failed with errno \(err)"
            )
        }

        do {
            try data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                var offset = 0
                let total = rawBuffer.count
                while offset < total {
                    let written = Darwin.write(fd, baseAddress.advanced(by: offset), total - offset)
                    if written < 0 {
                        let err = Darwin.errno
                        if err == EINTR { continue }
                        throw ExtensionBridgeError.storageIo(
                            path: path,
                            errno: err,
                            message: "write(2) failed with errno \(err)"
                        )
                    }
                    offset += written
                }
            }

            if Darwin.fsync(fd) != 0 {
                let err = Darwin.errno
                throw ExtensionBridgeError.storageIo(
                    path: path,
                    errno: err,
                    message: "fsync(2) failed with errno \(err)"
                )
            }
            _ = Darwin.close(fd)
        } catch {
            _ = Darwin.close(fd)
            _ = unlinkFile(path)
            throw error
        }
    }

    /// Performs a zero-lock POSIX snapshot read of `path`, returning `nil` if
    /// the file does not exist (`ENOENT`).
    public func readFileData(atPath path: String) throws -> Data? {
        let fd = path.withCString { ptr in
            Darwin.open(ptr, O_RDONLY | O_CLOEXEC)
        }
        if fd < 0 {
            let err = Darwin.errno
            if err == ENOENT {
                return nil
            }
            throw ExtensionBridgeError.storageIo(
                path: path,
                errno: err,
                message: "open(2) for snapshot read failed with errno \(err)"
            )
        }
        defer { _ = Darwin.close(fd) }

        var st = Darwin.stat()
        if Darwin.fstat(fd, &st) != 0 {
            let err = Darwin.errno
            throw ExtensionBridgeError.storageIo(
                path: path,
                errno: err,
                message: "fstat(2) failed with errno \(err)"
            )
        }

        let size = max(0, Int(st.st_size))
        if size == 0 {
            return Data()
        }

        var buffer = Data(count: size)
        var totalRead = 0
        try buffer.withUnsafeMutableBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            while totalRead < size {
                let n = Darwin.read(fd, baseAddress.advanced(by: totalRead), size - totalRead)
                if n < 0 {
                    let err = Darwin.errno
                    if err == EINTR { continue }
                    throw ExtensionBridgeError.storageIo(
                        path: path,
                        errno: err,
                        message: "read(2) failed with errno \(err)"
                    )
                }
                if n == 0 { break }
                totalRead += n
            }
        }
        if totalRead < size {
            buffer.removeSubrange(totalRead..<size)
        }
        return buffer
    }
}
