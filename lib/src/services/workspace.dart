import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../core/models.dart';
import '../core/rpc.dart';
import 'plugins.dart';
import 'store.dart';

class Workspace extends ChangeNotifier {
  late Store store;
  late PluginManager plugins;
  late String root;
  bool ready = false, closing = false;
  String? fatal, notice, selectedAccount;
  String startupStatus = '正在准备工作区…';
  void startupProgress(String message) {
    startupStatus = message;
    changed();
  }

  Conversation? selectedConversation;
  List<AccountRef> accounts = [];
  List<Conversation> conversations = [];
  List<Message> messages = [];
  List<Json> outbox = [];
  List<Json> packages = [];
  final clients = <String, RpcClient>{};
  final _starting = <String, Future<RpcClient>>{};
  final sync = <String, SyncState>{};
  final authUrls = <String, String>{};
  final capabilities = <String, Json>{};
  final _busy = <String>{}, _updating = <String>{};
  final _backoff = <String, DateTime>{};
  final _next = <String, DateTime>{};
  final _streams = <String>{};
  Timer? _timer;
  RandomAccessFile? _instanceLock;
  void Function(Message message)? onIncoming;
  AccountRef account(String id) => accounts.firstWhere((a) => a.id == id);
  void changed() {
    if (!closing) notifyListeners();
  }

  Future<void> initialize({String? directory}) async {
    try {
      startupProgress('正在准备本地数据目录…');
      root =
          directory ??
          p.join((await getApplicationSupportDirectory()).path, 'workspace');
      await Directory(root).create(recursive: true);
      _instanceLock = await File(
        p.join(root, '.instance.lock'),
      ).open(mode: FileMode.append);
      try {
        await _instanceLock!.lock(FileLock.exclusive);
      } catch (_) {
        throw const AppFailure('already_running', '此工作区已有应用运行，请切换到已打开的窗口');
      }
      startupProgress('正在打开消息数据库…');
      store = await Store.open(p.join(root, 'imbroglio.sqlite'));
      plugins = PluginManager(
        root,
        store,
        Abi.current().toString().contains('arm64') ? 'arm64' : 'amd64',
      );
      startupProgress('正在载入账号与聊天记录…');
      accounts = (await store.list(
        'accounts',
      )).map(AccountRef.fromJson).toList();
      conversations = (await store.list(
        'conversations',
      )).map(Conversation.fromJson).toList();
      startupProgress('正在载入插件与偏好设置…');
      final seeded = await store.get('settings', 'seeded');
      for (final file
          in seeded == null ? ['assistant', 'summary', 'tasks'] : <String>[]) {
        final manifest = object(
          jsonDecode(await rootBundle.loadString('assets/plugins/$file.json')),
        );
        if (await store.get('packages', manifest['id']) == null) {
          await store.put('packages', manifest['id'], {
            ...manifest,
            'enabled': true,
            'builtin': true,
          });
        }
      }
      await store.put('settings', 'seeded', {'version': 1});
      packages = await store.list('packages');
      selectedAccount = accounts.firstOrNull?.id;
      outbox = await store.list('outbox');
      ready = true;
      _timer = Timer.periodic(const Duration(seconds: 1), (_) => tick());
      changed();
    } catch (e) {
      fatal = '$e';
      changed();
    }
  }

  String get adapterPath {
    final name = 'im_adapter${Platform.isWindows ? '.exe' : ''}';
    final exe = p.dirname(Platform.resolvedExecutable);
    final candidates = [
      p.join(exe, 'adapters', name),
      p.join(exe, '..', 'Resources', 'adapters', name),
      p.join(Directory.current.path, 'build', 'adapters', name),
    ];
    for (final path in candidates) {
      if (File(path).existsSync()) return p.normalize(p.absolute(path));
    }
    throw const AppFailure(
      'adapter_missing',
      '缺少适配器程序。开发环境请先运行 dart run tool/build_adapter.dart',
    );
  }

