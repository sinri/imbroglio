import 'dart:async';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imbroglio/src/core/models.dart';
import 'package:imbroglio/src/core/feishu_auth.dart';
import 'package:imbroglio/src/core/rpc.dart';
import 'package:imbroglio/src/services/store.dart';
import 'package:imbroglio/src/services/workspace.dart';

class FakeRpc implements RpcClient {
  bool closed = false;
  final cancelledMethods = <String>{};
  final FutureOr<dynamic> Function(String, Json) handler;
  FakeRpc(this.handler);
  @override
  Future<dynamic> call(
    String method, [
    Json params = const {},
    Duration timeout = const Duration(seconds: 45),
  ]) async => handler(method, params);
  @override
  Future<void> close() async {
    closed = true;
  }

  @override
  void notify(String method, Json params) {}
  @override
  void cancelPending(Set<String> methods) => cancelledMethods.addAll(methods);
  @override
  bool get hasPending => false;
  @override
  Process get process => throw UnimplementedError();
  @override
  StreamController<Json> get events => throw UnimplementedError();
}

Json authResponse(String method) => method == 'auth.login'
    ? {'completed': true, 'userId': 'ou_test'}
    : {
        'status': {
          'appId': 'app',
          'identities': {
            'user': {
              'available': true,
              'verified': true,
              'status': 'ready',
              'openId': 'ou_test',
              'scope': {...feishuReadScopes, ...feishuSendScopes}.join(' '),
            },
          },
        },
      };

