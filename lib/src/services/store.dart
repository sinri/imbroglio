import 'dart:convert';
import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import '../core/models.dart';
import '../core/startup_trace.dart';
import '../core/normalize.dart';

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
  final _revisions = <String, int>{};
  final _deletedAccounts = <String>{};
  // Lets UI queries survive unrelated workspace notifications.
  int revision(String bucket) => _revisions[bucket] ?? 0;
  Store(QueryExecutor executor) : db = LocalDatabase(executor);
  static Future<Store> open(String path, {StartupTrace? trace}) async {
    final store = Store(NativeDatabase.createInBackground(File(path)));
    await store.init(trace: trace);
    return store;
  }

  Future<void> init({StartupTrace? trace}) async {
    await db.customStatement('PRAGMA journal_mode=WAL');
    trace?.mark('database.worker-ready');
    await db.customStatement(
      'CREATE TABLE IF NOT EXISTS records (bucket TEXT NOT NULL, key TEXT NOT NULL, account TEXT NOT NULL DEFAULT \'\', conversation TEXT NOT NULL DEFAULT \'\', ts INTEGER NOT NULL DEFAULT 0, text TEXT NOT NULL DEFAULT \'\', body TEXT NOT NULL, PRIMARY KEY(bucket,key))',
    );
    await db.customStatement(
      'CREATE INDEX IF NOT EXISTS records_account ON records(bucket,account,conversation,ts)',
    );
    await db.customStatement(
      "CREATE VIRTUAL TABLE IF NOT EXISTS search_index USING fts5(bucket UNINDEXED, key UNINDEXED, account UNINDEXED, text, tokenize='trigram')",
    );
    // A partial index avoids reading every message body on every launch,
    // including when there are no legacy timestamps to repair.
    await db.customStatement(
      "CREATE INDEX IF NOT EXISTS records_legacy_message_time ON records(key) WHERE bucket='messages' AND ts<=0",
    );
    trace?.mark('database.schema-ready');
    // Repair old rows before LIMIT/ORDER BY uses their timestamp index.
    // Page by key so genuinely missing timestamps do not loop forever.
    String? after;
    while (true) {
      final rows = await db
          .customSelect(
            "SELECT key,body FROM records INDEXED BY records_legacy_message_time WHERE bucket='messages' AND ts<=0${after == null ? '' : ' AND key>?'} ORDER BY key LIMIT 200",
            variables: [if (after != null) Variable(after)],
          )
          .get();
      if (rows.isEmpty) break;
      await db.transaction(() async {
        for (final row in rows) {
          final body = object(jsonDecode(row.read<String>('body')));
          final stored = body['timestamp'] as int? ?? 0;
          final recovered = stored > 0
              ? stored
              : messageTimestamp(object(object(body['extra'])['raw']));
          if (recovered > 0) {
            body['timestamp'] = recovered;
            await db.customStatement(
              "UPDATE records SET ts=?,body=? WHERE bucket='messages' AND key=?",
              [recovered, jsonEncode(body), row.read<String>('key')],
            );
          }
        }
      });
      after = rows.last.read<String>('key');
    }
    trace?.mark('database.legacy-repair-ready');
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
      if (_deletedAccounts.any(
        (id) => _belongsToAccount(id, bucket, key, account, data),
      )) {
        return;
      }
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
    _revisions[bucket] = revision(bucket) + 1;
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

  /// Fetch only the requested keys; chunking keeps SQLite parameter use bounded.
  Future<Map<String, Json>> getMany(
    String bucket,
    Iterable<String> keys,
  ) async {
    final unique = keys.toSet().toList();
    final result = <String, Json>{};
    for (var offset = 0; offset < unique.length; offset += 400) {
      final batch = unique.skip(offset).take(400).toList();
      final rows = await db
          .customSelect(
            'SELECT key,body FROM records WHERE bucket=? AND key IN (${List.filled(batch.length, '?').join(',')})',
            variables: [Variable(bucket), ...batch.map(Variable.new)],
          )
          .get();
      for (final row in rows) {
        result[row.read<String>('key')] = object(
          jsonDecode(row.read<String>('body')),
        );
      }
    }
    return result;
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
    _revisions[bucket] = revision(bucket) + 1;
  }

  bool _belongsToAccount(
    String id,
    String bucket,
    String key,
    String owner,
    Json body,
  ) {
    if (owner == id || body['accountId'] == id || body['account'] == id) {
      return true;
    }
    if ((bucket == 'accounts' || bucket == 'discovery') && key == id) {
      return true;
    }
    if (bucket == 'cursors' && key == 'conversations:$id') return true;
    if (bucket == 'agentSessions') {
      if ((body['scope'] as List? ?? []).contains(id)) return true;
      if (object(
        body['sources'],
      ).values.any((v) => object(v)['accountId'] == id)) {
        return true;
      }
    }
    // Legacy sync/read rows have no account column; attachments nest a message key.
    var part = key;
    while (part.startsWith('[')) {
      try {
        final decoded = jsonDecode(part);
        if (decoded is! List || decoded.isEmpty || decoded.first is! String) {
          break;
        }
        part = decoded.first as String;
        if (part == id) return true;
      } catch (_) {
        break;
      }
    }
    return false;
  }

  Future<void> deleteAccount(String id) async {
    await db.transaction(() async {
      final rows = await db
          .customSelect('SELECT bucket,key,account,body FROM records')
          .get();
      final auditIds = <String>{};
      for (final row in rows) {
        final body = object(jsonDecode(row.read<String>('body')));
        if (row.read<String>('bucket') == 'audit' &&
            body['account'] == id &&
            body['id'] is String) {
          auditIds.add(body['id'] as String);
        }
      }
      for (final row in rows) {
        final bucket = row.read<String>('bucket'),
            key = row.read<String>('key');
        final body = object(jsonDecode(row.read<String>('body')));
        if (_belongsToAccount(
              id,
              bucket,
              key,
              row.read<String>('account'),
              body,
            ) ||
            (bucket == 'audit' && auditIds.contains(body['id']))) {
          await remove(bucket, key);
        } else if (bucket == 'installations') {
          void stripBackups(Json record) {
            if (record['rollbackConfigs'] is Map) {
              record['rollbackConfigs'] = {...object(record['rollbackConfigs'])}
                ..remove(id);
            }
            if (record['previous'] is Map) {
              final previous = object(record['previous']);
              stripBackups(previous);
              record['previous'] = previous;
            }
          }

          stripBackups(body);
          await put(bucket, key, body);
        }
      }
      await db.customStatement('DELETE FROM search_index WHERE account=?', [
        id,
      ]);
      // Rebuild FTS segments so deleted text is no longer kept in old segments.
      await db.customStatement(
        "INSERT INTO search_index(search_index) VALUES('rebuild')",
      );
      _deletedAccounts.add(id);
    });
    // Reclaim deleted payload pages and truncate the application's SQLite WAL.
    await db.customStatement('VACUUM');
    await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
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

  Future<bool> saveIncoming(Message m) => db.transaction(() async {
    final isNew = await get('messages', m.key) == null;
    await saveMessage(m);
    return isNew;
  });

  Future<int?> oldestMessage(String account, String conversation) async {
    final row = await db
        .customSelect(
          "SELECT MIN(ts) AS oldest FROM records WHERE bucket='messages' AND account=? AND conversation=?",
          variables: [Variable(account), Variable(conversation)],
        )
        .getSingle();
    return row.readNullable<int>('oldest');
  }

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