  Future<RpcClient> client(AccountRef a) async {
    if (_updating.contains(a.platform)) {
      throw const AppFailure('updating', '插件正在更新');
    }
    if (clients[a.id] != null) return clients[a.id]!;
    if (_starting[a.id] != null) return _starting[a.id]!;
    final future = _start(a);
    _starting[a.id] = future;
    try {
      return await future;
    } finally {
      _starting.remove(a.id);
    }
  }

  Future<RpcClient> _start(AccountRef a) async {
    String entry = adapterPath;
    String binary = '';
    if (repositories.containsKey(a.platform)) {
      binary = await plugins.binary(a.platform);
    } else {
      final manifest = packages.firstWhere(
        (m) => m['id'] == a.platform && m['enabled'] == true,
        orElse: () => throw const AppFailure('disabled', '插件未启用'),
      );
      entry = p.join(
        manifest['directory'],
        object(manifest['entrypoints'])[plugins.target],
      );
    }
    final process = await Process.start(entry, [], runInShell: false);
    final rpc = RpcClient(process);
    rpc.events.stream.listen((event) => _event(a, event));
    try {
      final result = object(
        await rpc.call('initialize', {
          'protocol': 1,
          'platform': a.platform,
          'binary': binary,
          'directory': p.join(root, 'accounts', a.id),
          'accountId': a.id,
          'profile': a.profile,
        }, const Duration(seconds: 90)),
      );
      if (result['protocol'] != 1) {
        throw const AppFailure('protocol', '插件协议版本不兼容');
      }
      capabilities[a.id] = object(result['capabilities']);
      clients[a.id] = rpc;
      process.exitCode.then((_) {
        if (identical(clients[a.id], rpc)) {
          clients.remove(a.id);
          for (final c in conversations.where((c) => c.accountId == a.id)) {
            _streams.remove(c.key);
          }
        }
      });
      return rpc;
    } catch (_) {
      await rpc.close();
      rethrow;
    }
  }

  Future<void> _event(AccountRef a, Json event) async {
    if (closing) return;
    final params = object(event['params']);
    switch (event['method']) {
      case 'auth.url':
        authUrls[a.id] = '${params['url']}';
        changed();
      case 'message':
        try {
          final m = Message.fromJson(params);
          if (m.accountId != a.id) {
            throw const AppFailure('identity', '插件消息账号不匹配');
          }
          final exists = await store.get('messages', m.key) != null;
          await store.saveMessage(m);
          if (!exists) {
            await _incrementUnread(m);
            onIncoming?.call(m);
          }
          if (selectedConversation?.key ==
              compositeKey(a.id, m.conversationId)) {
            await loadMessages();
          }
        } catch (_) {
          notice = '事件格式不兼容，等待历史补拉';
          changed();
        }
      case 'sync.ready':
        final key = compositeKey(a.id, '${params['conversationId']}');
        (sync[key] ??= SyncState()).mode = '实时订阅';
        changed();
      case 'sync.gap':
        final key = compositeKey(a.id, '${params['conversationId']}');
        _streams.remove(key);
        final state = sync[key] ??= SyncState();
        state.gap = true;
        state.error = '${params['reason']}';
        state.mode = '补拉中';
        changed();
    }
  }

  Future<AccountRef> addAccount(String platform, String label) async {
    final a = AccountRef(
      id: newId(),
      platform: platform,
      label: label,
      enabled: false,
    );
    accounts.add(a);
    await store.put('accounts', a.id, a.toJson());
    selectedAccount = a.id;
    changed();
    return a;
  }

  Future<void> saveAccount(AccountRef a) async {
    final index = accounts.indexWhere((x) => x.id == a.id);
    accounts[index] = a;
    await store.put('accounts', a.id, a.toJson());
    changed();
  }

  Future<void> renameAccount(String id, String label) async {
    final name = label.trim();
    if (name.isEmpty) throw const AppFailure('name', '账号名称不能为空');
    await saveAccount(account(id).copyWith(label: name));
  }

  Future<Json> authenticate(
    AccountRef a, {
    bool configure = false,
    Json config = const {},
  }) async {
    final rpc = await client(a);
    if (configure) {
      await rpc.call('auth.configure', config, const Duration(minutes: 6));
    }
    await rpc.call('auth.login', {}, const Duration(minutes: 6));
    final result = object(await rpc.call('auth.status'));
    authUrls.remove(a.id);
    changed();
    return result;
  }