void main() {
  late Workspace w;
  final temporaryDirectories = <Directory>[];
  const account = AccountRef(id: 'a', platform: 'feishu', label: 'test');
  const conversation = Conversation(accountId: 'a', id: 'c', title: 'chat');
  Json message(String id, int time) => Message(
    accountId: 'a',
    conversationId: 'c',
    id: id,
    text: id,
    timestamp: time,
  ).toJson();
  setUp(() async {
    w = Workspace()
      ..store = Store(NativeDatabase.memory())
      ..accounts = [account]
      ..conversations = [conversation];
    await w.store.init();
  });
  tearDown(() async {
    await w.close();
    for (final dir in temporaryDirectories) {
      await dir.delete(recursive: true);
    }
    temporaryDirectories.clear();
  });
  test(
    'three tiers cool idle chats and revisit them after three hours',
    () async {
      final now = DateTime.now();
      w.conversations = [
        conversation.copyWith(
          updatedAt: now
              .subtract(const Duration(hours: 2))
              .millisecondsSinceEpoch,
        ),
        const Conversation(
          accountId: 'a',
          id: 'hot',
          title: 'hot',
        ).copyWith(updatedAt: now.millisecondsSinceEpoch),
      ];
      final reads = <String, int>{};
      w.clients['a'] = FakeRpc((method, args) {
        if (method == 'messages' && args['before'] == null) {
          final id = object(args['conversation'])['id'] as String;
          reads[id] = (reads[id] ?? 0) + 1;
        }
        return {'items': [], 'hasMore': false, 'complete': true};
      });
      Future<void> tick(int seconds) async {
        w.tick(at: now.add(Duration(seconds: seconds)));
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }

      await tick(0);
      await tick(1);
      expect(reads, {'c': 1, 'hot': 1});
      await tick(31);
      expect(reads, {'c': 1, 'hot': 2});
      await tick(3601);
      expect(reads, {'c': 1, 'hot': 2});
      await tick(10801);
      await tick(10802);
      expect(reads, {'c': 2, 'hot': 3});
    },
  );

  test(
    'active discovery resumes a fixed window and preserves rich chat details',
    () async {
      final now = DateTime.now();
      w.conversations = [
        const Conversation(
          accountId: 'a',
          id: 'c',
          title: 'Known',
          peerId: 'peer',
          avatar: 'avatar',
        ),
      ];
      final queries = <Json>[];
      var fail = false;
      w.clients['a'] = FakeRpc((method, args) {
        queries.add({...args});
        if (fail) throw const AppFailure('network', 'offline');
        return {
          'items': [
            conversation
                .copyWith(updatedAt: now.millisecondsSinceEpoch)
                .toJson(),
          ],
          'complete': args['cursor'] == 'page2',
          'cursor': args['cursor'] == 'page2' ? '' : 'page2',
        };
      });
      await w.refreshActiveConversations(account, at: now);
      expect(
        (await w.store.get('activeDiscovery', 'a'))?['completedUntil'],
        isNull,
      );
      fail = true;
      await expectLater(
        w.refreshActiveConversations(
          account,
          at: now.add(const Duration(seconds: 15)),
        ),
        throwsA(isA<AppFailure>()),
      );
      fail = false;
      await w.refreshActiveConversations(
        account,
        at: now.add(const Duration(seconds: 30)),
      );
      expect(queries.last['start'], queries.first['start']);
      expect(queries.last['end'], queries.first['end']);
      expect(queries.last['cursor'], 'page2');
      expect(
        (await w.store.get('activeDiscovery', 'a'))?['completedUntil'],
        queries.first['end'],
      );
      expect(w.conversations.single.title, 'Known');
      expect(w.conversations.single.peerId, 'peer');
      expect(w.conversations.single.avatar, 'avatar');
      await w.refreshActiveConversations(
        account,
        at: now.add(const Duration(seconds: 45)),
      );
      expect(queries.last['start'], (queries.first['end'] as int) - 120000);
    },
  );

  test(
    'active discovery rejects a stalled page without advancing checkpoint',
    () async {
      w.clients['a'] = FakeRpc(
        (_, _) => {'items': [], 'complete': false, 'cursor': ''},
      );
      await expectLater(
        w.refreshActiveConversations(account),
        throwsA(isA<AppFailure>()),
      );
      expect(
        (await w.store.get('activeDiscovery', 'a'))?['completedUntil'],
        isNull,
      );
    },
  );

  test(
    'active changes wake cold chats without repeating overlapping results',
    () async {
      final now = DateTime.now();
      w.conversations = [
        conversation.copyWith(
          updatedAt: now
              .subtract(const Duration(hours: 2))
              .millisecondsSinceEpoch,
        ),
      ];
      var latest = now
          .subtract(const Duration(hours: 2))
          .millisecondsSinceEpoch;
      var reads = 0;
      w.clients['a'] = FakeRpc((method, args) {
        if (method == 'conversations.active') {
          return {
            'items': [conversation.copyWith(updatedAt: latest).toJson()],
            'complete': true,
          };
        }
        if (method == 'messages' && args['before'] == null) reads++;
        return {'items': [], 'hasMore': false, 'complete': true};
      });
      Future<void> tick(int seconds) async {
        w.tick(at: now.add(Duration(seconds: seconds)));
        await Future<void>.delayed(const Duration(milliseconds: 60));
      }

      await tick(0);
      await tick(1);
      expect(reads, 1);
      latest = now.millisecondsSinceEpoch;
      await w.refreshActiveConversations(
        account,
        at: now.add(const Duration(seconds: 2)),
      );
      await tick(3);
      expect(reads, 2);
      await w.refreshActiveConversations(
        account,
        at: now.add(const Duration(seconds: 4)),
      );
      await tick(5);
      expect(reads, 2);
    },
  );

  test(
    'partial login continues verification and preserves a visible permissions warning',
    () async {
      final calls = <String>[];
      w.clients['a'] = FakeRpc((method, _) {
        calls.add(method);
        if (method == 'auth.scopes') {
          return {
            'appId': 'app',
            'userScopes': [...feishuReadScopes, ...feishuSendScopes],
          };
        }
        if (method == 'auth.status' && !calls.contains('auth.login')) {
          return {
            'status': {
              'appId': 'app',
              'identities': {
                'user': {'status': 'missing'},
              },
            },
          };
        }
        return method == 'auth.login'
            ? {
                'completed': true,
                'userId': 'ou_test',
                'warning': '部分权限未授予',
                'missingScopes': ['optional.scope'],
              }
            : authResponse(method);
      });
      final result = await w.authenticate(account);
      expect(calls, [
        'auth.status',
        'auth.scopes',
        'auth.login',
        'auth.status',
      ]);
      expect(result['warning'], '部分权限未授予');
      expect(w.notice, contains('部分权限未授予'));
    },
  );
  test(
    'initial import stops at seven days; explicit manual history bypasses that boundary',
    () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      final recent = now - const Duration(days: 6).inMilliseconds;
      final old = now - const Duration(days: 8).inMilliseconds;
      final requests = <Json>[];
      w.clients['a'] = FakeRpc((method, args) {
        if (method != 'messages') return {};
        requests.add(args);
        if (requests.length == 1) {
          return {
            'items': [message('recent', recent), message('old', old)],
            'hasMore': true,
            'cursor': 'automatic-next',
          };
        }
        return {
          'items': [message('old', old)],
          'hasMore': false,
        };
      });
      await w.syncConversation(conversation);
      expect(
        requests.single['notBefore'],
        closeTo(now - const Duration(days: 7).inMilliseconds, 2000),
      );
      expect(
        await w.store.get('messages', compositeKey('a', 'recent')),
        isNotNull,
      );
      expect(await w.store.get('messages', compositeKey('a', 'old')), isNull);
      expect(
        (await w.store.get('cursors', conversation.key))!['historyDone'],
        true,
      );
      w.selectedConversation = conversation;
      await w.showEarlierMessages();
      expect(requests.length, 1);
      await w.showEarlierMessages(manual: true);
      expect(requests.length, 2);
      expect(requests.last.containsKey('notBefore'), false);
      expect(requests.last['cursor'], isNull);
      expect(requests.last['before'], recent);
      expect(
        await w.store.get('messages', compositeKey('a', 'old')),
        isNotNull,
      );
      expect(
        (await w.store.get('cursors', conversation.key))!['manualHistoryDone'],
        true,
      );
      await w.showEarlierMessages(manual: true);
      expect(requests.length, 2);
    },
  );

  test('manual history keeps its own pagination checkpoint', () async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await w.store.saveMessage(Message.fromJson(message('recent', now)));
    await w.store.put('cursors', conversation.key, {
      'timestamp': now,
      'historyDone': true,
      'historyCursor': 'automatic-cursor',
    });
    final requests = <Json>[];
    w.clients['a'] = FakeRpc((method, args) {
      requests.add(args);
      return {
        'items': [
          message(
            'old${requests.length}',
            now - Duration(days: 8 + requests.length).inMilliseconds,
          ),
        ],
        'hasMore': requests.length == 1,
        'cursor': requests.length == 1 ? 'manual-next' : '',
      };
    });
    await w.syncConversation(conversation, older: true, manual: true);
    await w.syncConversation(conversation, older: true, manual: true);
    expect(requests.first['cursor'], isNull);
    expect(requests.last['cursor'], 'manual-next');
    expect(requests.last['before'], requests.first['before']);
    final saved = (await w.store.get('cursors', conversation.key))!;
    expect(saved['historyCursor'], 'automatic-cursor');
    expect(saved['manualHistoryDone'], true);
  });
  test('logout failure still closes the client and pauses syncing', () async {
    final rpc = FakeRpc((method, args) {
      if (method == 'auth.logout') throw const AppFailure('test', '注销失败');
      return {};
    });
    w.clients['a'] = rpc;
    await expectLater(
      w.disconnect(account, logout: true),
      throwsA(isA<AppFailure>()),
    );
    expect(rpc.closed, true);
    expect(w.clients, isEmpty);
    expect(w.account('a').enabled, false);
  });
  for (final methodToCancel in [
    'auth.configure',
    'auth.login',
    'auth.status',
  ]) {
    test('cancel $methodToCancel stops the flow and permits retry', () async {
      final entered = Completer<void>();
      final pending = Completer<Json>();
      final methods = <String>[];
      var first = true;
      final rpc = FakeRpc((method, args) {
        methods.add(method);
        if (first && method == methodToCancel) {
          entered.complete();
          return pending.future;
        }
        return authResponse(method);
      });
      w.clients['a'] = rpc;
      final attempt = w.authenticate(
        const AccountRef(id: 'a', platform: 'dingtalk', label: 'test'),
        configure: true,
      );
      final assertion = expectLater(
        attempt,
        throwsA(isA<AppFailure>().having((e) => e.code, 'code', 'cancelled')),
      );
      await entered.future;
      w.authUrls['a'] = 'https://example.com/authorization';
      w.cancelAuthentication(account);
      await assertion;
      expect(w.authUrls, isEmpty);
      expect(rpc.cancelledMethods, contains(methodToCancel));
      expect(methods.last, methodToCancel);
      first = false;
      methods.clear();
      await w.authenticate(
        const AccountRef(id: 'a', platform: 'dingtalk', label: 'test'),
      );
      expect(methods, ['auth.login', 'auth.status']);
      pending.complete({});
      await Future<void>.delayed(Duration.zero);
      expect(methods, ['auth.login', 'auth.status']);
    });
  }
  test(
    'authentication reports stages and clears obsolete authorization URLs',
    () async {
      final stages = <String>[];
      final methods = <String>[];
      w.authUrls['a'] = 'https://example.com/old';
      w.clients['a'] = FakeRpc((method, args) {
        methods.add(method);
        expect(w.authUrls['a'], isNull);
        if (method != 'auth.status') {
          w.authUrls['a'] = 'https://example.com/current';
        }
        return authResponse(method);
      });
      await w.authenticate(
        const AccountRef(id: 'a', platform: 'dingtalk', label: 'test'),
        configure: true,
        onStage: stages.add,
      );
      expect(methods, ['auth.configure', 'auth.login', 'auth.status']);
      expect(stages, ['应用初始化', '用户授权', '连接验证']);
      expect(w.authUrls, isEmpty);
    },
  );

  for (final failure in {
    'auth.configure': '应用初始化',
    'auth.login': '用户授权',
    'auth.status': '连接验证',
  }.entries) {
    test('authentication identifies failure at ${failure.key}', () async {
      final methods = <String>[];
      w.clients['a'] = FakeRpc((method, args) {
        methods.add(method);
        if (method == failure.key) {
          w.authUrls['a'] = 'https://example.com/expired';
          throw const AppFailure('authentication', 'denied', retryAfter: 7);
        }
        return {};
      });
      await expectLater(
        w.authenticate(
          const AccountRef(id: 'a', platform: 'dingtalk', label: 'test'),
          configure: true,
        ),
        throwsA(
          isA<AppFailure>()
              .having((e) => e.message, 'message', '${failure.value}失败：denied')
              .having((e) => e.code, 'code', 'authentication')
              .having((e) => e.retryAfter, 'retryAfter', 7),
        ),
      );
      expect(methods.last, failure.key);
      expect(w.authUrls, isEmpty);
    });
  }
  test(
    'selecting a chat preserves its position among equal timestamps',
    () async {
      const second = Conversation(
        accountId: 'a',
        id: 'second',
        title: 'Second',
      );
      w.conversations = [conversation.copyWith(unread: 3), second];
      w.clients['a'] = FakeRpc(
        (method, args) => {'items': [], 'hasMore': false},
      );
      await w.selectConversation(w.conversations.first);
      expect(w.conversations.map((c) => c.id), ['c', 'second']);
      expect(w.conversations.first.unread, 0);
      expect(w.selectedConversation!.id, 'c');
    },
  );
  test(
    'delayed messages do not move an active chat back in the list',
    () async {
      final current = conversation.copyWith(updatedAt: 9000);
      w.conversations = [current];
      await w.store.put('cursors', current.key, {'timestamp': 5000});
      w.clients['a'] = FakeRpc(
        (method, args) => {
          'items': [message('delayed', 6000)],
          'hasMore': false,
        },
      );
      await w.selectConversation(current);
      expect(w.conversations.single.updatedAt, 9000);
      expect(w.messages.single.id, 'delayed');
    },
  );
  test(
    'initial history establishes a live checkpoint without announcing all history',
    () async {
      final timestamp = DateTime.now()
          .subtract(const Duration(hours: 1))
          .millisecondsSinceEpoch;
      var notifications = 0;
      w.onIncoming = (_) => notifications++;
      w.clients['a'] = FakeRpc(
        (method, args) => {
          'items': [message('m', timestamp)],
          'hasMore': true,
          'cursor': 'older',
        },
      );
      await w.syncConversation(conversation);
      expect(
        (await w.store.get('cursors', conversation.key))!['timestamp'],
        timestamp,
      );
      expect(w.sync[conversation.key]!.gap, false);
      expect(notifications, 0);
    },
  );
  test(
    'incremental pages deduplicate overlaps and save watermark only after drain',
    () async {
      await w.store.put('cursors', conversation.key, {'timestamp': 5000});
      var requests = 0, notifications = 0;
      w.onIncoming = (_) => notifications++;
      w.clients['a'] = FakeRpc((method, args) {
        requests++;
        return args['cursor'] == null
            ? {
                'items': [message('m1', 6000)],
                'hasMore': true,
                'cursor': 'next',
              }
            : {
                'items': [message('m1', 6000), message('m2', 7000)],
                'hasMore': false,
                'cursor': '',
              };
      });
      await w.syncConversation(conversation);
      expect(requests, 2);
      expect(
        notifications,
        0,
      ); // Offline catch-up updates badges, not desktop alerts.
      expect((await w.store.list('messages')).length, 2);
      expect(
        (await w.store.get('cursors', conversation.key))!['timestamp'],
        7000,
      );
    },
  );
  test(
    'new live messages notify once and count locally while another page is open',
    () async {
      final now = DateTime.now().millisecondsSinceEpoch + 100;
      await w.store.put('cursors', conversation.key, {'timestamp': now - 1000});
      w.selectedConversation = conversation;
      w.chatVisible = false;
      var notifications = 0;
      w.onIncoming = (_) => notifications++;
      w.clients['a'] = FakeRpc(
        (method, args) => {
          'items': [message('live', now)],
          'hasMore': false,
        },
      );
      await w.syncConversation(conversation);
      await w.syncConversation(conversation);
      expect(notifications, 1);
      expect(w.conversations.single.unread, 1);
      await w.updateReading(visible: true);
      expect(w.conversations.single.unread, 0);
      expect(
        (await w.store.get('readState', conversation.key))!['timestamp'],
        isA<int>(),
      );
    },
  );

  test('send completes while post-send history is still pending', () async {
    final history = Completer<Json>();
    w.clients['a'] = FakeRpc((method, args) {
      if (method == 'send') return {'messageId': 'sent'};
      return history.future;
    });
    try {
      await w.send(conversation, 'hello').timeout(const Duration(seconds: 2));
      expect(w.outbox.single['state'], 'confirmed');
      expect(history.isCompleted, false);
    } finally {
      history.complete({'items': [], 'hasMore': false});
    }
  });

  test(
    'scheduler includes recent unwatched chats and discovers pages',
    () async {
      final synced = Completer<void>();
      w.clients['a'] = FakeRpc((method, args) {
        if (method == 'messages' && !synced.isCompleted) synced.complete();
        return {'items': [], 'hasMore': false};
      });
      w.tick();
      await synced.future.timeout(const Duration(seconds: 2));
      expect(w.selectedConversation, isNull);
      expect(conversation.watched, false);
    },
  );

  test(
    'history counts local unread within retention without desktop alerts',
    () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      await w.store.saveMessage(Message.fromJson(message('latest', now)));
      await w.store.put('cursors', conversation.key, {'timestamp': now});
      var notifications = 0;
      w.onIncoming = (_) => notifications++;
      w.clients['a'] = FakeRpc(
        (method, args) => {
          'items': [
            message('within', now - const Duration(days: 6).inMilliseconds),
            message('outside', now - const Duration(days: 8).inMilliseconds),
          ],
          'hasMore': true,
        },
      );
      await w.syncConversation(conversation, older: true);
      expect(
        (await w.store.get('cursors', conversation.key))!['historyDone'],
        true,
      );
      expect(
        await w.store.get('messages', compositeKey('a', 'outside')),
        isNull,
      );
      expect(
        await w.store.get('messages', compositeKey('a', 'within')),
        isNotNull,
      );
      expect(w.conversations.single.unread, 1);
      expect(notifications, 0);
    },
  );

  test(
    'platform unread counts refresh instead of keeping obsolete local count',
    () async {
      w.clients['a'] = FakeRpc(
        (method, args) => {
          'items': [
            {
              ...conversation.toJson(),
              'unread': 7,
              'unreadIsLocal': false,
              'updatedAt': 100,
            },
          ],
        },
      );
      await w.refreshConversations(account);
      expect(w.conversations.single.unread, 7);
      expect(w.conversations.single.unreadIsLocal, false);
    },
  );

  test(
    'first import counts local history once, excludes own and read messages',
    () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      w.clients['a'] = FakeRpc(
        (method, args) => {
          'items': [
            message('old', now - 10000),
            {
              ...message('own', now - 9000),
              'extra': {'isOwn': true},
            },
          ],
          'hasMore': false,
        },
      );
      await w.syncConversation(conversation);
      await w.syncConversation(conversation);
      expect(w.conversations.single.unread, 1);
      await w.markRead(w.conversations.single);
      w.clients['a'] = FakeRpc(
        (method, args) => {
          'items': [message('delayed', now - 8000)],
          'hasMore': false,
        },
      );
      await w.syncConversation(conversation, older: true);
      expect(w.conversations.single.unread, 0);
    },
  );

  test('platform history count remains authoritative', () async {
    final chat = conversation.copyWith(unread: 7, unreadIsLocal: false);
    w.conversations = [chat];
    w.clients['a'] = FakeRpc(
      (method, args) => {
        'items': [message('old', DateTime.now().millisecondsSinceEpoch - 1000)],
        'hasMore': false,
      },
    );
    await w.syncConversation(chat, older: true);
    expect(w.conversations.single.unread, 7);
  });

  test('reading live messages advances durable read watermark', () async {
    final now = DateTime.now().millisecondsSinceEpoch + 100;
    w.selectedConversation = conversation;
    w.clients['a'] = FakeRpc(
      (method, args) => {
        'items': [message('visible', now)],
        'hasMore': false,
      },
    );
    await w.syncConversation(conversation);
    expect(
      (await w.store.get('readState', conversation.key))!['timestamp'],
      now,
    );
    expect(w.conversations.single.unread, 0);
  });

  test('completed discovery restarts on next first-page refresh', () async {
    await w.store.put('discovery', 'a', {'done': true, 'cursor': ''});
    final cursors = <Object?>[];
    w.clients['a'] = FakeRpc((method, args) {
      cursors.add(args['cursor']);
      return {'items': [], 'cursor': args['cursor'] == null ? 'page2' : ''};
    });
    await w.refreshConversations(account);
    await w.refreshConversations(account, more: true);
    expect(cursors, [null, 'page2']);
  });

  test(
    'incremental batches retain maximum timestamp across an empty final page',
    () async {
      await w.store.put('cursors', conversation.key, {'timestamp': 5000});
      var calls = 0;
      w.clients['a'] = FakeRpc((method, args) {
        calls++;
        return calls <= 2
            ? {
                'items': [message('m$calls', 5000 + calls * 1000)],
                'hasMore': true,
                'cursor': 'page$calls',
              }
            : {'items': [], 'hasMore': false};
      });
      await w.syncConversation(conversation);
      expect(w.sync[conversation.key]!.gap, true);
      await w.syncConversation(conversation);
      expect(
        (await w.store.get('cursors', conversation.key))!['timestamp'],
        7000,
      );
      expect(w.sync[conversation.key]!.gap, false);
    },
  );

  test('send is dispatched while a background request is blocked', () async {
    final background = Completer<Json>();
    final entered = Completer<void>();
    w.clients['a'] = FakeRpc((method, args) {
      if (method == 'send') return {'messageId': 'sent'};
      if (!entered.isCompleted) entered.complete();
      return background.future;
    });
    final sync = w.syncConversation(conversation);
    await entered.future;
    await w.send(conversation, 'immediate').timeout(const Duration(seconds: 2));
    expect(w.outbox.single['state'], 'confirmed');
    background.complete({'items': [], 'hasMore': false});
    await sync;
  });

  test(
    'empty initial chat establishes a checkpoint and completes history',
    () async {
      w.clients['a'] = FakeRpc(
        (method, args) => {'items': [], 'hasMore': false},
      );
      await w.syncConversation(conversation);
      final saved = (await w.store.get('cursors', conversation.key))!;
      expect(saved['timestamp'], greaterThanOrEqualTo(w.startedAt));
      expect(saved['historyDone'], true);
      expect(w.backgroundPending, 0);
    },
  );

  for (final blockedPlatform in ['dingtalk', 'feishu']) {
    test('$blockedPlatform discovery cannot starve another plugin', () async {
      final otherPlatform = blockedPlatform == 'dingtalk'
          ? 'feishu'
          : 'dingtalk';
      final blocked = Completer<Json>();
      final discovered = Completer<void>();
      final messages = Completer<void>();
      final blockedCalls = <String>{};
      w.accounts = [
        for (var i = 0; i < 4; i++)
          AccountRef(
            id: 'blocked$i',
            platform: blockedPlatform,
            label: 'blocked',
          ),
        AccountRef(id: 'a', platform: otherPlatform, label: 'other'),
      ];
      for (final a in w.accounts.take(4)) {
        w.clients[a.id] = FakeRpc((method, _) {
          blockedCalls.add(a.id);
          return blocked.future;
        });
      }
      w.clients['a'] = FakeRpc((method, _) {
        if (method == 'conversations' && !discovered.isCompleted) {
          discovered.complete();
        }
        if (method == 'messages' && !messages.isCompleted) messages.complete();
        return {'items': [], 'hasMore': false};
      });
      try {
        w.tick();
        await Future.wait([
          discovered.future,
          messages.future,
        ]).timeout(const Duration(seconds: 2));
        expect(blockedCalls.length, 4);
        expect(blocked.isCompleted, false);
      } finally {
        blocked.complete({'items': [], 'hasMore': false});
      }
    });
  }

  test('saturated message slots do not block another plugin', () async {
    final blocked = Completer<Json>();
    final entered = Completer<void>();
    final otherMessages = Completer<void>();
    w.accounts = [
      const AccountRef(id: 'ding', platform: 'dingtalk', label: 'DingTalk'),
      account,
    ];
    final chats = List.generate(
      3,
      (i) => Conversation(accountId: 'ding', id: 'chat$i', title: 'Chat $i'),
    );
    w.conversations = [...chats, conversation];
    var calls = 0;
    w.clients['ding'] = FakeRpc((method, _) {
      if (method == 'messages' && ++calls == 3) entered.complete();
      return blocked.future;
    });
    w.clients['a'] = FakeRpc((method, _) {
      if (method == 'messages' && !otherMessages.isCompleted) {
        otherMessages.complete();
      }
      return {'items': [], 'hasMore': false};
    });
    final pending = chats.map((c) => w.syncConversation(c)).toList();
    try {
      await entered.future.timeout(const Duration(seconds: 2));
      w.tick();
      w.tick();
      await otherMessages.future.timeout(const Duration(seconds: 2));
      expect(calls, 3);
      expect(blocked.isCompleted, false);
    } finally {
      blocked.complete({'items': [], 'hasMore': false});
      await Future.wait(pending);
    }
  });

  test('history pages run independently across plugins', () async {
    final blocked = Completer<Json>();
    final historyCalls = <String>[];
    final bothStarted = Completer<void>();
    final now = DateTime.now();
    w.accounts = [
      const AccountRef(id: 'ding', platform: 'dingtalk', label: 'DingTalk'),
      account,
    ];
    w.conversations = [
      const Conversation(accountId: 'ding', id: 'c', title: 'DingTalk chat'),
      conversation,
    ];
    for (final c in w.conversations) {
      await w.store.put('cursors', c.key, {
        'timestamp': now.millisecondsSinceEpoch,
      });
      w.clients[c.accountId] = FakeRpc((method, args) {
        if (method == 'messages' && !args.containsKey('since')) {
          historyCalls.add(c.accountId);
          if (historyCalls.length == 2) bothStarted.complete();
          return blocked.future;
        }
        return {'items': [], 'hasMore': false};
      });
    }
    try {
      w.tick(at: now);
      // Let live requests finish before the next scheduler tick requests history.
      while (w.activities.runningCount > 0) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      w.tick(at: now.add(const Duration(seconds: 1)));
      await bothStarted.future.timeout(const Duration(seconds: 2));
      w.tick(at: now.add(const Duration(seconds: 2)));
      expect(historyCalls, containsAll(['ding', 'a']));
      expect(historyCalls.length, 2);
      expect(blocked.isCompleted, false);
    } finally {
      blocked.complete({'items': [], 'hasMore': false});
    }
  });

  test(
    '100 recent chats receive a sync slot within 60 scheduler ticks',
    () async {
      final now = DateTime.now();
      w.conversations = List.generate(
        100,
        (i) => Conversation(
          accountId: 'a',
          id: 'chat$i',
          title: 'Chat $i',
          updatedAt: now.millisecondsSinceEpoch,
        ),
      );
      final reached = <String>{};
      w.clients['a'] = FakeRpc((method, args) {
        if (method == 'messages') {
          reached.add(object(args['conversation'])['id']);
        }
        return {'items': [], 'hasMore': false};
      });
      for (var second = 0; second < 60 && reached.length < 100; second++) {
        w.tick(at: now.add(Duration(seconds: second)));
        // Drain the in-memory database work between simulated one-second ticks.
        await Future<void>.delayed(const Duration(milliseconds: 30));
      }
      expect(reached.length, 100);
    },
  );

  test('read state survives restart before delayed history arrives', () async {
    final dir = await Directory.systemTemp.createTemp('imbroglio-read-');
    temporaryDirectories.add(dir);
    await w.close();
    w = Workspace();
    final seed = await Store.open('${dir.path}/imbroglio.sqlite');
    await seed.put('settings', 'seeded', {'version': 1});
    await seed.put('accounts', account.id, account.toJson());
    await seed.put('conversations', conversation.key, conversation.toJson());
    await seed.close();
    await w.initialize(directory: dir.path);
    expect(w.fatal, isNull);
    await w.markRead(conversation);
    final readTime =
        (await w.store.get('readState', conversation.key))!['timestamp'] as int;
    await w.close();
    w = Workspace();
    await w.initialize(directory: dir.path);
    expect(w.fatal, isNull);
    w.clients['a'] = FakeRpc(
      (method, args) => {
        'items': [message('delayed-after-restart', readTime - 1000)],
        'hasMore': false,
      },
    );
    await w.syncConversation(conversation, older: true);
    expect(w.conversations.single.unread, 0);
  });

  test('sender resolution drains more than one batch', () async {
    final batches = <int>[];
    final done = Completer<void>();
    w.clients['a'] = FakeRpc((method, args) {
      final ids = args['ids'] as List;
      batches.add(ids.length);
      return {
        'items': ids.map((id) => {'id': id, 'name': 'Name $id'}).toList(),
      };
    });
    w.addListener(() {
      if (w.senderProfiles.length == 45 && !done.isCompleted) done.complete();
    });
    final messages = List.generate(
      45,
      (i) => Message(
        accountId: 'a',
        conversationId: 'c',
        id: '$i',
        text: '',
        timestamp: 0,
        extra: {'senderLookupId': 'u$i'},
      ),
    );
    await w.resolveSenders('a', messages);
    await done.future.timeout(const Duration(seconds: 2));
    expect(batches, [20, 20, 5]);
  });

  test(
    'stalled incremental paging keeps checkpoint and reports incomplete data',
    () async {
      await w.store.put('cursors', conversation.key, {'timestamp': 5000});
      w.clients['a'] = FakeRpc(
        (method, args) => {
          'items': [message('overlap', 5000)],
          'hasMore': true,
        },
      );
      await w.syncConversation(conversation);
      expect(w.sync[conversation.key]!.gap, true);
      expect(w.sync[conversation.key]!.error, contains('分页无法继续'));
      expect(
        (await w.store.get('cursors', conversation.key))!['timestamp'],
        5000,
      );
    },
  );

  for (final found in [true, false]) {
    test(
      'successful Feishu lookup caches missing avatar, found=$found',
      () async {
        var calls = 0;
        w.clients['a'] = FakeRpc((method, args) {
          calls++;
          return {
            'items': [
              if (found) {'id': 'u', 'name': 'User', 'avatar': ''},
            ],
          };
        });
        const m = Message(
          accountId: 'a',
          conversationId: 'c',
          id: 'm',
          senderId: 'u',
          text: '',
          timestamp: 1,
        );
        await w.resolveSenders('a', [m]);
        final key = compositeKey('a', 'u');
        final saved = (await w.store.get('senders', key))!;
        expect(saved['avatarUnavailable'], true);
        expect(
          saved['expires'] as int,
          greaterThan(
            DateTime.now()
                .add(const Duration(hours: 11))
                .millisecondsSinceEpoch,
          ),
        );
        w.senderProfiles.clear();
        await w.resolveSenders('a', [m]);
        expect(calls, 1);
        w.senderProfiles.clear();
        await w.store.put('senders', key, {...saved, 'expires': 0});
        await w.resolveSenders('a', [m]);
        expect(calls, 2);
      },
    );
  }

  test(
    'failed profile query does not cache absent avatar for twelve hours',
    () async {
      w.clients['a'] = FakeRpc(
        (_, _) => throw const AppFailure('timeout', 'retry'),
      );
      const m = Message(
        accountId: 'a',
        conversationId: 'c',
        id: 'm',
        senderId: 'u',
        text: '',
        timestamp: 1,
      );
      await w.resolveSenders('a', [m]);
      final saved = (await w.store.get('senders', compositeKey('a', 'u')))!;
      expect(saved['avatarUnavailable'], isNull);
      expect(
        saved['expires'] as int,
        lessThan(
          DateTime.now().add(const Duration(minutes: 1)).millisecondsSinceEpoch,
        ),
      );
    },
  );

  test(
    'named cached sender without an avatar still triggers profile lookup',
    () async {
      Json? request;
      w.clients['a'] = FakeRpc((method, args) {
        request = args;
        return {
          'items': [
            {
              'id': 'staff1',
              'name': '张三',
              'avatar': 'https://example.com/avatar.png',
            },
          ],
        };
      });
      final m = Message(
        accountId: 'a',
        conversationId: 'c',
        id: 'm',
        text: '',
        timestamp: 1,
        sender: '张三',
        senderId: 'staff1',
        extra: {
          'raw': {'senderOpenDingTalkId': 'open1'},
        },
      );
      await w.resolveSenders('a', [m]);
      expect(request!['ids'], ['staff1']);
      expect(request!['openIds'], {'staff1': 'open1'});
      expect(
        w.senderProfiles[compositeKey('a', 'staff1')]!['avatar'],
        'https://example.com/avatar.png',
      );
    },
  );

  test(
    'legacy empty profile cache is retried instead of hiding contacts for 12 hours',
    () async {
      final key = compositeKey('a', 'u');
      await w.store.put('senders', key, {
        'expires': DateTime.now()
            .add(const Duration(hours: 12))
            .millisecondsSinceEpoch,
      });
      w.senderProfiles[key] = {};
      w.clients['a'] = FakeRpc(
        (method, args) => {
          'items': [
            {
              'id': 'u',
              'name': 'Recovered',
              'avatar': 'https://example.com/a.png',
            },
          ],
        },
      );
      await w.resolveSenders('a', [
        const Message(
          accountId: 'a',
          conversationId: 'c',
          id: 'm',
          text: '',
          timestamp: 1,
          senderId: 'u',
        ),
      ]);
      expect(w.senderProfiles[key]!['name'], 'Recovered');
      expect(w.senderProfiles[key]!['version'], 2);
    },
  );

  test('switching chats during profile lookup queues new senders', () async {
    final first = Completer<Json>();
    final started = Completer<void>();
    final requested = <String>[];
    w.clients['a'] = FakeRpc((method, args) {
      final id = (args['ids'] as List).single as String;
      requested.add(id);
      if (id == 'u1') {
        started.complete();
        return first.future;
      }
      return {
        'items': [
          {'id': id, 'name': 'Second', 'avatar': 'https://example.com/2.png'},
        ],
      };
    });
    final loading = w.resolveSenders('a', [
      const Message(
        accountId: 'a',
        conversationId: 'c',
        id: '1',
        text: '',
        timestamp: 1,
        senderId: 'u1',
      ),
    ]);
    await started.future;
    await w.resolveSenders('a', [
      const Message(
        accountId: 'a',
        conversationId: 'other',
        id: '2',
        text: '',
        timestamp: 1,
        senderId: 'u2',
      ),
    ]);
    first.complete({
      'items': [
        {'id': 'u1', 'name': 'First', 'avatar': 'https://example.com/1.png'},
      ],
    });
    await loading;
    expect(requested, ['u1', 'u2']);
    expect(w.senderProfiles[compositeKey('a', 'u2')]!['name'], 'Second');
  });

  test(
    'DingTalk avatar media is downloaded and cached inside the account',
    () async {
      final dir = await Directory.systemTemp.createTemp('imbroglio-avatar-');
      temporaryDirectories.add(dir);
      w.root = dir.path;
      final avatar = File('${dir.path}/accounts/a/downloads/avatar');
      await avatar.parent.create(recursive: true);
      final calls = <String>[];
      w.clients['a'] = FakeRpc((method, args) async {
        calls.add(method);
        if (method == 'contacts.resolve') {
          return {
            'items': [
              {'id': 'u', 'name': '张三', 'avatarResourceId': '@media'},
            ],
          };
        }
        expect(method, 'attachment.download');
        expect(args['resourceId'], '@media');
        expect(object(args['message'])['id'], 'm');
        await avatar.writeAsBytes([1, 2, 3]);
        return {'path': avatar.path};
      });
      const m = Message(
        accountId: 'a',
        conversationId: 'c',
        id: 'm',
        text: '',
        timestamp: 1,
        senderId: 'u',
      );
      await w.resolveSenders('a', [m]);
      expect(
        w.senderProfiles[compositeKey('a', 'u')]!['avatarPath'],
        avatar.path,
      );
      await w.resolveSenders('a', [m]);
      expect(calls, ['contacts.resolve', 'attachment.download']);
      await avatar.delete();
      await w.resolveSenders('a', [m]);
      expect(calls, [
        'contacts.resolve',
        'attachment.download',
        'contacts.resolve',
        'attachment.download',
      ]);
      expect(avatar.existsSync(), true);
    },
  );

  test(
    'real sync lifecycle exposes progress and backoff to the activity log',
    () async {
      final response = Completer<Json>();
      final entered = Completer<void>();
      w.clients['a'] = FakeRpc((method, args) {
        entered.complete();
        return response.future;
      });
      final request = w.syncConversation(conversation);
      await entered.future;
      expect(w.activities.runningCount, 1);
      expect(w.activities.items.single.title, '拉取新消息');
      response.completeError(
        const AppFailure('rate_limit', '平台限流', retryAfter: 60),
      );
      await request;
      expect(w.activities.runningCount, 0);
      expect(w.activities.items.single.state, 'failed');
      expect(w.activities.items.single.retryAt, isNotNull);
      w.clients['a'] = FakeRpc(
        (method, args) => {'items': [], 'hasMore': false},
      );
      await w.syncConversation(conversation);
      expect(w.activities.items.single.state, 'completed');
      expect(w.activities.items.single.detail, '已拉取 1 页 · 0 条消息');
      expect(w.activities.attentionCount, 0);
    },
  );

  test('identity mismatch does not enter cache or advance cursor', () async {
    w.clients['a'] = FakeRpc(
      (method, args) => {
        'items': [
          {...message('foreign', 5000), 'accountId': 'b'},
        ],
      },
    );
    await w.syncConversation(conversation);
    expect(await w.store.list('messages'), isEmpty);
    expect(await w.store.get('cursors', conversation.key), isNull);
    expect(w.sync[conversation.key]!.error, contains('来源不匹配'));
  });
  test(
    'failed sends are not retried and ambiguous result is persisted',
    () async {
      var calls = 0;
      w.clients['a'] = FakeRpc((method, args) {
        calls++;
        throw const AppFailure('timeout', 'timed out');
      });
      await expectLater(
        w.send(conversation, 'hello'),
        throwsA(isA<AppFailure>()),
      );
      expect(calls, 1);
      expect((await w.store.list('outbox')).single['state'], 'unknown');
      expect(w.activities.items.where((e) => e.title == '发送消息'), isEmpty);
    },
  );
  test('rate limiting remains visible with no lost checkpoint', () async {
    await w.store.put('cursors', conversation.key, {'timestamp': 5000});
    w.clients['a'] = FakeRpc(
      (method, args) =>
          throw const AppFailure('rate_limit', 'slow down', retryAfter: 120),
    );
    await w.syncConversation(conversation);
    expect(
      (await w.store.get('cursors', conversation.key))!['timestamp'],
      5000,
    );
    expect(w.sync[conversation.key]!.failures, 1);
  });
}
