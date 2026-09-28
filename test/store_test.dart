import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imbroglio/src/core/models.dart';
import 'package:imbroglio/src/services/store.dart';

void main() {
  late Store store;
  setUp(() async {
    store = Store(NativeDatabase.memory());
    await store.init();
  });
  tearDown(() async {
    await store.close();
  });
  test(
    'duplicate event/history messages upsert without account leakage',
    () async {
      for (final account in ['a', 'b']) {
        final m = Message(
          accountId: account,
          conversationId: 'same-chat',
          id: 'same-id',
          text: '发布计划已确认',
          timestamp: 1000,
        );
        await store.saveMessage(m);
        await store.saveMessage(m);
      }
      expect((await store.list('messages')).length, 2);
      expect((await store.search('发布计划', {'a'})).map((r) => r.accountId), [
        'a',
      ]);
      expect((await store.search('发布', {'b'})).map((r) => r.accountId), ['b']);
      expect(await store.search('计划', {}), isEmpty);
    },
  );
  test('interrupted writes become unknown and are not retried', () async {
    await store.put('outbox', 'id', {'id': 'id', 'state': 'sending'});
    await store.init();
    expect((await store.get('outbox', 'id'))!['state'], 'unknown');
  });
  test('search index updates and removal are transactional', () async {
    const m = Message(
      accountId: 'a',
      conversationId: 'c',
      id: 'm',
      text: '旧计划',
      timestamp: 1000,
    );
    await store.saveMessage(m);
    await store.saveMessage(Message.fromJson({...m.toJson(), 'text': '新计划'}));
    expect(await store.search('旧计划', {'a'}), isEmpty);
    expect((await store.search('新计划', {'a'})).length, 1);
    await store.remove('messages', m.key);
    expect(await store.search('新计划', {'a'}), isEmpty);
  });
}