  Future<void> connect(
    AccountRef a, {
    String profile = '',
    String organization = '',
    String userId = '',
  }) async {
    await clients.remove(a.id)?.close();
    final connected = a.copyWith(
      profile: profile,
      organization: organization,
      userId: userId,
      enabled: true,
    );
    await saveAccount(connected);
    await refreshConversations(connected);
  }

  Future<void> disconnect(AccountRef a, {bool logout = false}) async {
    await saveAccount(a.copyWith(enabled: false));
    if (logout) {
      final rpc = await client(a);
      await rpc.call('auth.logout');
    }
    await clients.remove(a.id)?.close();
    for (final c in conversations.where((c) => c.accountId == a.id)) {
      _streams.remove(c.key);
    }
    changed();
  }

  Future<void> refreshConversations(AccountRef a, {bool more = false}) async {
    final rpc = await client(a);
    final page = more
        ? await store.get('cursors', 'conversations:${a.id}')
        : null;
    final result = object(
      await rpc.call('conversations', {
        if (page?['cursor'] != null && page!['cursor'] != '')
          'cursor': page['cursor'],
      }),
    );
    for (final j in (result['items'] as List? ?? [])) {
      var c = Conversation.fromJson(object(j));
      if (c.accountId != a.id) throw const AppFailure('identity', '会话账号不匹配');
      final old = conversations.where((x) => x.key == c.key).firstOrNull;
      c = c.copyWith(
        watched: old?.watched ?? false,
        unread: old?.unread ?? c.unread,
      );
      conversations.removeWhere((x) => x.key == c.key);
      conversations.add(c);
      await store.put(
        'conversations',
        c.key,
        c.toJson(),
        account: a.id,
        ts: c.updatedAt,
      );
    }
    await store.put('cursors', 'conversations:${a.id}', {
      'cursor': result['cursor'],
    });
    conversations.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    changed();
  }

  Future<void> selectConversation(Conversation c) async {
    selectedAccount = c.accountId;
    selectedConversation = c.copyWith(unread: 0);
    await _saveConversation(selectedConversation!);
    await loadMessages();
    await syncConversation(c);
  }

  Future<void> _saveConversation(Conversation c) async {
    conversations.removeWhere((x) => x.key == c.key);
    conversations.add(c);
    await store.put(
      'conversations',
      c.key,
      c.toJson(),
      account: c.accountId,
      ts: c.updatedAt,
    );
    changed();
  }

  Future<void> watch(Conversation c, bool value) async {
    await _saveConversation(c.copyWith(watched: value));
    if (!value && _streams.remove(c.key)) {
      await clients[c.accountId]?.call('unsubscribe', {'conversationId': c.id});
    }
  }

  Future<void> loadMessages() async {
    final c = selectedConversation;
    if (c == null) return;
    final data =
        (await store.list(
            'messages',
            account: c.accountId,
            conversation: c.id,
            limit: 500,
          )).map(Message.fromJson).toList()
          ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    if (selectedConversation?.key == c.key) {
      messages = data;
      outbox = await store.list('outbox');
      changed();
    }
  }

  Future<void> _incrementUnread(Message m) async {
    final c = conversations
        .where((c) => c.accountId == m.accountId && c.id == m.conversationId)
        .firstOrNull;
    if (c != null) {
      await _saveConversation(
        c.copyWith(
          unread: selectedConversation?.key == c.key ? 0 : c.unread + 1,
          updatedAt: m.timestamp,
        ),
      );
    }
  }

