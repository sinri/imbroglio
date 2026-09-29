import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imbroglio/src/core/models.dart';
import 'package:imbroglio/src/services/agent.dart';
import 'package:imbroglio/src/services/store.dart';
import 'package:imbroglio/src/services/workspace.dart';
import 'sync_test.dart' show FakeRpc;

void main() {
  late Workspace w;
  late Directory root;
  const a = AccountRef(
    id: 'a',
    platform: 'feishu',
    label: '飞书 A',
    enabled: false,
    signedOut: true,
  );
  const b = AccountRef(
    id: 'b',
    platform: 'feishu',
    label: '飞书 B',
    enabled: false,
  );
  setUp(() async {
    root = await Directory.systemTemp.createTemp('imbroglio-cleanup-');
    w = Workspace()
      ..root = root.path
      ..store = Store(NativeDatabase.memory())
      ..accounts = [a, b];
    await w.store.init();
    for (final account in [a, b]) {
      await w.store.put('accounts', account.id, account.toJson());
    }
  });
  tearDown(() async {
    await w.close();
    await root.delete(recursive: true);
  });

  test(
    'cleanup removes owned records, indexes, files, backups and agent sessions only',
    () async {
      for (final id in ['a', 'b']) {
        final c = Conversation(accountId: id, id: 'chat', title: '聊天');
        w.conversations.add(c);
        await w.store.put('conversations', c.key, c.toJson(), account: id);
        await w.store.saveMessage(
          Message(
            accountId: id,
            conversationId: 'chat',
            id: 'message',
            text: 'cleanup needle',
            timestamp: 1,
          ),
        );
        for (final bucket in ['readState', 'cursors', 'sync', 'senders']) {
          await w.store.put(bucket, c.key, {'value': 'legacy'});
        }
        await w.store.put('cursors', 'conversations:$id', {'cursor': 'legacy'});
        await w.store.put('discovery', id, {'cursor': 'legacy'});
        await w.store.put(
          'attachments',
          compositeKey(compositeKey(id, 'message'), 'media'),
          {'path': 'legacy'},
        );
        await w.store.put('outbox', 'outbox-$id', {'accountId': id});
        await w.store.put('diagnostics', 'diagnostic-$id', {
          'accountId': id,
        }, account: id);
        await w.store.put(
          'resources',
          'resource-$id',
          {'accountId': id, 'id': 'resource-$id', 'title': 'Resource'},
          account: id,
          text: 'cleanup needle',
        );
        await w.store.put('agentSessions', 'session-$id', {
          'scope': [id],
          'history': ['private'],
        });
        await w.store.audit('agent.write', {'id': 'action-$id', 'account': id});
        await w.store.audit('agent.write', {
          'id': 'action-$id',
          'state': 'confirmed',
        });
        for (final path in [
          'accounts/$id/downloads/file',
          'accounts/$id/config/token',
          'backups/feishu/v1/$id/config',
          'backups/feishu/v2/$id/config',
        ]) {
          final file = File('${root.path}/$path');
          await file.parent.create(recursive: true);
          await file.writeAsString('private');
        }
      }
      await w.store.put('agentSessions', 'mixed', {
        'scope': ['a', 'b'],
      });
      await w.store.put('installations', 'feishu', {
        'enabled': true,
        'rollbackConfigs': {'a': 'a-backup', 'b': 'b-backup'},
        'previous': {
          'rollbackConfigs': {'a': 'old-a', 'b': 'old-b'},
        },
      });
      await w.store.put('settings', 'model', {'model': 'keep'});
      final agent = AgentController(w)
        ..sessionScope = {'a', 'b'}
        ..history = [
          {'content': 'private'},
        ];
      addTearDown(agent.dispose);
      w.selectedAccount = 'a';
      w.selectedConversation = w.conversations.first;
      w.senderProfiles[compositeKey('a', 'sender')] = {'name': 'private'};
      w.outbox = [
        {'accountId': 'a'},
        {'accountId': 'b'},
      ];
      await w.deleteAccount(a);
      expect(w.accounts.map((v) => v.id), ['b']);
      expect(w.selectedAccount, 'b');
      expect(w.selectedConversation, isNull);
      expect(w.senderProfiles, isEmpty);
      expect(w.outbox.single['accountId'], 'b');
      expect(agent.history, isEmpty);
      expect(await w.store.get('accounts', 'a'), isNull);
      expect(await w.store.get('accounts', 'b'), isNotNull);
      for (final bucket in [
        'conversations',
        'messages',
        'readState',
        'sync',
        'senders',
        'attachments',
        'outbox',
        'diagnostics',
        'resources',
        'agentSessions',
        'discovery',
      ]) {
        expect(await w.store.list(bucket), hasLength(1), reason: bucket);
      }
      expect(await w.store.list('cursors'), hasLength(2));
      expect(await w.store.list('audit'), hasLength(2));
      expect(await w.store.search('cleanup', {'a'}), isEmpty);
      expect(await w.store.search('cleanup', {'b'}), hasLength(2));
      final installation = (await w.store.get('installations', 'feishu'))!;
      expect(installation['rollbackConfigs'], {'b': 'b-backup'});
      expect(installation['previous']['rollbackConfigs'], {'b': 'old-b'});
      expect(await w.store.get('settings', 'model'), {'model': 'keep'});
      for (final parent in [
        'accounts',
        'backups/feishu/v1',
        'backups/feishu/v2',
      ]) {
        expect(await Directory('${root.path}/$parent/a').exists(), false);
        expect(await Directory('${root.path}/$parent/b').exists(), true);
      }
      // An old asynchronous result cannot resurrect deleted data.
      await w.store.saveMessage(
        const Message(
          accountId: 'a',
          conversationId: 'chat',
          id: 'late',
          text: 'late',
          timestamp: 2,
        ),
      );
      expect(await w.store.get('messages', compositeKey('a', 'late')), isNull);
      await expectLater(w.client(a), throwsA(isA<AppFailure>()));
    },
  );

  test(
    'logout failure preserves data and local-only cleanup remains possible',
    () async {
      w.accounts[0] = a.copyWith(signedOut: false);
      w.clients['a'] = FakeRpc(
        (method, _) => throw const AppFailure('auth', '注销失败'),
      );
      await expectLater(
        w.deleteAccount(w.account('a')),
        throwsA(isA<AppFailure>()),
      );
      expect(await w.store.get('accounts', 'a'), isNotNull);
      expect(w.deletedAccountIds, isEmpty);
      await w.deleteAccount(w.account('a'), logout: false);
      expect(await w.store.get('accounts', 'a'), isNull);
    },
  );

  test('active agent work blocks destructive cleanup', () async {
    w.activeAgentAccounts.add('a');
    await expectLater(w.deleteAccount(a), throwsA(isA<AppFailure>()));
    expect(await w.store.get('accounts', 'a'), isNotNull);
  });

  test('cleanup never follows an account directory symlink', () async {
    final external = await Directory.systemTemp.createTemp(
      'imbroglio-external-',
    );
    addTearDown(() => external.delete(recursive: true));
    await File('${external.path}/keep').writeAsString('keep');
    await Directory('${root.path}/accounts').create();
    await Link('${root.path}/accounts/a').create(external.path);
    await w.deleteAccount(a);
    expect(await File('${external.path}/keep').readAsString(), 'keep');
    expect(await Link('${root.path}/accounts/a').exists(), false);
  });
}
