import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import '../core/models.dart';

class LocalDatabase extends GeneratedDatabase {
  LocalDatabase(super.e);
  @override
  int get schemaVersion => 1;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
  @override
  List<DatabaseSchemaEntity> get allSchemaEntities => const [];
}

class Store {
  final LocalDatabase db;
  Store(QueryExecutor executor) : db = LocalDatabase(executor);
  static Future<Store> open(String path) async {
    final store = Store(NativeDatabase.createInBackground(File(path)));
    await store.init();
    return store;
  }

  Future<void> init() async {
    await db.customStatement('PRAGMA journal_mode=WAL');
    await db.customStatement(
      'CREATE TABLE IF NOT EXISTS records (bucket TEXT NOT NULL, key TEXT NOT NULL, account TEXT NOT NULL DEFAULT \'\', conversation TEXT NOT NULL DEFAULT \'\', ts INTEGER NOT NULL DEFAULT 0, text TEXT NOT NULL DEFAULT \'\', body TEXT NOT NULL, PRIMARY KEY(bucket,key))',
    );
    await db.customStatement(
      'CREATE INDEX IF NOT EXISTS records_account ON records(bucket,account,conversation,ts)',
    );
    await db.customStatement(
      "CREATE VIRTUAL TABLE IF NOT EXISTS search_index USING fts5(bucket UNINDEXED, key UNINDEXED, account UNINDEXED, text, tokenize='trigram')",
    );
    // A crash while sending cannot safely become an automatic retry.
    final pending = await list('outbox');
    for (final row in pending.where((e) => e['state'] == 'sending')) {
      await put('outbox', row['id'], {...row, 'state': 'unknown'});
    }
  }

  Future<void> put(
    String bucket,
    String key,
    Json data, {
    String account = '',
    String conversation = '',
    int ts = 0,
    String text = '',
  }) async {
    await db.transaction(() async {
      await db.customStatement(
        'INSERT INTO records(bucket,key,account,conversation,ts,text,body) VALUES(?,?,?,?,?,?,?) ON CONFLICT(bucket,key) DO UPDATE SET account=excluded.account,conversation=excluded.conversation,ts=excluded.ts,text=excluded.text,body=excluded.body',
        [bucket, key, account, conversation, ts, text, jsonEncode(data)],
      );
      if (bucket == 'messages' || bucket == 'resources') {
        await db.customStatement(
          'DELETE FROM search_index WHERE bucket=? AND key=?',
          [bucket, key],
        );
        await db.customStatement(
          'INSERT INTO search_index(bucket,key,account,text) VALUES(?,?,?,?)',
          [bucket, key, account, text],
        );
      }
    });
  }

  Future<Json?> get(String bucket, String key) async {
    final rows = await db
        .customSelect(
          'SELECT body FROM records WHERE bucket=? AND key=?',
          variables: [Variable(bucket), Variable(key)],
        )
        .get();
    return rows.isEmpty
        ? null
        : object(jsonDecode(rows.first.read<String>('body')));
  }

  Future<List<Json>> list(
    String bucket, {
    String? account,
    String? conversation,
    int limit = 1000,
  }) async {
    final rows = await db
        .customSelect(
          'SELECT body FROM records WHERE bucket=?${account == null ? '' : ' AND account=?'}${conversation == null ? '' : ' AND conversation=?'} ORDER BY ts DESC LIMIT ?',
          variables: [
            Variable(bucket),
            if (account != null) Variable(account),
            if (conversation != null) Variable(conversation),
            Variable(limit),
          ],
        )
        .get();
    return rows.map((r) => object(jsonDecode(r.read<String>('body')))).toList();
  }

  Future<void> remove(String bucket, String key) async {
    await db.transaction(() async {
      await db.customStatement('DELETE FROM records WHERE bucket=? AND key=?', [
        bucket,
        key,
      ]);
      await db.customStatement(
        'DELETE FROM search_index WHERE bucket=? AND key=?',
        [bucket, key],
      );
    });
  }

  Future<void> saveMessage(Message m) => put(
    'messages',
    m.key,
    m.toJson(),
    account: m.accountId,
    conversation: m.conversationId,
    ts: m.timestamp,
    text: m.text,
  );
  Future<List<ResourceRef>> search(String query, Set<String> accounts) async {
    if (query.trim().isEmpty || accounts.isEmpty) return [];
    final placeholders = accounts.map((_) => '?').join(',');
    final fullText = query.runes.length >= 3;
    final rows = await db
        .customSelect(
          fullText
              ? 'SELECT r.bucket,r.body FROM search_index s JOIN records r ON r.bucket=s.bucket AND r.key=s.key WHERE search_index MATCH ? AND s.account IN ($placeholders) ORDER BY r.ts DESC LIMIT 100'
              : "SELECT bucket,body FROM records WHERE bucket IN ('messages','resources') AND account IN ($placeholders) AND instr(lower(text),lower(?))>0 ORDER BY ts DESC LIMIT 100",
          variables: fullText
              ? [
                  Variable('"${query.replaceAll('"', '""')}"'),
                  ...accounts.map(Variable.new),
                ]
              : [...accounts.map(Variable.new), Variable(query)],
        )
        .get();
    return rows.map((r) {
      final data = object(jsonDecode(r.read<String>('body')));
      if (r.read<String>('bucket') == 'resources') {
        return ResourceRef.fromJson(data);
      }
      final m = Message.fromJson(data);
      return ResourceRef(
        accountId: m.accountId,
        id: m.id,
        title: m.sender,
        text: m.text,
        kind: 'message',
        conversationId: m.conversationId,
        updatedAt: m.timestamp,
      );
    }).toList();
  }

  Future<void> audit(String action, Json data) => put('audit', newId(), {
    'action': action,
    ...data,
  }, ts: DateTime.now().millisecondsSinceEpoch);
  Future<void> close() => db.close();
}