  Future<void> syncConversation(Conversation c, {bool older = false}) async {
    if (!_busy.add(c.key)) return;
    final state = sync[c.key] ??= SyncState();
    try {
      final a = account(c.accountId);
      if (!a.enabled) return;
      final rpc = await client(a);
      final saved = await store.get('cursors', c.key);
      final current = await store.list(
        'messages',
        account: a.id,
        conversation: c.id,
        limit: 10000,
      );
      int? before;
      if (older && current.isNotEmpty) {
        before = current
            .map((e) => e['timestamp'] as int)
            .reduce((a, b) => a < b ? a : b);
      }
      var since = older
          ? null
          : (saved?['resumeSince'] ?? saved?['timestamp']) as int?;
      String? cursor = older
          ? (saved?['historyCursor'] as String?)
          : (saved?['resumeCursor'] as String?);
      if (older && cursor != null) before = saved?['historyBefore'] as int?;
      var pages = 0, hasMore = false, maxTime = since ?? 0;
      do {
        final result = object(
          await rpc.call('messages', {
            'conversation': c.toJson(),
            'before': ?before,
            if (since != null) 'since': since - 2000,
            'cursor': ?cursor,
          }),
        );
        final items = (result['items'] as List? ?? [])
            .map((j) => Message.fromJson(object(j)))
            .toList();
        for (final m in items) {
          if (m.accountId != a.id || m.conversationId != c.id) {
            throw const AppFailure('identity', '消息来源不匹配');
          }
          final existed = await store.get('messages', m.key) != null;
          await store.saveMessage(m);
          if (!older && saved != null && !existed) {
            await _incrementUnread(m);
            onIncoming?.call(m);
          }
          if (m.timestamp > maxTime) maxTime = m.timestamp;
        }
        final next = '${result['cursor'] ?? ''}';
        hasMore = result['hasMore'] == true;
        if (next.isEmpty || next == cursor) {
          cursor = null;
          if (!older &&
              since != null &&
              hasMore &&
              maxTime > since + 2000 &&
              a.platform == 'dingtalk') {
            since = maxTime;
          } else {
            break;
          }
        } else {
          cursor = next;
        }
      } while (!older && since != null && ++pages < 10);
      state.gap = since != null && hasMore;
      final checkpoint = <String, dynamic>{...?saved};
      if (older) {
        checkpoint['historyCursor'] = cursor;
        checkpoint['historyBefore'] = before;
      } else if (maxTime > 0) {
        if (!state.gap) {
          checkpoint['timestamp'] = maxTime;
          checkpoint.remove('resumeCursor');
          checkpoint.remove('resumeSince');
        } else {
          checkpoint['resumeSince'] = since;
          checkpoint['resumeCursor'] = cursor;
        }
      }
      await store.put('cursors', c.key, checkpoint);
      state.error = state.gap ? '可能仍有未补齐消息；请加载历史记录' : '';
      state.lastSuccess = DateTime.now().millisecondsSinceEpoch;
      state.failures = 0;
      _backoff.remove(c.key);
      if (a.platform == 'dingtalk' && c.watched && !_streams.contains(c.key)) {
        _streams.add(c.key);
        try {
          await rpc.call('subscribe', {'conversation': c.toJson()});
        } catch (e) {
          _streams.remove(c.key);
          state.error = '$e';
        }
      }
      if (selectedConversation?.key == c.key) await loadMessages();
      await store.put('sync', c.key, state.toJson());
    } catch (e) {
      state.failures++;
      state.error = '$e';
      state.mode = e is AppFailure && e.code == 'authorization'
          ? '权限不足'
          : '定时同步';
      final delay = e is AppFailure && e.retryAfter != null
          ? e.retryAfter!
          : (5 * (1 << state.failures.clamp(0, 6)));
      _backoff[c.key] = DateTime.now().add(Duration(seconds: delay));
    } finally {
      _busy.remove(c.key);
      changed();
    }
  }

  void tick() {
    if (closing) return;
    final now = DateTime.now();
    for (final a in accounts.where(
      (a) => a.enabled && !_updating.contains(a.platform),
    )) {
      final key = 'account:${a.id}';
      if (!(_next[key]?.isAfter(now) ?? false) && _busy.add(key)) {
        _next[key] = now.add(const Duration(seconds: 60));
        refreshConversations(a)
            .catchError((Object e) {
              notice = '${a.label}：$e';
              changed();
            })
            .whenComplete(() => _busy.remove(key));
      }
    }
    for (final c in conversations.where(
      (c) => c.watched || c.key == selectedConversation?.key,
    )) {
      if (!account(c.accountId).enabled ||
          _updating.contains(account(c.accountId).platform)) {
        continue;
      }
      if ((_backoff[c.key]?.isAfter(now) ?? false) ||
          (_next[c.key]?.isAfter(now) ?? false)) {
        continue;
      }
      _next[c.key] = now.add(
        Duration(seconds: c.key == selectedConversation?.key ? 5 : 30),
      );
      unawaited(syncConversation(c));
    }
  }

