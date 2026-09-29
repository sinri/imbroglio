import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import '../core/models.dart';
import '../core/startup_trace.dart';
import '../core/conversation_blacklist.dart';
import '../core/feishu_auth.dart';
import '../core/normalize.dart';
import '../core/rpc.dart';
import '../core/diagnostics.dart';
import 'plugins.dart';
import 'store.dart';
import 'activity.dart';

class Workspace extends ChangeNotifier {
  final startupTrace = StartupTrace();
  String? _startupTracePath;
  Future<void> saveStartupTrace() async {
    final path = _startupTracePath;
    if (path != null) await startupTrace.save(path);
  }

  late final activities = ActivityLog(changed);
  late Store store;
  late PluginManager plugins;
  late String root;
  bool ready = false, closing = false;
  String? fatal, selectedAccount;
  final notices = <String>[];
  String? get notice => notices.lastOrNull;
  set notice(String? value) {
    if (value == null) {
      notices.clear();
    } else if (!notices.contains(value)) {
      notices.add(value);
    }
  }

  String startupStatus = '正在准备工作区…';
  void startupProgress(String message) {
    startupTrace.mark(message);
    startupStatus = message;
    changed();
  }

  Conversation? selectedConversation;
  List<AccountRef> accounts = [];
  Iterable<AccountRef> get visibleAccounts =>
      accounts.where((a) => !a.signedOut);
  List<Conversation> conversations = [];
  List<Message> messages = [];
  int messageLimit = 100;
  bool loadingEarlier = false;
  final _attachments = <String, Future<String>>{};
  List<Json> outbox = [];
  List<Json> packages = [];
  final clients = <String, RpcClient>{};
  final _starting = <String, Future<RpcClient>>{};
  final sync = <String, SyncState>{};
  final authUrls = <String, String>{};
  final deletedAccountIds = <String>{};
  final activeAgentAccounts = <String>{};
  final _deletingAccounts = <String>{};
  int _eventsInFlight = 0;
  bool isRemovingAccount(String id) =>
      _deletingAccounts.contains(id) || deletedAccountIds.contains(id);
  final _authorizations = <String, Completer<void>>{};
  final capabilities = <String, Json>{};
  final _busy = <String>{}, _updating = <String>{};
  final _backoff = <String, DateTime>{};
  final _next = <String, DateTime>{};
  final _pendingChecks = <String>{};
  final _streams = <String>{};
  final blockedConversations = <String>{};
  final diagnostics = <Json>[];
  final _subscriptionRetry = <String, DateTime>{};
  final _subscriptionFailures = <String, int>{};

  Future<void> recordDiagnostic(AccountRef a, Json input) async {
    if (closing ||
        deletedAccountIds.contains(a.id) ||
        _deletingAccounts.contains(a.id)) {
      return;
    }
    final row = <String, dynamic>{
      'id': newId(),
      'accountId': a.id,
      'account': a.label,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'operation': diagnosticText('${input['operation'] ?? 'CLI'}'),
      'detail': diagnosticText('${input['detail'] ?? ''}'),
      'conversationId': '${input['conversationId'] ?? ''}',
      if (input['exitCode'] is int) 'exitCode': input['exitCode'],
    };
    await store.db.transaction(() async {
      await store.put(
        'diagnostics',
        row['id'],
        row,
        account: a.id,
        ts: row['timestamp'],
      );
      final saved = await store.list('diagnostics', limit: 1000);
      for (final old in saved.skip(200)) {
        await store.remove('diagnostics', old['id']);
      }
      diagnostics
        ..clear()
        ..addAll(saved.take(200));
    });
    changed();
  }

  List<ConversationBlacklistRule> _conversationBlacklist = [];
  List<ConversationBlacklistRule> get conversationBlacklist =>
      List.unmodifiable(_conversationBlacklist);

  bool isConversationExcluded(Conversation c) {
    final current = conversations.where((v) => v.key == c.key).firstOrNull ?? c;
    return _conversationBlacklist.any((rule) => rule.matches(current));
  }

  bool _excludedKey(String accountId, String conversationId) {
    final c = conversations
        .where((c) => c.accountId == accountId && c.id == conversationId)
        .firstOrNull;
    return c != null && isConversationExcluded(c);
  }

  Future<void> saveConversationBlacklist(
    List<ConversationBlacklistRule> rules,
  ) async {
    final snapshot = List<ConversationBlacklistRule>.of(rules);
    await store.put('settings', 'conversationBlacklist', {
      'rules': snapshot.map((r) => r.toJson()).toList(),
    });
    _conversationBlacklist = snapshot;
    _next.clear();
    changed();
    await _stopExcludedSubscriptions();
  }

  Future<void> _stopExcludedSubscriptions() async {
    for (final c in conversations.toList()) {
      if (!isConversationExcluded(c) || !_streams.contains(c.key)) continue;
      try {
        await clients[c.accountId]?.call('unsubscribe', {
          'conversationId': c.id,
        });
        _streams.remove(c.key);
      } catch (e) {
        notice = '停止会话订阅失败：${c.title}：$e';
        changed();
      }
    }
  }

  Future<void> loadSyncPolicies() async {
    final blacklist = await store.get('settings', 'conversationBlacklist');
    _conversationBlacklist = (blacklist?['rules'] as List? ?? [])
        .map((r) => ConversationBlacklistRule.fromJson(object(r)))
        .toList();
    diagnostics
      ..clear()
      ..addAll(await store.list('diagnostics', limit: 200));
    for (final row in await store.list('syncPolicies', limit: 100000)) {
      final key = compositeKey(row['accountId'], row['conversationId']);
      if (row['blocked'] == true) {
        blockedConversations.add(key);
        (sync[key] ??= SyncState())
          ..mode = '保密群'
          ..error = '保密群不支持读取消息，已停止拉取';
      }
    }
    for (final row in await store.list('subscriptionRetry', limit: 100000)) {
      final key = compositeKey(row['accountId'], row['conversationId']);
      _subscriptionFailures[key] = row['failures'] as int? ?? 0;
      _subscriptionRetry[key] = DateTime.fromMillisecondsSinceEpoch(
        row['retryAt'] as int? ?? 0,
      );
    }
  }

  Future<void> _subscriptionFailed(
    AccountRef a,
    String conversationId,
    String reason,
  ) async {
    final key = compositeKey(a.id, conversationId);
    final failures = (_subscriptionFailures[key] ?? 0) + 1;
    _subscriptionFailures[key] = failures;
    final retry = DateTime.now().add(
      Duration(
        seconds: (30 * (1 << (failures - 1).clamp(0, 5))).clamp(30, 900),
      ),
    );
    _subscriptionRetry[key] = retry;
    final state = sync[key] ??= SyncState();
    state.mode = '定时同步（订阅待重连）';
    state.error = diagnosticText(reason);
    activities
        .begin('subscription:$key', '恢复实时订阅', a.label)
        .finish(state: 'waiting', detail: state.error, retryAt: retry);
    await store.put('subscriptionRetry', key, {
      'accountId': a.id,
      'conversationId': conversationId,
      'failures': failures,
      'retryAt': retry.millisecondsSinceEpoch,
    }, account: a.id);
  }

