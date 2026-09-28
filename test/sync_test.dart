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
  });
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
      expect(notifications, 2);
      expect((await w.store.list('messages')).length, 2);
      expect(
        (await w.store.get('cursors', conversation.key))!['timestamp'],
        7000,
      );
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