  Future<void> send(
    Conversation c,
    String text, {
    Message? reply,
    String? attachment,
    bool image = false,
    bool markdown = false,
  }) async {
    final id = newId();
    final record = {
      'id': id,
      'accountId': c.accountId,
      'conversationId': c.id,
      'text': text,
      'state': 'sending',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };
    await store.put('outbox', id, record, ts: record['timestamp'] as int);
    outbox = await store.list('outbox');
    changed();
    try {
      final result = await (await client(account(c.accountId))).call('send', {
        'conversation': c.toJson(),
        'text': text,
        'reply': reply?.toJson(),
        'attachment': attachment,
        'image': image,
        'markdown': markdown,
        'idempotencyKey': id,
        'approved': true,
      });
      await store.put('outbox', id, {
        ...record,
        'state': 'confirmed',
        'result': result,
      }, ts: record['timestamp'] as int);
      await store.audit('message.send', {
        'account': c.accountId,
        'conversation': c.id,
        'id': id,
        'state': 'confirmed',
      });
      await syncConversation(c);
    } catch (e) {
      final state =
          e is AppFailure &&
              [
                'approval',
                'authorization',
                'not_installed',
                'unsupported',
                'confirmation',
              ].contains(e.code)
          ? 'failed'
          : 'unknown';
      await store.put('outbox', id, {
        ...record,
        'state': state,
        'error': '$e',
      }, ts: record['timestamp'] as int);
      rethrow;
    } finally {
      outbox = await store.list('outbox');
      changed();
    }
  }

  Future<List<ResourceRef>> search(
    String query,
    Set<String> scope, {
    bool online = true,
  }) async {
    final results = await store.search(query, scope);
    if (online) {
      for (final id in scope) {
        try {
          final a = account(id);
          if (!a.enabled) continue;
          try {
            final found = object(
              await (await client(a)).call('messages.search', {'query': query}),
            );
            for (final raw in found['items'] as List? ?? []) {
              final m = Message.fromJson(object(raw));
              if (m.accountId != id) {
                throw const AppFailure('identity', '消息来源不匹配');
              }
              await store.saveMessage(m);
              results.add(
                ResourceRef(
                  accountId: id,
                  id: m.id,
                  title: m.sender,
                  text: m.text,
                  kind: 'message',
                  conversationId: m.conversationId,
                  updatedAt: m.timestamp,
                ),
              );
            }
          } catch (e) {
            notice = '${a.label} 在线消息搜索不完整：$e';
          }
          final data = object(
            await (await client(a)).call('resources.search', {'query': query}),
          );
          for (final j in data['items'] as List? ?? []) {
            final resource = ResourceRef.fromJson(object(j));
            if (resource.accountId != id) {
              throw const AppFailure('identity', '资源来源不匹配');
            }
            await store.put(
              'resources',
              compositeKey(id, resource.id),
              resource.toJson(),
              account: id,
              text: '${resource.title}\n${resource.text}',
              ts: resource.updatedAt,
            );
            results.add(resource);
          }
        } catch (e) {
          notice = '${account(id).label} 在线搜索不完整：$e';
        }
      }
    }
    changed();
    return {
      for (final r in results) compositeKey(r.accountId, r.id): r,
    }.values.toList();
  }

  Future<String> readResource(ResourceRef r) async {
    if (r.kind == 'message') return r.text;
    final data = object(
      await (await client(
        account(r.accountId),
      )).call('resources.read', {'id': r.url.isEmpty ? r.id : r.url}),
    );
    final updated = {...r.toJson(), 'text': '${data['text']}'};
    await store.put(
      'resources',
      compositeKey(r.accountId, r.id),
      updated,
      account: r.accountId,
      text: '${r.title}\n${data['text']}',
      ts: r.updatedAt,
    );
    return '${data['text']}';
  }

