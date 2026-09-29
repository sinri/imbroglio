import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imbroglio/src/core/models.dart';
import 'package:imbroglio/src/core/feishu_auth.dart';
import 'package:imbroglio/src/core/rpc.dart';
import 'package:imbroglio/src/services/store.dart';
import 'package:imbroglio/src/services/workspace.dart';
import 'adapter_test.dart' show RecordingAdapter;
import 'sync_test.dart' show FakeRpc;

class AuthWorkspace extends Workspace {
  late FakeRpc rpc;
  @override
  Future<RpcClient> client(AccountRef a) async => rpc;
}

void main() {
  const account = AccountRef(
    id: 'a',
    platform: 'feishu',
    label: '飞书',
    enabled: false,
  );
  const chat = Conversation(accountId: 'a', id: 'c', title: 'chat');
  late AuthWorkspace w;
  late Json user;
  setUp(() async {
    user = {
      'available': true,
      'verified': true,
      'status': 'ready',
      'openId': 'ou_test',
      'scope': {...feishuReadScopes, ...feishuSendScopes}.join(' '),
    };
    w = AuthWorkspace()
      ..store = Store(NativeDatabase.memory())
      ..accounts = [account];
    await w.store.init();
    var loggedIn = false;
    w.rpc = FakeRpc((method, _) {
      if (method == 'auth.login') {
        loggedIn = true;
        return {'completed': true, 'userId': 'ou_test'};
      }
      if (method == 'auth.scopes') {
        return {
          'appId': 'app',
          'userScopes': [
            ...feishuReadScopes,
            ...feishuSendScopes,
            ...feishuDocumentScopes,
          ],
        };
      }
      return {
        'status': {
          'appId': 'app',
          'identities': {
            'user': loggedIn ? user : {'status': 'missing'},
          },
        },
      };
    });
  });
  tearDown(() => w.close());

  test(
    'login explicitly requests sending and status verifies remotely',
    () async {
      final a = RecordingAdapter('feishu')
        ..response =
            '{"event":"authorization_complete","user_open_id":"ou_test"}';
      await a.handle(1, 'auth.login', {});
      expect(
        a.command,
        containsAllInOrder([
          '--scope',
          [...feishuReadScopes, ...feishuSendScopes].join(' '),
          '--json',
        ]),
      );
      a.response = {};
      await a.handle(2, 'auth.status', {});
      expect(a.command, containsAll(['--json', '--verify']));
    },
  );

  for (final patch in <Json>[
    {'available': false, 'status': 'missing'},
    {'verified': false, 'status': 'verify_failed'},
    {'verified': null},
    {'status': 'error'},
    {'openId': ''},
    {'openId': 'ou_someone_else'},
  ]) {
    test('rejects invalid or mismatched user: $patch', () async {
      user.addAll(patch);
      await expectLater(w.authenticate(account), throwsA(isA<AppFailure>()));
      expect(w.account('a').enabled, false);
    });
  }

  test(
    'verified refreshed user preserves identity and sending capability',
    () async {
      user['status'] = 'needs_refresh';
      final result = await w.authenticate(account);
      expect(result['userId'], 'ou_test');
      expect(result['canSend'], true);
    },
  );

  test(
    'denied sending keeps valid login but blocks send before RPC or outbox',
    () async {
      user['scope'] = {...feishuReadScopes, 'im:message'}.join(' ');
      final result = await w.authenticate(account);
      expect(result['canSend'], false);
      var calls = 0;
      w.rpc = FakeRpc((_, _) {
        calls++;
        return {'items': []};
      });
      await w.connect(
        account.copyWith(canSend: false),
        userId: result['userId'],
      );
      final saved = AccountRef.fromJson((await w.store.get('accounts', 'a'))!);
      expect(saved.enabled, true);
      expect(saved.canSend, false);
      expect(saved.userId, 'ou_test');
      calls = 0;
      await expectLater(
        w.send(chat, 'blocked'),
        throwsA(isA<AppFailure>().having((e) => e.code, 'code', 'permission')),
      );
      expect(calls, 0);
      await w.connect(saved.copyWith(canSend: true), userId: 'ou_test');
      expect(
        AccountRef.fromJson((await w.store.get('accounts', 'a'))!).canSend,
        true,
      );
    },
  );

  test(
    'failed initial conversation query leaves account persistently disabled',
    () async {
      w.rpc = FakeRpc(
        (_, _) => throw const AppFailure('upstream', 'query failed'),
      );
      await expectLater(
        w.connect(account, userId: 'ou_test'),
        throwsA(isA<AppFailure>()),
      );
      expect(w.account('a').enabled, false);
      expect((await w.store.get('accounts', 'a'))!['enabled'], false);
    },
  );

  test(
    'persisted login identity excludes own polled messages from unread and notifications',
    () async {
      w.rpc = FakeRpc((_, _) => {'items': []});
      await w.connect(account, userId: 'ou_test');
      w.conversations = [chat];
      final incoming = <Message>[];
      w.onIncoming = incoming.add;
      await w.store.put('notificationSettings', chat.key, {
        'muted': false,
        'checkedAt': DateTime.now().millisecondsSinceEpoch,
      }, account: account.id);
      final time = DateTime.now().millisecondsSinceEpoch + 1000;
      w.rpc = FakeRpc(
        (_, _) => {
          'items': [
            Message(
              accountId: 'a',
              conversationId: 'c',
              id: 'own',
              text: 'own',
              senderId: 'ou_test',
              timestamp: time,
            ).toJson(),
            Message(
              accountId: 'a',
              conversationId: 'c',
              id: 'other',
              text: 'other',
              senderId: 'ou_other',
              timestamp: time + 1,
            ).toJson(),
          ],
          'hasMore': false,
        },
      );
      await w.syncConversation(chat);
      expect(w.conversations.single.unread, 1);
      expect(incoming.map((m) => m.id), ['other']);
    },
  );
}
