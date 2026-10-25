import 'package:extension_bridge_annotation/extension_bridge_annotation.dart';
import 'package:test/test.dart';

final class _SampleAttributes {}

final class _SampleContentState {}

void main() {
  group('AppGroupSchema', () {
    test('stores configuration and supports value equality', () {
      const a = AppGroupSchema(
        groupId: 'group.com.example.pulsehub',
        swiftPackageName: 'PulseHubExtensionKit',
        schemaVersion: 2,
        notificationPrefix: 'com.example.pulsehub.eb',
      );
      const b = AppGroupSchema(
        groupId: 'group.com.example.pulsehub',
        swiftPackageName: 'PulseHubExtensionKit',
        schemaVersion: 2,
        notificationPrefix: 'com.example.pulsehub.eb',
      );
      const c = AppGroupSchema(groupId: 'group.com.example.other');

      expect(a.groupId, 'group.com.example.pulsehub');
      expect(a.swiftPackageName, 'PulseHubExtensionKit');
      expect(a.schemaVersion, 2);
      expect(a.notificationPrefix, 'com.example.pulsehub.eb');
      expect(c.schemaVersion, 1);
      expect(c.swiftPackageName, isNull);
      expect(c.notificationPrefix, isNull);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
      expect(a.toString(), contains('group.com.example.pulsehub'));
    });
  });

  group('SharedState', () {
    test('supports widget/control reload lists and value equality', () {
      const a = SharedState(
        key: 'now_playing',
        reloadWidgets: ['NowPlayingWidget', 'MiniPlayerWidget'],
        reloadControls: ['PlaybackControl'],
        notificationName: 'com.example.state.now_playing',
      );
      const b = SharedState(
        key: 'now_playing',
        reloadWidgets: ['NowPlayingWidget', 'MiniPlayerWidget'],
        reloadControls: ['PlaybackControl'],
        notificationName: 'com.example.state.now_playing',
      );
      const c = SharedState(
        key: 'now_playing',
        reloadWidgets: ['DifferentWidget'],
      );
      const empty = SharedState();

      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
      expect(a, isNot(equals(empty)));
      expect(empty.key, isNull);
      expect(empty.reloadWidgets, isNull);
      expect(empty.reloadControls, isNull);
      expect(a.toString(), contains('now_playing'));
    });
  });

  group('SharedQueue', () {
    test('defaults maxItems to 256 and supports value equality', () {
      const a = SharedQueue(
        key: 'inbox',
        maxItems: 64,
        notificationName: 'com.example.queue.inbox',
      );
      const b = SharedQueue(
        key: 'inbox',
        maxItems: 64,
        notificationName: 'com.example.queue.inbox',
      );
      const defaults = SharedQueue();

      expect(defaults.maxItems, 256);
      expect(defaults.key, isNull);
      expect(defaults.notificationName, isNull);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(defaults)));
      expect(a.toString(), contains('maxItems: 64'));
    });
  });

  group('DarwinSignal', () {
    test('stores optional name and supports value equality', () {
      const a = DarwinSignal(name: 'skip_next');
      const b = DarwinSignal(name: 'skip_next');
      const unnamed = DarwinSignal();

      expect(a.name, 'skip_next');
      expect(unnamed.name, isNull);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(unnamed)));
      expect(a.toString(), 'DarwinSignal(name: skip_next)');
    });
  });

  group('LiveActivitySchema', () {
    test('stores attributes and contentState types', () {
      const a = LiveActivitySchema(
        attributes: _SampleAttributes,
        contentState: _SampleContentState,
        key: 'delivery',
      );
      const b = LiveActivitySchema(
        attributes: _SampleAttributes,
        contentState: _SampleContentState,
        key: 'delivery',
      );
      const c = LiveActivitySchema(
        attributes: _SampleAttributes,
        contentState: _SampleContentState,
      );

      expect(a.attributes, _SampleAttributes);
      expect(a.contentState, _SampleContentState);
      expect(a.key, 'delivery');
      expect(c.key, isNull);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
      expect(a.toString(), contains('delivery'));
    });
  });

  group('BridgeModel & SharedAttachment & Defaults', () {
    test('BridgeModel defaults discriminatorKey to _type', () {
      const custom = BridgeModel(discriminatorKey: 'kind');
      expect(bridgeModel.discriminatorKey, '_type');
      expect(bridgeModel, equals(const BridgeModel()));
      expect(bridgeModel.hashCode, equals(const BridgeModel().hashCode));
      expect(custom, isNot(equals(bridgeModel)));
      expect(custom.toString(), 'BridgeModel(discriminatorKey: kind)');
    });

    test('SharedAttachment defaults to cloneOrStream', () {
      const streamOnly = SharedAttachment(
        copyMode: AttachmentCopyMode.streamOnly,
      );
      expect(sharedAttachment.copyMode, AttachmentCopyMode.cloneOrStream);
      expect(sharedAttachment, equals(const SharedAttachment()));
      expect(
        sharedAttachment.hashCode,
        equals(const SharedAttachment().hashCode),
      );
      expect(streamOnly, isNot(equals(sharedAttachment)));
      expect(
        streamOnly.toString(),
        'SharedAttachment(copyMode: AttachmentCopyMode.streamOnly)',
      );
    });

    test('Default and DefaultEnumValue preserve values and equality', () {
      const defInt = Default<int>(42);
      const defIntSame = Default<int>(42);
      const defOther = Default<int>(7);

      expect(defInt.value, 42);
      expect(defInt, equals(defIntSame));
      expect(defInt.hashCode, equals(defIntSame.hashCode));
      expect(defInt, isNot(equals(defOther)));
      expect(defInt.toString(), 'Default(42)');

      expect(defaultEnumValue, equals(const DefaultEnumValue()));
      expect(
        defaultEnumValue.hashCode,
        equals(const DefaultEnumValue().hashCode),
      );
      expect(defaultEnumValue.toString(), 'DefaultEnumValue()');
    });
  });
}
