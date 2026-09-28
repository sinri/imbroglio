import 'dart:async';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imbroglio/src/core/models.dart';
import 'package:imbroglio/src/core/rpc.dart';
import 'package:imbroglio/src/services/store.dart';
import 'package:imbroglio/src/services/workspace.dart';

class FakeRpc implements RpcClient {
  final FutureOr<dynamic> Function(String, Json) handler;
  FakeRpc(this.handler);
  @override
  Future<dynamic> call(
    String method, [
    Json params = const {},
    Duration timeout = const Duration(seconds: 45),
  ]) async => handler(method, params);
  @override
  Future<void> close() async {}
  @override
  void notify(String method, Json params) {}
  @override
  bool get hasPending => false;
  @override
  Process get process => throw UnimplementedError();
  @override
  StreamController<Json> get events => throw UnimplementedError();
}

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
      var notifications = 0;
      w.onIncoming = (_) => notifications++;
      w.clients['a'] = FakeRpc(
        (method, args) => {
          'items': [message('m', 5000)],
          'hasMore': true,
          'cursor': 'older',
        },
      );
      await w.syncConversation(conversation);
      expect(
        (await w.store.get('cursors', conversation.key))!['timestamp'],
        5000,
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
            message('within', now - const Duration(days: 30).inMilliseconds),
            message('outside', now - const Duration(days: 100).inMilliseconds),
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