  Future<void> _blockConfidential(Conversation c) async {
    blockedConversations.add(c.key);
    _streams.remove(c.key);
    final state = sync[c.key] ??= SyncState();
    state
      ..mode = '保密群'
      ..error = '保密群不支持读取消息，已停止拉取'
      ..gap = false;
    await store.put('syncPolicies', c.key, {
      'accountId': c.accountId,
      'conversationId': c.id,
      'blocked': true,
    }, account: c.accountId);
    try {
      await clients[c.accountId]?.call('unsubscribe', {'conversationId': c.id});
    } catch (_) {}
  }

  final _historyDone = <String>{};
  final senderProfiles = <String, Json>{};
  final _resolvingSenders = <String>{};
  final _senderQueue = <String, Map<String, Message>>{};
  final _sendingAccounts = <String, int>{};
  final _readAt = <String, int>{};
  final _seenPlatformTime = <String, int>{};
  final int startedAt = DateTime.now().millisecondsSinceEpoch;
  bool chatVisible = true;
  bool windowFocused = true;
  int get historyCutoff =>
      DateTime.now().subtract(const Duration(days: 7)).millisecondsSinceEpoch;
  bool isReading(Conversation c) =>
      chatVisible && windowFocused && selectedConversation?.key == c.key;
  Timer? _timer;
  RandomAccessFile? _instanceLock;
  void Function(Message message)? onIncoming;
  VoidCallback? requestMessagesPage;
  AccountRef account(String id) => accounts.firstWhere((a) => a.id == id);
  void changed() {
    final visibleIds = visibleAccounts.map((a) => a.id).toSet();
    if (!visibleIds.contains(selectedAccount)) {
      selectedAccount = visibleAccounts.firstOrNull?.id;
    }
    if (selectedConversation != null &&
        !visibleIds.contains(selectedConversation!.accountId)) {
      selectedConversation = null;
      messages = [];
    }
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
      _startupTracePath = p.join(root, 'startup-timing.json');
      startupProgress('正在打开消息数据库…');
      store = await startupTrace.measure(
        'database.open',
        () => Store.open(p.join(root, 'imbroglio.sqlite'), trace: startupTrace),
      );
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
      final keys = conversations.map((c) => c.key).toList();
      final reads = await store.getMany('readState', keys);
      final cursors = await store.getMany('cursors', keys);
      for (final c in conversations) {
        final read = reads[c.key];
        _readAt[c.key] = read?['timestamp'] as int? ?? 0;
        _seenPlatformTime[c.key] = read?['platformTime'] as int? ?? -1;
        final cursor = cursors[c.key];
        if (cursor?['historyDone'] == true) _historyDone.add(c.key);
      }
      startupTrace.mark('conversation-state.loaded');
      await loadSyncPolicies();
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
      if (seeded == null) {
        await store.put('settings', 'seeded', {'version': 1});
      }
      packages = await store.list('packages');
      selectedAccount = visibleAccounts.firstOrNull?.id;
      outbox = await store.list('outbox');
      startupTrace.mark('workspace.ready');
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
    if (deletedAccountIds.contains(a.id) || _deletingAccounts.contains(a.id)) {
      throw const AppFailure('deleted', '账号正在清理或已删除');
    }
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

  Future<RpcClient> _start(AccountRef a) => activities.run(
    'connect:${a.id}',
    '连接消息服务',
    a.label,
    (_) => _startClient(a),
  );

  Future<RpcClient> _startClient(AccountRef a) async {
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
    if (isRemovingAccount(a.id)) return;
    _eventsInFlight++;
    try {
      await _handleEvent(a, event);
    } finally {
      _eventsInFlight--;
    }
  }

  Future<void> _handleEvent(AccountRef a, Json event) async {
    if (deletedAccountIds.contains(a.id) || _deletingAccounts.contains(a.id)) {
      return;
    }
    if (closing) return;
    final params = object(event['params']);
    switch (event['method']) {
      case 'diagnostic':
        await recordDiagnostic(a, params);
      case 'auth.url':
        if (!_authorizations.containsKey(a.id)) return;
        authUrls[a.id] = '${params['url']}';
        changed();
      case 'message':
        try {
          final m = Message.fromJson(params);
          if (m.accountId != a.id) {
            throw const AppFailure('identity', '插件消息账号不匹配');
          }
          if (_excludedKey(m.accountId, m.conversationId)) return;
          final isNew = await store.saveIncoming(m);
          if (isNew) {
            await _incrementUnread(m);
            if (!_isOwn(m) &&
                m.timestamp >= startedAt &&
                m.timestamp >
                    (_readAt[compositeKey(m.accountId, m.conversationId)] ??
                        0)) {
              onIncoming?.call(m);
            }
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
        if (blockedConversations.contains(key) ||
            _excludedKey(a.id, '${params['conversationId']}')) {
          return;
        }
        final wasRetrying = _subscriptionFailures.remove(key) != null;
        _subscriptionRetry.remove(key);
        if (wasRetrying) {
          activities
              .begin('subscription:$key', '恢复实时订阅', a.label)
              .finish(detail: '实时订阅已恢复');
        }
        await store.remove('subscriptionRetry', key);
        (sync[key] ??= SyncState()).mode = '实时订阅';
        changed();
      case 'sync.gap':
        final key = compositeKey(a.id, '${params['conversationId']}');
        if (blockedConversations.contains(key) ||
            _excludedKey(a.id, '${params['conversationId']}')) {
          return;
        }
        if (params['disconnected'] == true) {
          _streams.remove(key);
          await _subscriptionFailed(
            a,
            '${params['conversationId']}',
            '${params['reason']}',
          );
        }
        final state = sync[key] ??= SyncState();
        state.gap = true;
        state.error = diagnosticText('${params['reason']}');
        if (params['disconnected'] != true) state.mode = '补拉中';
        _next.remove(key);
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
    if (isRemovingAccount(a.id)) {
      throw const AppFailure('deleted', '账号正在清理或已删除');
    }
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
    void Function(String stage)? onStage,
    Future<List<String>?> Function(Json permissions)? onPermissions,
  }) async {
    if (_authorizations.containsKey(a.id)) {
      throw const AppFailure('busy', '授权正在进行');
    }
    final cancelled = Completer<void>();
    _authorizations[a.id] = cancelled;
    final cancellation = cancelled.future.then<Never>(
      (_) => throw const AppFailure('cancelled', '授权已中止'),
    );
    Future<T> wait<T>(Future<T> operation) =>
        Future.any([operation, cancellation]);
    var stage = configure
        ? '应用初始化'
        : a.platform == 'feishu'
        ? '检查现有授权'
        : '用户授权';
    void progress(String next) {
      stage = next;
      authUrls.remove(a.id);
      onStage?.call(stage);
      changed();
    }

    try {
      progress(stage);
      final rpc = await wait(client(a));
      if (configure) {
        await wait(
          rpc.call('auth.configure', config, const Duration(minutes: 6)),
        );
      }
      Json loginArgs = {};
      String? expectedAppId;
      if (a.platform == 'feishu') {
        progress('检查现有授权');
        final prior = object(await wait(rpc.call('auth.status')));
        final priorUser = feishuUser(prior);
        final valid = feishuVerified(priorUser);
        if (!valid &&
            config['forceAuthorization'] != true &&
            !['missing', 'not_configured'].contains(priorUser['status'])) {
          throw AppFailure(
            'authentication',
            '暂时无法验证已有授权，请重试；也可主动选择重新授权。${diagnosticText('${priorUser['message'] ?? ''}')}',
          );
        }
        if (valid && a.userId.isNotEmpty && a.userId != priorUser['openId']) {
          throw const AppFailure('identity', '当前飞书用户与已绑定账号不一致');
        }
        final app = object(await wait(rpc.call('auth.scopes')));
        if (app['appId'] is! String ||
            (app['appId'] as String).isEmpty ||
            app['userScopes'] is! List ||
            app['appId'] != object(prior['status'])['appId']) {
          throw const AppFailure('contract', '飞书应用权限查询结果与当前应用不一致');
        }
        expectedAppId = app['appId'] as String;
        final granted = feishuScopes(priorUser);
        final appScopes = (app['userScopes'] as List)
            .whereType<String>()
            .toSet();
        final canReuse =
            valid &&
            config['forceAuthorization'] != true &&
            granted.containsAll(feishuReadScopes);
        final permissions = <String, dynamic>{
          'appId': app['appId'],
          'userId': priorUser['openId'],
          'canReuse': canReuse,
          'granted': granted.toList(),
          'appScopes': appScopes.toList(),
        };
        final selected = onPermissions == null
            ? (canReuse ? <String>[] : feishuReadScopes.toList())
            : await wait(onPermissions(permissions));
        if (selected == null) throw const AppFailure('cancelled', '授权已中止');
        if (canReuse && granted.containsAll(selected)) {
          prior['userId'] = priorUser['openId'];
          prior['canSend'] = granted.containsAll(feishuSendScopes);
          return prior;
        }
        final requested = {...granted, ...feishuReadScopes, ...selected};
        final unavailable = requested.difference(appScopes).difference(granted);
        if (unavailable.isNotEmpty) {
          throw AppFailure(
            'permission',
            '应用尚未开通所选功能的权限：${(unavailable.toList()..sort()).join('、')}。'
                '请先在飞书开放平台开通后重试',
          );
        }
        loginArgs = {'scopes': requested.toList()..sort()};
      }
      progress('用户授权');
      final login = object(
        await wait(
          rpc.call('auth.login', loginArgs, const Duration(minutes: 6)),
        ),
      );
      progress('连接验证');
      final result = object(await wait(rpc.call('auth.status')));
      if (a.platform == 'feishu') {
        final user = object(
          object(object(result['status'])['identities'])['user'],
        );
        final openId = user['openId'];
        if (user['available'] != true ||
            user['verified'] != true ||
            !['ready', 'needs_refresh'].contains(user['status']) ||
            openId is! String ||
            openId.isEmpty) {
          throw AppFailure(
            'authentication',
            '飞书用户身份未通过验证，请检查网络或重新授权。'
                '${diagnosticText('${user['message'] ?? ''}')}',
          );
        }
        if (login['userId'] != openId ||
            (a.userId.isNotEmpty && a.userId != openId) ||
            object(result['status'])['appId'] != expectedAppId) {
          throw const AppFailure('identity', '飞书登录与验证的用户身份不一致，请重新授权');
        }
        final scopes = feishuScopes(user);
        if (!scopes.containsAll(feishuReadScopes)) {
          throw const AppFailure('permission', '基础消息读取权限未授予，暂时无法连接；请开通权限后重试');
        }
        result['userId'] = openId;
        result['canSend'] =
            scopes.contains('im:message.send_as_user') &&
            scopes.contains('im:message');
      }
      if (login['warning'] is String) {
        notice = '${a.label}：${diagnosticText(login['warning'] as String)}';
        result['warning'] = login['warning'];
        result['missingScopes'] = login['missingScopes'];
      }
      return result;
    } catch (e) {
      if (cancelled.isCompleted) {
        throw const AppFailure('cancelled', '授权已中止');
      }
      throw AppFailure(
        e is AppFailure ? e.code : 'authorization',
        '$stage失败：${diagnosticText(e is AppFailure ? e.message : '$e')}',
        retryAfter: e is AppFailure ? e.retryAfter : null,
      );
    } finally {
      _authorizations.remove(a.id);
      authUrls.remove(a.id);
      changed();
    }
  }

  void cancelAuthentication(AccountRef a) {
    final cancellation = _authorizations[a.id];
    if (cancellation == null || cancellation.isCompleted) return;
    cancellation.complete();
    clients[a.id]?.cancelPending({
      'auth.configure',
      'auth.login',
      'auth.status',
      'auth.scopes',
    });
    authUrls.remove(a.id);
    changed();
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
      signedOut: false,
    );
    await saveAccount(connected.copyWith(enabled: false));
    await refreshConversations(connected);
    await saveAccount(connected);
  }

  Future<void> disconnect(AccountRef a, {bool logout = false}) async {
    await saveAccount(a.copyWith(enabled: false));
    try {
      if (logout) {
        final rpc = await client(a);
        await rpc.call('auth.logout');
        await saveAccount(
          account(a.id).copyWith(signedOut: true, enabled: false),
        );
      }
    } finally {
      try {
        await clients.remove(a.id)?.close();
      } finally {
        for (final c in conversations.where((c) => c.accountId == a.id)) {
          _streams.remove(c.key);
        }
        authUrls.remove(a.id);
        changed();
      }
    }
  }

  Future<void> deleteAccount(AccountRef a, {bool logout = true}) async {
    if (_updating.isNotEmpty ||
        activeAgentAccounts.contains(a.id) ||
        _authorizations.containsKey(a.id) ||
        _starting.isNotEmpty ||
        _deletingAccounts.isNotEmpty) {
      throw const AppFailure('busy', '请先结束授权、Agent 任务或插件更新，再清理账号');
    }
    // Stop scheduling this account before waiting for outstanding work.
    await saveAccount(account(a.id).copyWith(enabled: false));
    if (logout && !account(a.id).signedOut) {
      await disconnect(account(a.id), logout: true);
    }
    if (!_deletingAccounts.add(a.id)) throw const AppFailure('busy', '账号正在清理');
    try {
      await clients.remove(a.id)?.close();
      final deadline = DateTime.now().add(const Duration(seconds: 5));
      while (_eventsInFlight > 0 ||
          _busy.isNotEmpty ||
          activities.runningCount > 0 ||
          (_sendingAccounts[a.id] ?? 0) > 0) {
        if (DateTime.now().isAfter(deadline)) {
          throw const AppFailure('busy', '后台任务尚未结束，账号已暂停，请稍后重试清理');
        }
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
      if (activeAgentAccounts.contains(a.id)) {
        throw const AppFailure('busy', '请先结束此账号的 Agent 任务');
      }
      for (final segment in [a.id, a.platform]) {
        if (segment.isEmpty ||
            segment == '.' ||
            segment == '..' ||
            p.basename(segment) != segment) {
          throw const AppFailure('path', '账号数据路径无效');
        }
      }
      await _deleteAccountPath(p.join(root, 'accounts', a.id));
      final backupRoot = p.join(root, 'backups', a.platform);
      await _checkAccountPath(backupRoot);
      if (await FileSystemEntity.type(backupRoot, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const AppFailure('path', '备份目录是符号链接，无法安全清理');
      }
      if (await FileSystemEntity.type(backupRoot, followLinks: false) ==
          FileSystemEntityType.directory) {
        await for (final version in Directory(
          backupRoot,
        ).list(followLinks: false)) {
          if (version is Directory) {
            await _deleteAccountPath(p.join(version.path, a.id));
          }
        }
      }
      await saveConversationBlacklist(
        _conversationBlacklist.where((r) => r.accountId != a.id).toList(),
      );
      await store.deleteAccount(a.id);
      deletedAccountIds.add(a.id);
      final keys = conversations
          .where((c) => c.accountId == a.id)
          .map((c) => c.key)
          .toSet();
      bool ownedKey(String key) {
        if (keys.contains(key) || key == a.id || key.endsWith(':${a.id}')) {
          return true;
        }
        try {
          final parts = jsonDecode(key);
          if (parts is List && parts.isNotEmpty && parts.first is String) {
            return parts.first == a.id || ownedKey(parts.first as String);
          }
        } catch (_) {}
        return false;
      }

      accounts.removeWhere((v) => v.id == a.id);
      conversations.removeWhere((v) => v.accountId == a.id);
      messages.removeWhere((v) => v.accountId == a.id);
      outbox.removeWhere((v) => v['accountId'] == a.id);
      diagnostics.removeWhere((v) => v['accountId'] == a.id);
      for (final map in <Map<String, dynamic>>[
        sync,
        authUrls,
        capabilities,
        _backoff,
        _next,
        _subscriptionRetry,
        _subscriptionFailures,
        senderProfiles,
        _readAt,
        _seenPlatformTime,
        _attachments,
      ]) {
        map.removeWhere((key, _) => ownedKey(key));
      }
      for (final set in [
        _streams,
        blockedConversations,
        _historyDone,
        _pendingChecks,
      ]) {
        set.removeWhere(ownedKey);
      }
      _senderQueue.remove(a.id);
      _sendingAccounts.remove(a.id);
      activities.removeScope(a.label);
      notices.removeWhere((notice) => notice.contains(a.label));
    } finally {
      _deletingAccounts.remove(a.id);
      changed();
    }
  }

  Future<void> _checkAccountPath(String path) async {
    final base = p.normalize(p.absolute(root));
    final target = p.normalize(p.absolute(path));
    if (!p.isWithin(base, target)) throw const AppFailure('path', '清理路径超出工作区');
    var current = base;
    for (final part in p.split(p.relative(p.dirname(target), from: base))) {
      if (part == '.') continue;
      current = p.join(current, part);
      if (await FileSystemEntity.type(current, followLinks: false) ==
          FileSystemEntityType.link) {
        throw const AppFailure('path', '账号目录的父路径包含符号链接，无法安全清理');
      }
    }
  }

  Future<void> _deleteAccountPath(String path) async {
    await _checkAccountPath(path);
    final type = await FileSystemEntity.type(path, followLinks: false);
    if (type == FileSystemEntityType.directory) {
      await Directory(path).delete(recursive: true);
    } else if (type == FileSystemEntityType.link) {
      await Link(path).delete();
    } else if (type == FileSystemEntityType.file) {
      await File(path).delete();
    }
  }

  Future<void> refreshActiveConversations(
    AccountRef a, {
    DateTime? at,
  }) => activities.run('active:${a.id}', '发现最新活跃会话', a.label, (_) async {
    final now = at ?? DateTime.now();
    final end = now.millisecondsSinceEpoch ~/ 1000 * 1000;
    final saved =
        await store.get('activeDiscovery', a.id) ?? <String, dynamic>{};
    final cursor = '${saved['cursor'] ?? ''}';
    final state = cursor.isNotEmpty
        ? saved
        : <String, dynamic>{
            'start':
                ((saved['completedUntil'] as int? ??
                    end - const Duration(hours: 1).inMilliseconds) -
                const Duration(minutes: 2).inMilliseconds),
            'end': end,
            'completedUntil': saved['completedUntil'],
          };
    await store.put('activeDiscovery', a.id, state, account: a.id);
    final result = object(
      await (await client(a)).call('conversations.active', {
        'start': state['start'],
        'end': state['end'],
        if (cursor.isNotEmpty) 'cursor': cursor,
      }),
    );
    if (result['items'] is! List || result['complete'] is! bool) {
      throw const AppFailure('contract', '活跃会话响应不完整，检查点未推进');
    }
    final next = '${result['cursor'] ?? ''}';
    final complete = result['complete'] == true;
    if (!complete && (next.isEmpty || next == cursor)) {
      throw const AppFailure('contract', '活跃会话分页无法继续，检查点未推进');
    }
    // Validate the whole page before modifying the local checkpoint.
    final found = (result['items'] as List? ?? [])
        .map((j) => Conversation.fromJson(object(j)))
        .toList();
    if (found.any((c) => c.accountId != a.id)) {
      throw const AppFailure('identity', '活跃会话账号不匹配');
    }
    for (final c in found) {
      await store.db.transaction(() async {
        final old = conversations.where((v) => v.key == c.key).firstOrNull;
        final updated = old == null
            ? c
            : old.copyWith(
                updatedAt: c.updatedAt > old.updatedAt
                    ? c.updatedAt
                    : old.updatedAt,
              );
        await _saveConversation(updated);
        if (old == null &&
            a.platform == 'dingtalk' &&
            (c.kind == 'unknown' || (c.peerId.isEmpty && c.kind == 'p2p'))) {
          // Activity summaries lack the peer ID needed for direct-message reads.
          // Enumerate details before scheduling this new conversation.
          _next.remove('account:${a.id}');
        }
        if ((old == null || c.updatedAt > old.updatedAt) &&
            !isConversationExcluded(updated) &&
            !blockedConversations.contains(c.key)) {
          _pendingChecks.add(c.key);
          _next.remove(c.key);
        }
      });
    }
    conversations.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    await store.put('activeDiscovery', a.id, {
      ...state,
      'cursor': complete ? '' : next,
      if (complete) 'completedUntil': state['end'],
    }, account: a.id);
    _next['active:${a.id}'] = now.add(Duration(seconds: complete ? 15 : 1));
    changed();
  });

  Future<void> refreshConversations(AccountRef a, {bool more = false}) =>
      activities.run(
        'conversations:${a.id}:$more',
        more ? '发现更多会话' : '刷新会话列表',
        a.label,
        (task) => _refreshConversations(a, more: more, activity: task),
      );

  Future<void> _refreshConversations(
    AccountRef a, {
    required bool more,
    required BackgroundActivity activity,
  }) async {
    final rpc = await client(a);
    final page = more ? await store.get('discovery', a.id) : null;
    if (more && page?['done'] == true) return;
    final result = object(
      await rpc.call('conversations', {
        if (page?['cursor'] != null && page!['cursor'] != '')
          'cursor': page['cursor'],
      }),
    );
    for (final j in (result['items'] as List? ?? [])) {
      await store.db.transaction(() async {
        var c = Conversation.fromJson(object(j));
        if (c.accountId != a.id) throw const AppFailure('identity', '会话账号不匹配');
        final old = conversations.where((x) => x.key == c.key).firstOrNull;
        c = c.copyWith(
          watched: old?.watched ?? false,
          unread: c.unreadIsLocal
              ? (old?.unread ?? 0)
              : ((_seenPlatformTime[c.key] ?? -1) >= c.updatedAt
                    ? (old?.unread ?? 0)
                    : c.unread),
          updatedAt: old != null && old.updatedAt > c.updatedAt
              ? old.updatedAt
              : c.updatedAt,
        );
        if (old == null) _pendingChecks.add(c.key);
        _upsertConversation(c);
        await store.put(
          'conversations',
          c.key,
          c.toJson(),
          account: a.id,
          ts: c.updatedAt,
        );
      });
    }
    await store.put('cursors', 'conversations:${a.id}', {
      'cursor': result['cursor'],
    });
    final discovery = await store.get('discovery', a.id);
    if (more || discovery == null || discovery['done'] == true) {
      final next = '${result['cursor'] ?? ''}';
      await store.put('discovery', a.id, {
        'cursor': next,
        'done': next.isEmpty || next == page?['cursor'],
        'checkedAt': DateTime.now().millisecondsSinceEpoch,
      });
    }
    await _stopExcludedSubscriptions();
    conversations.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    activity.progress('已更新 ${(result['items'] as List? ?? []).length} 个会话');
    changed();
  }

  Future<void> selectConversation(Conversation c) async {
    if (selectedConversation?.key != c.key) {
      messageLimit = 100;
      messages = [];
    }
    selectedAccount = c.accountId;
    selectedConversation = c.copyWith(unread: 0);
    await markRead(selectedConversation!);
    await loadMessages();
    await syncConversation(c, manual: isConversationExcluded(c));
  }

  bool _isOwn(Message m) =>
      m.extra['isOwn'] == true ||
      (account(m.accountId).userId.isNotEmpty &&
          account(m.accountId).userId == m.senderId);

  Future<void> markRead(Conversation c) => store.db.transaction(() async {
    final latest = conversations.where((v) => v.key == c.key).firstOrNull ?? c;
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now > (_readAt[c.key] ?? 0)) _readAt[c.key] = now;
    _seenPlatformTime[c.key] = latest.updatedAt;
    await store.put('readState', c.key, {
      'timestamp': _readAt[c.key],
      'platformTime': latest.updatedAt,
    });
    await _saveConversation(latest.copyWith(unread: 0));
  });

  Future<void> updateReading({bool? visible, bool? focused}) async {
    if (closing) return;
    chatVisible = visible ?? chatVisible;
    windowFocused = focused ?? windowFocused;
    final c = selectedConversation;
    if (c != null && isReading(c)) {
      await markRead(
        conversations.where((v) => v.key == c.key).firstOrNull ?? c,
      );
    }
  }

  Future<void> _saveConversation(Conversation c) async {
    _upsertConversation(c);
    await store.put(
      'conversations',
      c.key,
      c.toJson(),
      account: c.accountId,
      ts: c.updatedAt,
    );
    changed();
  }

  void _upsertConversation(Conversation c) {
    if (deletedAccountIds.contains(c.accountId) ||
        _deletingAccounts.contains(c.accountId)) {
      return;
    }
    final index = conversations.indexWhere((x) => x.key == c.key);
    if (index < 0) {
      conversations.add(c);
    } else {
      conversations[index] = c;
    }
  }

  Future<void> watch(Conversation c, bool value) async {
    await _saveConversation(c.copyWith(watched: value));
    if (!value && _streams.remove(c.key)) {
      await clients[c.accountId]?.call('unsubscribe', {'conversationId': c.id});
    }
  }

  Future<void> showEarlierMessages({bool manual = false}) async {
    final c = selectedConversation;
    if (c == null || loadingEarlier) return;
    loadingEarlier = true;
    try {
      messageLimit += 100;
      await loadMessages();
      final saved = await store.get('cursors', c.key);
      final done = manual
          ? (saved?['manualHistoryDone'] == true)
          : _historyDone.contains(c.key);
      if (messages.length < messageLimit && !done) {
        await syncConversation(c, older: true, manual: manual);
      }
    } finally {
      loadingEarlier = false;
      changed();
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
            limit: messageLimit,
          )).map(Message.fromJson).toList()
          ..sort((a, b) => a.timestamp.compareTo(b.timestamp));
    if (selectedConversation?.key == c.key) {
      messages = data;
      unawaited(resolveSenders(c.accountId, data));
      outbox = await store.list('outbox');
      changed();
    }
  }

  bool validSenderAvatarPath(String accountId, String path) =>
      path.isNotEmpty &&
      p.isWithin(
        p.join(root, 'accounts', accountId, 'downloads'),
        p.normalize(path),
      ) &&
      File(path).existsSync();

  Future<void> resolveSenders(String accountId, List<Message> list) async {
    if (closing) return;
    final queue = _senderQueue.putIfAbsent(accountId, () => {});
    for (final m in list) {
      final id = senderLookupId(m);
      if (id.isNotEmpty &&
          (messageSenderName(m).isEmpty ||
              (messageSenderAvatar(m).isEmpty &&
                  conversationSenderAvatar(m, conversations).isEmpty))) {
        queue[compositeKey(m.conversationId, id)] = m;
      }
    }
    if (!_resolvingSenders.add(accountId)) return;
    _busy.add('senders:$accountId');
    bool fresh(Json? profile) =>
        (profile?['avatarPath'] == null ||
            validSenderAvatarPath(accountId, '${profile?['avatarPath']}')) &&
        profile?['version'] == 2 &&
        (profile?['expires'] as int? ?? 0) >
            DateTime.now().millisecondsSinceEpoch;
    BackgroundActivity? currentActivity;
    try {
      while (queue.isNotEmpty && !closing) {
        final conversationId = queue.values.first.conversationId;
        final entries = queue.entries
            .where((e) => e.value.conversationId == conversationId)
            .take(20)
            .toList();
        final missing = <String, Message>{};
        for (final entry in entries) {
          queue.remove(entry.key);
          final m = entry.value, id = senderLookupId(entry.value);
          final key = compositeKey(accountId, id);
          if (fresh(senderProfiles[key])) continue;
          final saved = await store.get('senders', key);
          if (fresh(saved)) {
            senderProfiles[key] = saved!;
          } else {
            missing[id] = m;
          }
        }
        if (missing.isEmpty || closing) continue;
        if (!account(accountId).enabled && !clients.containsKey(accountId)) {
          continue;
        }
        final activity = currentActivity = activities.begin(
          'senders:$accountId',
          '更新联系人资料',
          account(accountId).label,
        );
        activity.progress('正在查询 ${missing.length} 位联系人的名称与头像');
        var returned = <Json>[];
        var lookupSucceeded = false;
        try {
          final c = conversations
              .where((c) => c.accountId == accountId && c.id == conversationId)
              .firstOrNull;
          final response = object(
            await (await client(account(accountId))).call('contacts.resolve', {
              'ids': missing.keys.toList(),
              if (c != null) 'conversation': c.toJson(),
              'openIds': {
                for (final entry in missing.entries)
                  if (field(object(entry.value.extra['raw']), [
                    'senderOpenDingTalkId',
                  ]).isNotEmpty)
                    entry.key: field(object(entry.value.extra['raw']), [
                      'senderOpenDingTalkId',
                    ]),
              },
            }),
          );
          returned = (response['items'] as List? ?? []).map(object).toList();
          lookupSucceeded = true;
        } catch (e) {
          notice = '联系人资料暂不可用，将自动重试：$e';
          activity.finish(
            state: 'failed',
            detail: '$e',
            retryAt: DateTime.now().add(const Duration(seconds: 30)),
          );
        }
        for (final id in missing.keys) {
          final key = compositeKey(accountId, id);
          final profile =
              returned.where((r) => r['id'] == id).firstOrNull ??
              <String, dynamic>{};
          final previous = senderProfiles[key];
          final name = field(profile, [
            'name',
          ], field(previous ?? {}, ['name'], messageSenderName(missing[id]!)));
          final avatar = avatarUrl(profile['avatar']).isNotEmpty
              ? avatarUrl(profile['avatar'])
              : avatarUrl(previous?['avatar']);
          var avatarPath = '${previous?['avatarPath'] ?? ''}';
          final resource = '${profile['avatarResourceId'] ?? ''}';
          if (resource.isNotEmpty) {
            try {
              avatarPath = await cachedAttachment(missing[id]!, resource);
            } catch (e) {
              notice = '联系人头像暂不可用，将自动重试：$e';
            }
          }
          final hasFile = validSenderAvatarPath(accountId, avatarPath);
          final saved = <String, dynamic>{
            if (hasFile) 'avatarPath': avatarPath,
            'version': 2,
            'id': id,
            'name': name,
            'avatar': avatar,
            if (lookupSucceeded && account(accountId).platform == 'feishu')
              'avatarUnavailable': avatar.isEmpty && !hasFile,
            'expires': DateTime.now()
                .add(
                  (lookupSucceeded &&
                              account(accountId).platform == 'feishu') ||
                          (name.isNotEmpty && (avatar.isNotEmpty || hasFile))
                      ? const Duration(hours: 12)
                      : const Duration(seconds: 30),
                )
                .millisecondsSinceEpoch,
          };
          senderProfiles[key] = saved;
          await store.put('senders', key, saved, account: accountId);
        }
        activity.finish(detail: '已处理 ${missing.length} 位联系人');
        changed();
      }
      changed();
    } catch (e) {
      currentActivity?.finish(state: 'failed', detail: '$e');
      notice = '联系人资料更新失败：$e';
      changed();
    } finally {
      _resolvingSenders.remove(accountId);
      _busy.remove('senders:$accountId');
    }
  }

  Future<void> _incrementUnread(Message m) => store.db.transaction(() async {
    final c = conversations
        .where((c) => c.accountId == m.accountId && c.id == m.conversationId)
        .firstOrNull;
    if (c != null) {
      if (isReading(c)) {
        // Persist the last visible message too, including delayed delivery.
        final previous = _readAt[c.key] ?? 0;
        if (m.timestamp > previous) _readAt[c.key] = m.timestamp;
        await store.put('readState', c.key, {
          'timestamp': _readAt[c.key] ?? 0,
          'platformTime': _seenPlatformTime[c.key] ?? -1,
        });
      }
      await _saveConversation(
        c.copyWith(
          unread: isReading(c)
              ? 0
              : (_isOwn(m) ||
                        m.timestamp <= (_readAt[c.key] ?? 0) ||
                        !c.unreadIsLocal
                    ? c.unread
                    : c.unread + 1),
          updatedAt: m.timestamp > c.updatedAt ? m.timestamp : c.updatedAt,
        ),
      );
    }
  });

  Future<void> syncConversation(
    Conversation c, {
    bool older = false,
    bool manual = false,
  }) async {
    if ((!manual && isConversationExcluded(c)) ||
        blockedConversations.contains(c.key) ||
        !_busy.add(c.key)) {
      return;
    }
    final state = sync[c.key] ??= SyncState();
    BackgroundActivity? activity;
    var received = 0, fetchedPages = 0;
    try {
      final a = account(c.accountId);
      if (!a.enabled) return;
      activity = activities.begin(
        'sync:${c.key}:$older',
        older ? '补齐历史消息' : '拉取新消息',
        '${a.label} · ${c.title}',
      );
      activity.progress('正在请求消息');
      final rpc = await client(a);
      final saved = await store.get('cursors', c.key);
      final initial =
          saved?['timestamp'] == null && saved?['resumeSince'] == null;
      final cutoff = (saved?['historyWindowStart'] as int?) ?? historyCutoff;
      final limitHistory = !manual && (older || initial);
      final historyPrefix = manual ? 'manualHistory' : 'history';
      final requestStartedAt = DateTime.now().millisecondsSinceEpoch;
      int? before;
      if (older) before = await store.oldestMessage(a.id, c.id);
      var since = older
          ? null
          : (saved?['resumeSince'] ?? saved?['timestamp']) as int?;
      String? cursor = older
          ? (saved?['${historyPrefix}Cursor'] as String?)
          : (saved?['resumeCursor'] as String?);
      if (older && cursor != null) {
        before = saved?['${historyPrefix}Before'] as int?;
      }
      if (older && limitHistory && before != null && before <= cutoff) {
        _historyDone.add(c.key);
        await store.put('cursors', c.key, {...?saved, 'historyDone': true});
        activity.finish(state: 'completed', detail: '已达到自动拉取的 7 天范围');
        return;
      }
      var pages = 0, hasMore = false, stalledIncrement = false;
      var maxTime = (saved?['resumeMaxTime'] as int?) ?? since ?? 0;
      int? pageOldest;
      do {
        if (!manual && isConversationExcluded(c)) {
          activity.finish(state: 'completed', detail: '已排除自动同步');
          return;
        }
        final result = object(
          await rpc.call('messages', {
            'conversation': c.toJson(),
            'before': ?before,
            if (since != null) 'since': since - 2000,
            'cursor': ?cursor,
            if (limitHistory) 'notBefore': cutoff,
          }),
        );
        if (!manual && isConversationExcluded(c)) {
          activity.finish(state: 'completed', detail: '已排除自动同步');
          return;
        }
        final items = (result['items'] as List? ?? [])
            .map((j) => Message.fromJson(object(j)))
            .toList();
        for (final m in items) {
          if (m.accountId != a.id || m.conversationId != c.id) {
            throw const AppFailure('identity', '消息来源不匹配');
          }
          if (pageOldest == null || m.timestamp < pageOldest) {
            pageOldest = m.timestamp;
          }
          if (limitHistory && m.timestamp < cutoff) continue;
          final existed = !await store.saveIncoming(m);
          if (!existed && m.timestamp >= historyCutoff) {
            await _incrementUnread(m);
            if (!older &&
                !_isOwn(m) &&
                m.timestamp >= startedAt &&
                m.timestamp >
                    (_readAt[compositeKey(m.accountId, m.conversationId)] ??
                        0)) {
              onIncoming?.call(m);
            }
          }
          if (m.timestamp > maxTime) maxTime = m.timestamp;
        }
        received += items.length;
        fetchedPages++;
        activity.progress('已拉取 $fetchedPages 页 · $received 条消息');
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
            stalledIncrement = !older && since != null && hasMore;
            break;
          }
        } else {
          cursor = next;
        }
      } while (!older &&
          since != null &&
          ++pages < 2 &&
          (_sendingAccounts[a.id] ?? 0) == 0);
      if (!older) state.gap = since != null && hasMore;
      final checkpoint = <String, dynamic>{...?saved};
      if (limitHistory) checkpoint['historyWindowStart'] = cutoff;
      if (older) {
        checkpoint['${historyPrefix}Cursor'] = cursor;
        checkpoint['${historyPrefix}Before'] = before;
        final reachedEnd =
            !hasMore ||
            (limitHistory && pageOldest != null && pageOldest <= cutoff);
        final stalled =
            hasMore &&
            cursor == null &&
            (pageOldest == null || (before != null && pageOldest >= before));
        if (reachedEnd || stalled) {
          if (!manual) _historyDone.add(c.key);
          checkpoint['${historyPrefix}Done'] = true;
          checkpoint['${historyPrefix}Incomplete'] = stalled;
        }
      } else {
        if (saved?['timestamp'] == null && saved?['resumeSince'] == null) {
          if (!hasMore || (pageOldest != null && pageOldest <= cutoff)) {
            _historyDone.add(c.key);
            checkpoint['historyDone'] = true;
          } else if (cursor != null) {
            checkpoint['historyCursor'] = cursor;
          }
        }
        if (!state.gap) {
          checkpoint['timestamp'] = maxTime > 0 ? maxTime : requestStartedAt;
          checkpoint.remove('resumeCursor');
          checkpoint.remove('resumeSince');
          checkpoint.remove('resumeMaxTime');
        } else {
          checkpoint['resumeMaxTime'] = maxTime;
          checkpoint['resumeSince'] = since;
          checkpoint['resumeCursor'] = cursor;
        }
      }
      await store.put('cursors', c.key, checkpoint);
      state.error = stalledIncrement
          ? '增量分页无法继续，稍后重试；消息可能不完整'
          : state.gap
          ? '消息有缺口，正在自动补齐'
          : checkpoint['${historyPrefix}Incomplete'] == true
          ? '历史分页边界无法继续，部分历史可能不完整'
          : '';
      state.lastSuccess = DateTime.now().millisecondsSinceEpoch;
      state.failures = 0;
      _backoff.remove(c.key);
      if (!isConversationExcluded(c) &&
          a.platform == 'dingtalk' &&
          (c.watched || c.key == selectedConversation?.key) &&
          !_streams.contains(c.key) &&
          !(_subscriptionRetry[c.key]?.isAfter(DateTime.now()) ?? false)) {
        _streams.add(c.key);
        try {
          await rpc.call('subscribe', {'conversation': c.toJson()});
          // A rule may have unsubscribed while subscribe was still pending.
          if (isConversationExcluded(c)) _streams.add(c.key);
          await _stopExcludedSubscriptions();
        } catch (e) {
          _streams.remove(c.key);
          await _subscriptionFailed(a, c.id, '$e');
          await recordDiagnostic(a, {
            'operation': 'subscribe',
            'conversationId': c.id,
            'detail': '$e',
          });
        }
      }
      if (selectedConversation?.key == c.key && !closing) await loadMessages();
      if (!older && state.gap) {
        _next[c.key] = DateTime.now().add(
          Duration(seconds: stalledIncrement ? 30 : 0),
        );
      }
      await store.put('sync', c.key, state.toJson());
      activity.finish(
        state: state.error.isNotEmpty ? 'waiting' : 'completed',
        detail: state.error.isNotEmpty
            ? '${state.error}（本次 $received 条）'
            : '已拉取 $fetchedPages 页 · $received 条消息',
        retryAt: state.gap ? _next[c.key] : null,
      );
    } catch (e) {
      await recordDiagnostic(account(c.accountId), {
        'operation': older ? 'messages.history' : 'messages',
        'conversationId': c.id,
        'detail': '$e',
      });
      if (e is AppFailure &&
          (e.code == 'confidential_group' || confidentialFailure(e.message))) {
        await _blockConfidential(c);
        activity?.finish(state: 'waiting', detail: state.error);
        return;
      }
      state.failures++;
      state.error = '$e';
      state.mode = e is AppFailure && e.code == 'authorization'
          ? '权限不足'
          : '定时同步';
      final delay = e is AppFailure && e.retryAfter != null
          ? e.retryAfter!
          : (5 * (1 << state.failures.clamp(0, 6)));
      _backoff[c.key] = DateTime.now().add(Duration(seconds: delay));
      activity?.finish(state: 'failed', detail: '$e', retryAt: _backoff[c.key]);
    } finally {
      _busy.remove(c.key);
      changed();
    }
  }

