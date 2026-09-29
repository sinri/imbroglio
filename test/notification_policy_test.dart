import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imbroglio/src/core/models.dart';
import 'package:imbroglio/src/services/store.dart';
import 'package:imbroglio/src/services/workspace.dart';
import 'sync_test.dart' show FakeRpc;

void main() {
  late Workspace w;
  const a = AccountRef(id: 'a', platform: 'feishu', label: 'test');
  const c = Conversation(accountId: 'a', id: 'c', title: 'chat');
  const probe = Message(
    accountId: 'a',
    conversationId: 'c',
    id: 'probe',
    text: '',
    timestamp: 0,
  );
  setUp(() async {
    w = Workspace()
      ..store = Store(NativeDatabase.memory())
      ..accounts = [a]
      ..conversations = [c];
    await w.store.init();
  });
  tearDown(() => w.close());
  test(
    'native DingTalk self messages use open ID mapping and never notify or count unread',
    () async {
      w.accounts = [
        const AccountRef(
          id: 'a',
          platform: 'dingtalk',
          label: 'Ding',
          userId: 'employee',
          profile: 'corp:employee',
        ),
      ];
      final calls = <String>[];
      var notifications = 0;
      w.onIncoming = (_) => notifications++;
      final time = DateTime.now().millisecondsSinceEpoch + 1000;
      w.clients['a'] = FakeRpc((method, args) {
        calls.add(method);
        if (method == 'identity.self') {
          return {
            'userId': 'employee',
            'ids': ['employee', 'own-open'],
          };
        }
        if (method == 'notifications.settings') {
          return {
            'items': [
              {'id': 'c', 'muted': false},
            ],
          };
        }
        return {
          'items': [
            Message(
              accountId: 'a',
              conversationId: 'c',
              id: 'self',
              text: 'native self',
              timestamp: time,
              senderId: 'different-wire-id',
              extra: {
                'raw': {'senderOpenDingTalkId': 'own-open'},
              },
            ).toJson(),
            Message(
              accountId: 'a',
              conversationId: 'c',
              id: 'other',
              text: 'other',
              timestamp: time,
              senderId: 'other-open',
            ).toJson(),
          ],
          'hasMore': false,
        };
      });
      await w.syncConversation(c);
      await w.syncConversation(c);
      expect(notifications, 1);
      expect(w.conversations.single.unread, 1);
      expect(calls.where((m) => m == 'identity.self').length, 1);
      final own = await w.store.get('messages', compositeKey('a', 'self'));
      expect(object(own?['extra'])['isOwn'], true);
    },
  );

  for (final muted in [true, false]) {
    test(
      'muted=$muted affects notifications only, retaining messages and unread',
      () async {
        var notifications = 0;
        final time = DateTime.now().millisecondsSinceEpoch + 1000;
        w.onIncoming = (_) => notifications++;
        w.clients['a'] = FakeRpc(
          (method, args) => method == 'notifications.settings'
              ? {
                  'items': [
                    {'id': 'c', 'muted': muted},
                  ],
                }
              : {
                  'items': [
                    Message(
                      accountId: 'a',
                      conversationId: 'c',
                      id: 'new',
                      text: 'message',
                      timestamp: time,
                    ).toJson(),
                  ],
                  'hasMore': false,
                },
        );
        await w.syncConversation(c);
        expect(notifications, muted ? 0 : 1);
        expect(w.conversations.single.unread, 1);
        expect(
          await w.store.get('notificationSettings', c.key),
          containsPair('muted', muted),
        );
        await w.syncConversation(c);
        expect(notifications, muted ? 0 : 1);
        expect(w.conversations.single.unread, 1);
      },
    );
  }
  test(
    'unknown settings suppress notifications and failure retains cached preference',
    () async {
      var calls = 0;
      w.clients['a'] = FakeRpc((_, _) {
        calls++;
        throw const AppFailure('network', 'offline');
      });
      expect(await w.notificationAllowed(probe), false);
      expect(await w.notificationAllowed(probe), false);
      expect(calls, 1);
      await w.store.put('notificationSettings', c.key, {
        'muted': true,
        'checkedAt': 0,
      }, account: 'a');
      expect(await w.notificationAllowed(probe), false);
      await w.store.put('notificationSettings', c.key, {
        'muted': false,
        'checkedAt': 0,
      }, account: 'a');
      expect(await w.notificationAllowed(probe), true);
    },
  );
  test(
    'stale setting refreshes before notification and persists mute changes',
    () async {
      await w.store.put('notificationSettings', c.key, {
        'muted': false,
        'checkedAt': 0,
      }, account: 'a');
      var calls = 0;
      w.clients['a'] = FakeRpc((_, _) {
        calls++;
        return {
          'items': [
            {'id': 'c', 'muted': true},
          ],
        };
      });
      expect(await w.notificationAllowed(probe), false);
      expect(await w.notificationAllowed(probe), false);
      expect(calls, 1);
      expect(
        (await w.store.get('notificationSettings', c.key))?['muted'],
        true,
      );
    },
  );
  test('notification preference is isolated by account', () async {
    w.accounts = [
      a,
      const AccountRef(id: 'b', platform: 'feishu', label: 'other'),
    ];
    await w.store.put('notificationSettings', c.key, {
      'muted': true,
      'checkedAt': DateTime.now().millisecondsSinceEpoch,
    }, account: 'a');
    w.clients['b'] = FakeRpc(
      (_, _) => {
        'items': [
          {'id': 'c', 'muted': false},
        ],
      },
    );
    expect(
      await w.notificationAllowed(
        const Message(
          accountId: 'b',
          conversationId: 'c',
          id: 'b',
          text: '',
          timestamp: 0,
        ),
      ),
      true,
    );
    expect(await w.notificationAllowed(probe), false);
  });
}
