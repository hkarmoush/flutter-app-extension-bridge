/// Zero-dependency annotations for declaring cross-process App Group schemas,
/// lock-free snapshots, Maildir queues, and `<notify.h>` signals with
/// `extension_bridge`.
library;

export 'src/app_group_schema.dart';
export 'src/bridge_model.dart';
export 'src/darwin_signal.dart';
export 'src/defaults.dart';
export 'src/live_activity_schema.dart';
export 'src/shared_attachment.dart';
export 'src/shared_queue.dart';
export 'src/shared_state.dart';