  int get backgroundPending => conversations
      .where(
        (c) =>
            account(c.accountId).enabled &&
            !blockedConversations.contains(c.key) &&
            !isConversationExcluded(c) &&
            !_historyDone.contains(c.key) &&
            (c.updatedAt == 0 ||
                c.updatedAt >= historyCutoff ||
                c.watched ||
                c.unread > 0),
      )
      .length;

  void tick({DateTime? at}) {
    if (closing || _deletingAccounts.isNotEmpty) return;
    final now = at ?? DateTime.now();
    for (final platform in accounts.map((a) => a.platform).toSet()) {
      _tickPlatform(platform, now);
    }
  }

  void _tickPlatform(String platform, DateTime now) {
    final platformAccounts = accounts.where((a) => a.platform == platform);
    final accountIds = platformAccounts.map((a) => a.id).toSet();
    final platformConversations = conversations
        .where((c) => accountIds.contains(c.accountId))
        .toList();
    final historyKey = 'history:$platform';
    // Each plugin owns its slots so a slow platform cannot starve another.
    final taskKeys = {
      historyKey,
      for (final a in platformAccounts) ...[
        'account:${a.id}',
        'discover:${a.id}',
        'active:${a.id}',
      ],
      for (final c in platformConversations) c.key,
    };
    int pending() => _busy.where(taskKeys.contains).length;
    bool due(String key) =>
        !(_next[key]?.isAfter(now) ?? false) &&
        !(_backoff[key]?.isAfter(now) ?? false) &&
        !_busy.contains(key);
    bool available(String id) =>
        account(id).enabled &&
        !_updating.contains(account(id).platform) &&
        (_sendingAccounts[id] ?? 0) == 0;
    for (final a in platformAccounts.where((a) => available(a.id))) {
      final key = 'account:${a.id}';
      if (due(key) && !_busy.contains('discover:${a.id}') && pending() < 4) {
        _busy.add(key);
        _next[key] = now.add(const Duration(hours: 3));
        _pendingChecks.addAll(
          platformConversations
              .where((c) => c.accountId == a.id)
              .map((c) => c.key),
        );
        refreshConversations(a)
            .catchError((Object e) {
              _next[key] = now.add(const Duration(seconds: 30));
              notice = '${a.label}：$e';
              changed();
            })
            .whenComplete(() => _busy.remove(key));
      }
      // Discover remaining pages incrementally without delaying live requests.
      final moreKey = 'discover:${a.id}';
      if (due(moreKey) && !_busy.contains(key) && pending() < 3) {
        _busy.add(moreKey);
        _next[moreKey] = now.add(const Duration(seconds: 10));
        (() async {
              final cursor = await store.get('discovery', a.id);
              if (cursor?['done'] == true) return;
              await refreshConversations(a, more: true);
            })()
            .catchError((Object e) {
              notice = '${a.label} 会话发现稍后重试：$e';
              changed();
            })
            .whenComplete(() => _busy.remove(moreKey));
      }
    }
    for (final a in platformAccounts.where((a) => available(a.id))) {
      final key = 'active:${a.id}';
      if (!repositories.containsKey(a.platform) ||
          !due(key) ||
          pending() >= 3) {
        continue;
      }
      _busy.add(key);
      _next[key] = now.add(const Duration(seconds: 15));
      refreshActiveConversations(a, at: now)
          .catchError((Object e) {
            notice = '${a.label} 活跃会话查询稍后重试：$e';
            changed();
          })
          .whenComplete(() => _busy.remove(key));
    }
    final eligible = platformConversations
        .where(
          (c) =>
              available(c.accountId) &&
              !(platform == 'dingtalk' &&
                  (c.kind == 'unknown' ||
                      (c.kind == 'p2p' && c.peerId.isEmpty))) &&
              !blockedConversations.contains(c.key) &&
              !isConversationExcluded(c),
        )
        .toList();
    final hotSince = now
        .subtract(const Duration(hours: 1))
        .millisecondsSinceEpoch;
    final candidates = eligible
        .where(
          (c) =>
              c.updatedAt >= hotSince ||
              _pendingChecks.contains(c.key) ||
              sync[c.key]?.gap == true ||
              c.key == selectedConversation?.key,
        )
        .toList();
    candidates.sort((a, b) {
      final dueOrder = (_next[a.key] ?? DateTime(1970)).compareTo(
        _next[b.key] ?? DateTime(1970),
      );
      if (dueOrder != 0) return dueOrder;
      return b.unread.compareTo(a.unread);
    });
    for (final c in candidates) {
      if (pending() >= 3) break;
      if (!due(c.key)) continue;
      _next[c.key] = now.add(
        Duration(seconds: c.key == selectedConversation?.key ? 5 : 30),
      );
      unawaited(
        syncConversation(c).then((_) {
          final state = sync[c.key];
          if (state != null && state.error.isEmpty && !state.gap) {
            _pendingChecks.remove(c.key);
          }
        }),
      );
    }
    // One history page per plugin; pending sends and live data keep priority.
    if (!_busy.contains(historyKey) && pending() < 4) {
      final history =
          eligible
              .where(
                (c) =>
                    (c.updatedAt == 0 ||
                        c.updatedAt >= historyCutoff ||
                        c.watched ||
                        c.unread > 0) &&
                    (sync[c.key]?.lastSuccess ?? 0) > 0 &&
                    !_historyDone.contains(c.key) &&
                    !_busy.contains(c.key) &&
                    due('history:${c.key}') &&
                    !(_backoff[c.key]?.isAfter(now) ?? false),
              )
              .toList()
            ..sort(
              (a, b) => (_next['history:${a.key}'] ?? DateTime(1970)).compareTo(
                _next['history:${b.key}'] ?? DateTime(1970),
              ),
            );
      if (history.isNotEmpty) {
        final c = history.first;
        _next['history:${c.key}'] = now.add(const Duration(seconds: 10));
        _busy.add(historyKey);
        syncConversation(
          c,
          older: true,
        ).whenComplete(() => _busy.remove(historyKey));
      }
    }
  }