  Future<void> openContact(String accountId, Json contact) async {
    final c = Conversation.fromJson(
      object(
        await (await client(
          account(accountId),
        )).call('conversation.open', {'contact': contact}),
      ),
    );
    if (c.accountId != accountId) throw const AppFailure('identity', '会话身份不匹配');
    await _saveConversation(c);
    await selectConversation(c);
  }

  Future<String> downloadAttachment(Message message, String resourceId) async {
    final result = object(
      await (await client(account(message.accountId))).call(
        'attachment.download',
        {'message': message.toJson(), 'resourceId': resourceId},
      ),
    );
    final file = '${result['path']}';
    if (!p.isWithin(
      p.join(root, 'accounts', message.accountId, 'downloads'),
      p.normalize(file),
    )) {
      throw const AppFailure('path', '附件路径不在账号下载目录');
    }
    return file;
  }

  Future<void> updatePlugin(
    String id,
    Json release,
    void Function(String) progress,
  ) async {
    if (!_updating.add(id)) throw const AppFailure('busy', '插件正在更新');
    final backupId = newId();
    final backups = <String, String>{};
    try {
      for (final a in accounts.where((a) => a.platform == id)) {
        if (_starting[a.id] != null) await _starting[a.id];
        final active = clients[a.id];
        if (active?.hasPending == true) {
          throw const AppFailure('busy', '仍有请求正在执行，请完成后再更新');
        }
        await clients.remove(a.id)?.close();
        for (final c in conversations.where((c) => c.accountId == a.id)) {
          _streams.remove(c.key);
        }
        final config = Directory(p.join(root, 'accounts', a.id, 'config'));
        if (await config.exists()) {
          await _copyDirectory(
            config,
            Directory(p.join(root, 'backups', id, backupId, a.id)),
          );
        }
      }
      for (final a in accounts.where((a) => a.platform == id)) {
        final folder = p.join(root, 'backups', id, backupId, a.id);
        if (await Directory(folder).exists()) backups[a.id] = folder;
      }
      await plugins.installOfficial(id, release, progress);
      final installed = await plugins.installation(id);
      await store.put('installations', id, {
        ...installed!,
        'rollbackConfigs': backups,
      });
    } finally {
      _updating.remove(id);
      changed();
    }
  }

  Future<void> rollbackPlugin(String id) async {
    if (!_updating.add(id)) throw const AppFailure('busy', '插件正在更新');
    try {
      final current = await plugins.installation(id);
      for (final a in accounts.where((a) => a.platform == id)) {
        if (clients[a.id]?.hasPending == true) {
          throw const AppFailure('busy', '请等待当前请求完成');
        }
        await clients.remove(a.id)?.close();
      }
      await plugins.rollback(id);
      for (final entry in object(current?['rollbackConfigs']).entries) {
        final source = Directory(entry.value);
        if (!p.isWithin(p.join(root, 'backups'), source.path)) {
          throw const AppFailure('path', '无效备份路径');
        }
        final destination = Directory(
          p.join(root, 'accounts', entry.key, 'config'),
        );
        if (await destination.exists()) {
          await destination.delete(recursive: true);
        }
        await _copyDirectory(source, destination);
      }
      _streams.clear();
    } finally {
      _updating.remove(id);
      changed();
    }
  }

  Future<void> _copyDirectory(Directory source, Directory dest) async {
    await dest.create(recursive: true);
    await for (final f in source.list(recursive: true, followLinks: false)) {
      final path = p.join(dest.path, p.relative(f.path, from: source.path));
      if (f is File) {
        await File(path).parent.create(recursive: true);
        await f.copy(path);
      }
    }
  }

  Future<void> stopPlatform(String platform) async {
    for (final a in accounts.where((a) => a.platform == platform)) {
      await disconnect(a);
    }
  }

  Future<void> close() async {
    closing = true;
    _timer?.cancel();
    await Future.wait(clients.values.map((c) => c.close()));
    clients.clear();
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (_busy.isNotEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    await store.close();
    await _instanceLock?.unlock();
    await _instanceLock?.close();
  }
}
