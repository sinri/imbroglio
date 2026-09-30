import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:imbroglio/src/services/network.dart';
import 'package:imbroglio/src/core/diagnostics.dart';
import 'package:imbroglio/src/core/models.dart';
import 'package:imbroglio/src/services/store.dart';
import 'package:imbroglio/src/services/workspace.dart';
import 'sync_test.dart' show FakeRpc;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'OS offline gates polling and manual IM calls; manual recovery resumes',
    () async {
      final w = Workspace()..store = Store(NativeDatabase.memory());
      await w.store.init();
      addTearDown(w.close);
      const a = AccountRef(id: 'a', platform: 'feishu', label: 'A');
      w.accounts = [a];
      var calls = 0;
      w.clients[a.id] = FakeRpc((_, _) {
        calls++;
        return {'items': [], 'complete': true, 'hasMore': false};
      });
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      var online = false;
      messenger.setMockMethodCallHandler(
        NetworkMonitor.channel,
        (_) async => online,
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(NetworkMonitor.channel, null),
      );
      await w.networkMonitor.start(w.updateNetworkAvailability);
      expect(w.offline, true);
      w.tick();
      await expectLater(w.client(a), throwsA(isA<AppFailure>()));
      await w.retryNetwork();
      expect(calls, 0);
      expect(w.offline, true);
      online = true;
      await w.retryNetwork();
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(w.offline, false);
      expect(calls, greaterThan(0));
    },
  );

  test(
    'native network changes automatically pause and resume workspace',
    () async {
      final monitor = NetworkMonitor();
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(
        NetworkMonitor.channel,
        (_) async => false,
      );
      addTearDown(() {
        monitor.dispose();
        messenger.setMockMethodCallHandler(NetworkMonitor.channel, null);
      });
      final states = <bool>[];
      await monitor.start(states.add);
      await messenger.handlePlatformMessage(
        'imbroglio/network',
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall('changed', true),
        ),
        (_) {},
      );
      expect(states, [false, true]);
    },
  );

  test('DNS and transport timeouts are transient, permissions are not', () {
    expect(
      transientNetworkFailure('dial tcp: lookup open.feishu.cn: no such host'),
      true,
    );
    expect(transientNetworkFailure('dial tcp: lookup host: i/o timeout'), true);
    expect(transientNetworkFailure('missing required scope im:chat'), false);
    expect(transientNetworkFailure('field validation failed'), false);
  });
  test(
    'offline account backs off with one probe then resumes without losing checkpoint',
    () async {
      final w = Workspace()..store = Store(NativeDatabase.memory());
      await w.store.init();
      addTearDown(w.close);
      const a = AccountRef(id: 'a', platform: 'feishu', label: 'A');
      const b = AccountRef(id: 'b', platform: 'dingtalk', label: 'B');
      w.accounts = [a, b];
      final now = DateTime.now();
      var offline = true;
      final calls = <String>[];
      var healthy = 0;
      w.clients['a'] = FakeRpc((method, _) {
        calls.add(method);
        if (offline) {
          throw const AppFailure(
            'upstream',
            'dial tcp: lookup open.feishu.cn: no such host',
          );
        }
        return {'items': [], 'complete': true, 'hasMore': false};
      });
      w.clients['b'] = FakeRpc((_, _) {
        healthy++;
        return {'items': [], 'complete': true, 'hasMore': false};
      });
      await w.store.put('activeDiscovery', 'a', {
        'start': 1000,
        'end': 2000,
        'completedUntil': 500,
        'cursor': 'page2',
      }, account: 'a');
      Future<void> tick(int seconds) async {
        w.tick(at: now.add(Duration(seconds: seconds)));
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }

      await tick(0);
      final initial = calls.length;
      final healthyInitial = healthy;
      expect(w.notices.length, 1);
      await tick(20);
      expect(calls.length, initial);
      expect(healthy, greaterThan(healthyInitial));
      await tick(31);
      expect(calls.length, initial + 1);
      await tick(60);
      expect(calls.length, initial + 1);
      expect(w.notices.length, 1);
      expect(
        (await w.store.get('activeDiscovery', 'a'))?['completedUntil'],
        500,
      );
      offline = false;
      await tick(92);
      expect(w.notices, isEmpty);
      expect(
        (await w.store.get('activeDiscovery', 'a'))?['completedUntil'],
        2000,
      );
      await tick(93);
      expect(calls, isNot(contains('send')));
      expect(calls.length, greaterThan(initial + 2));
    },
  );
  test(
    'message network failure keeps cached data and resumes after recovery',
    () async {
      final w = Workspace()..store = Store(NativeDatabase.memory());
      await w.store.init();
      addTearDown(w.close);
      const a = AccountRef(id: 'a', platform: 'feishu', label: 'A');
      const c = Conversation(accountId: 'a', id: 'chat', title: 'chat');
      w.accounts = [a];
      w.conversations = [c];
      await w.store.put('cursors', c.key, {'timestamp': 1000});
      w.clients['a'] = FakeRpc(
        (_, _) => throw const AppFailure('upstream', 'dial tcp: i/o timeout'),
      );
      await w.syncConversation(c);
      expect(w.sync[c.key]!.mode, '等待网络');
      expect((await w.store.get('cursors', c.key))?['timestamp'], 1000);
      w.clients['a'] = FakeRpc(
        (_, _) => {'items': [], 'hasMore': false, 'complete': true},
      );
      w.tick(at: DateTime.now().add(const Duration(seconds: 31)));
      await Future<void>.delayed(const Duration(milliseconds: 80));
      expect(w.notices, isEmpty);
      expect(w.sync[c.key]!.error, isEmpty);
      expect(w.sync[c.key]!.mode, '定时同步');
    },
  );
}