  Future<void> dismissSendError(String id) async {
    final row = outbox.where((o) => o['id'] == id).firstOrNull;
    if (row == null) return;
    await _saveOutgoing({...row, 'errorDismissed': true});
  }

  Future<void> _saveOutgoing(Json record) async {
    outbox = [record, ...outbox.where((o) => o['id'] != record['id'])];
    changed();
    await store.put(
      'outbox',
      record['id'],
      record,
      ts: record['timestamp'] as int,
    );
  }

  Future<void> send(
    Conversation c,
    String text, {
    Message? reply,
    String? attachment,
    bool image = false,
    bool markdown = false,
  }) async {
    if (!account(c.accountId).canSend) {
      throw const AppFailure('permission', '缺少发送权限，请在设置中为此账号补充发送授权');
    }
    final id = newId();
    final record = {
      'id': id,
      'accountId': c.accountId,
      'conversationId': c.id,
      'text': text,
      'state': 'sending',
      'attachment': attachment,
      'replyId': reply?.id,
      'timestamp': DateTime.now().millisecondsSinceEpoch,
    };
    _sendingAccounts[c.accountId] = (_sendingAccounts[c.accountId] ?? 0) + 1;
    try {
      await _saveOutgoing(record);
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
      await _saveOutgoing({...record, 'state': 'confirmed', 'result': result});
      await store.audit('message.send', {
        'account': c.accountId,
        'conversation': c.id,
        'id': id,
        'state': 'confirmed',
      });
      unawaited(syncConversation(c));
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
      await _saveOutgoing({...record, 'state': state, 'error': '$e'});
      rethrow;
    } finally {
      _sendingAccounts[c.accountId] = (_sendingAccounts[c.accountId] ?? 1) - 1;
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

  Future<String> cachedAttachment(Message message, String resourceId) async {
    final key = compositeKey(message.key, resourceId);
    final task = _attachments.putIfAbsent(key, () async {
      final saved = await store.get('attachments', key);
      final path = saved?['path'] as String?;
      if (path != null &&
          p.isWithin(
            p.join(root, 'accounts', message.accountId, 'downloads'),
            p.normalize(path),
          ) &&
          await File(path).exists()) {
        return path;
      }
      final result = await downloadAttachment(message, resourceId);
      await store.put('attachments', key, {
        'path': result,
      }, account: message.accountId);
      return result;
    });
    try {
      return await task;
    } finally {
      if (identical(_attachments[key], task)) _attachments.remove(key);
    }
  }

  Future<String> downloadAttachment(Message message, String resourceId) =>
      activities.run(
        'download:${message.key}:$resourceId',
        '下载图片或附件',
        account(message.accountId).label,
        (_) => _downloadAttachment(message, resourceId),
      );

  Future<String> _downloadAttachment(Message message, String resourceId) async {
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
    if (_deletingAccounts.isNotEmpty) {
      throw const AppFailure('busy', '正在清理账号，请稍后更新插件');
    }
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
    if (_deletingAccounts.isNotEmpty) {
      throw const AppFailure('busy', '正在清理账号，请稍后回滚插件');
    }
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
