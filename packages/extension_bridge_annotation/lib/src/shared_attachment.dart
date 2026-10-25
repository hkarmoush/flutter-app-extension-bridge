/// Strategy used when staging a [`@SharedAttachment`](SharedAttachment) file
/// into the App Group container's `blobs/` directory.
enum AttachmentCopyMode {
  /// Attempts a zero-copy APFS copy-on-write clone via
  /// `clonefile(src, dst, CLONE_NOOWNERCOPY)` (~0.3 ms, 0 extra disk bytes),
  /// falling back automatically to a chunked streaming copy on `EXDEV` or
  /// `ENOTSUP`.
  cloneOrStream,

  /// Always performs a chunked streaming file copy into `blobs/`.
  streamOnly,
}

/// {@template extension_bridge.shared_attachment}
/// Marks a `String` or `String?` file-path field on a `@BridgeModel` class as
/// a zero-copy APFS attachment managed in `<AppGroup>/extension_bridge/blobs/`.
///
/// When writing a state or enqueueing a queue item:
/// 1. The runtime clones the source file into `blobs/` using Darwin's
///    `clonefile(src, dst, CLONE_NOOWNERCOPY)` syscall (falling back to chunked
///    streaming copy across volumes).
/// 2. The JSON payload stores the container-relative blob path (`blobs/...`).
/// 3. On read/consume, the runtime resolves the relative blob path back to an
///    absolute path inside the current process's App Group mount point.
/// 4. For `@SharedQueue`, the blob is unlinked automatically when `ack()`
///    completes. For `@SharedState`, blobs from generations `< currentGen - 2`
///    are garbage-collected lazily on subsequent writes.
///
/// ### Example
/// ```dart
/// @BridgeModel()
/// class ShareInboxItem {
///   const ShareInboxItem({
///     required this.id,
///     @SharedAttachment() this.mediaPath,
///   });
///
///   final String id;
///   final String? mediaPath;
/// }
/// ```
/// {@endtemplate}
final class SharedAttachment {
  /// {@macro extension_bridge.shared_attachment}
  const SharedAttachment({
    this.copyMode = AttachmentCopyMode.cloneOrStream,
  });

  /// Copy strategy used to stage the attachment into `blobs/`.
  ///
  /// Defaults to [AttachmentCopyMode.cloneOrStream].
  final AttachmentCopyMode copyMode;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SharedAttachment && other.copyMode == copyMode;

  @override
  int get hashCode => copyMode.hashCode;

  @override
  String toString() => 'SharedAttachment(copyMode: $copyMode)';
}

/// Convenience constant for [`@SharedAttachment()`](SharedAttachment).
const sharedAttachment = SharedAttachment();
