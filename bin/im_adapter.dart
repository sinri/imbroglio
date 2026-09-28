import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path/path.dart' as p;
// Shared wire models are intentionally pure Dart.
// ignore: avoid_relative_lib_imports
import '../lib/src/core/models.dart';
// ignore: avoid_relative_lib_imports
import '../lib/src/core/normalize.dart';
// ignore: avoid_relative_lib_imports
import '../lib/src/core/diagnostics.dart';

void emit(Json j) => stdout.writeln(jsonEncode({'jsonrpc': '2.0', ...j}));

class Adapter {
  late String platform, binary, directory, accountId;
  String profile = '';
  final processes = <Object, Process>{};
  final streams = <String, Process>{};
  final capabilities = <String, dynamic>{};
  bool initialized = false;
  final _groupProfileRetry = <String, DateTime>{};
  Map<String, String> get environment => {
    for (final key in [
      'PATH',
      'HOME',
      'USERPROFILE',
      'SystemRoot',
      'WINDIR',
      'TEMP',
      'TMP',
      'LANG',
      'LC_ALL',
      'DISPLAY',
      'DBUS_SESSION_BUS_ADDRESS',
      'XDG_RUNTIME_DIR',
      'HTTP_PROXY',
      'HTTPS_PROXY',
      'ALL_PROXY',
      'NO_PROXY',
      'http_proxy',
      'https_proxy',
      'all_proxy',
      'no_proxy',
    ])
      if (Platform.environment[key] != null) key: Platform.environment[key]!,
    'DWS_CONFIG_DIR': p.join(directory, 'config'),
    'DWS_CACHE_DIR': p.join(directory, 'cache'),
    'DWS_KEYCHAIN_DIR': p.join(directory, 'credentials'),
    'LARKSUITE_CLI_CONFIG_DIR': p.join(directory, 'config'),
    'LARKSUITE_CLI_NO_UPDATE_NOTIFIER': '1',
    'LARKSUITE_CLI_NO_SKILLS_NOTIFIER': '1',
  };
  List<String> scoped(
    List<String> args, {
    bool user = false,
    bool json = true,
  }) => [
    ...args,
    if (profile.isNotEmpty) ...['--profile', profile],
    if (user && platform == 'feishu') ...['--as', 'user'],
    if (json) ...['--format', 'json'],
  ];
  void diagnostic(
    String operation,
    String message, {
    int? exitCode,
    String conversationId = '',
  }) {
    emit({
      'method': 'diagnostic',
      'params': {
        'operation': operation,
        'detail': diagnosticText(message),
        'exitCode': ?exitCode,
        'conversationId': conversationId,
      },
    });
  }

  Future<dynamic> run(
    Object id,
    List<String> args, {
    String? input,
    bool raw = false,
    Duration timeout = const Duration(seconds: 40),
    bool auth = false,
  }) async {
    final process = await Process.start(
      binary,
      args,
      workingDirectory: directory,
      environment: environment,
      includeParentEnvironment: false,
      runInShell: false,
    );
    processes[id] = process;
    final buffer = StringBuffer(), errors = StringBuffer();
    void capture(String data, StringBuffer target) {
      if (target.length + data.length > 8 * 1024 * 1024) {
        process.kill();
        return;
      }
      target.write(data);
      if (auth) {
        for (final match in RegExp(
          r'https://[^\s"<>]+(?=[\s"<>])',
        ).allMatches(target.toString())) {
          final url = match.group(0)!;
          final host = Uri.tryParse(url)?.host ?? '';
          if ([
            'dingtalk.com',
            'feishu.cn',
            'larksuite.com',
            'larkoffice.com',
          ].any((d) => host == d || host.endsWith('.$d'))) {
            emit({
              'method': 'auth.url',
              'params': {'url': url},
            });
          }
        }
      }
    }

    final out = process.stdout
        .transform(utf8.decoder)
        .forEach((s) => capture(s, buffer));
    final err = process.stderr
        .transform(utf8.decoder)
        .forEach((s) => capture(s, errors));
    if (input != null) process.stdin.write(input);
    await process.stdin.close();
    int? exitCode;
    try {
      final code = await process.exitCode.timeout(timeout);
      exitCode = code;
      await out;
      await err;
      if (code != 0) {
        var message = 'CLI 请求失败 ($code)';
        String kind = 'upstream';
        int? retryAfter;
        try {
          final j = object(jsonDecode(errors.toString()));
          final e = object(j['error']);
          message =
              '${e['message'] ?? j['message'] ?? j['errorMsg'] ?? message}';
          kind = '${e['type'] ?? kind}';
          retryAfter = int.tryParse(
            '${e['retry_after'] ?? e['retryAfter'] ?? j['retry_after']}',
          );
          if (e['code'] == 429 || e['subtype'] == 'rate_limit') {
            kind = 'rate_limit';
          }
        } catch (_) {}
        if (code == 10) kind = 'confirmation';
        throw AppFailure(kind, message, retryAfter: retryAfter);
      }
      if (raw) return buffer.toString();
      try {
        return unwrap(jsonDecode(buffer.toString()));
      } catch (e) {
        if (e is AppFailure) rethrow;
        throw const AppFailure('contract', 'CLI 未返回预期 JSON，请检查版本兼容性');
      }
    } on TimeoutException {
      process.kill();
      diagnostic(
        args.take(2).join(' '),
        'CLI 超时\n${errors.toString()}',
        exitCode: exitCode,
      );
      throw const AppFailure('timeout', 'CLI 超时；写入结果未知');
    } catch (e) {
      diagnostic(
        args.take(2).join(' '),
        '$e\n${errors.toString()}',
        exitCode: exitCode,
      );
      if (confidentialFailure('$e') || confidentialFailure(errors.toString())) {
        throw const AppFailure('confidential_group', '该群为保密群，无法获取消息记录');
      }
      rethrow;
    } finally {
      processes.remove(id);
    }
  }

  Future<void> probe(Object id) async {
    final map = platform == 'dingtalk'
        ? <String, List<String>>{
            'conversations': ['chat', 'list-all-conversations'],
            'messages': ['chat', 'message', 'list'],
            'send': ['chat', 'message', 'send'],
            'reply': ['chat', 'message', 'reply'],
            'resources.search': ['doc', 'search'],
            'resources.read': ['doc', 'read'],
            'subscribe': ['event', 'consume'],
          }
        : <String, List<String>>{
            'conversations': ['im', '+chat-list'],
            'messages': ['im', '+chat-messages-list'],
            'send': ['im', '+messages-send'],
            'reply': ['im', '+messages-reply'],
            'resources.search': ['drive', '+search'],
            'resources.read': ['docs', '+fetch'],
          };
    for (final entry in map.entries) {
      try {
        final help = await run(id, [...entry.value, '--help'], raw: true);
        capabilities[entry.key] = {
          'state': help.toString().contains(entry.value.last)
              ? 'available'
              : 'unsupported',
        };
      } catch (_) {
        capabilities[entry.key] = {'state': 'unsupported'};
      }
    }
    capabilities['sync'] = {
      'mode': platform == 'dingtalk' ? 'subscription' : 'poll',
      'identity': 'user',
    };
    capabilities['readReceipts'] = {'state': 'unsupported'};
    capabilities['credentials'] = {'isolated': false};
  }

  List<String> target(Json j) {
    if (j['kind'] == 'p2p') {
      if ('${j['peerId'] ?? ''}'.isEmpty) {
        throw const AppFailure('unsupported', '该单聊缺少对端用户标识，请先通过联系人查找打开单聊');
      }
      return ['--open-dingtalk-id', j['peerId']];
    }
    return ['--group', j['id']];
  }

  Future<dynamic> handle(Object id, String method, Json args) async {
    if (method == 'initialize') {
      platform = args['platform'];
      binary = args['binary'];
      directory = args['directory'];
      accountId = args['accountId'];
      profile = args['profile'] ?? '';
      if (!p.isAbsolute(binary) || !p.isAbsolute(directory)) {
        throw const AppFailure('path', '必须使用绝对路径');
      }
      await Directory(directory).create(recursive: true);
      initialized = true;
      await probe(id);
      return {'protocol': 1, 'capabilities': capabilities};
    }
    if (!initialized) throw const AppFailure('state', '插件尚未初始化');
    switch (method) {
      case 'health':
        return {'ready': true};
      case 'capabilities':
        return capabilities;
      case 'auth.configure':
        if (platform == 'dingtalk') return {};
        if ('${args['appId'] ?? ''}'.isNotEmpty) {
          await run(
            id,
            [
              'config',
              'init',
              '--app-id',
              args['appId'],
              '--app-secret-stdin',
              '--brand',
              'feishu',
            ],
            input: args['appSecret'],
            raw: true,
          );
        } else {
          await run(
            id,
            ['config', 'init', '--new'],
            raw: true,
            auth: true,
            timeout: const Duration(minutes: 5),
          );
        }
        return {'configured': true};
      case 'auth.login':
        await run(
          id,
          platform == 'dingtalk'
              ? ['auth', 'login', '--no-browser']
              : ['auth', 'login', '--recommend'],
          raw: true,
          auth: true,
          timeout: const Duration(minutes: 5),
        );
        return {'completed': true};
      case 'auth.status':
        final value = await run(
          id,
          platform == 'dingtalk'
              ? scoped(['profile', 'list'])
              : ['auth', 'status', '--json'],
        );
        return {'profiles': rows(value), 'status': value};
      case 'auth.logout':
        await run(
          id,
          platform == 'dingtalk'
              ? scoped(['auth', 'logout'])
              : ['auth', 'logout', '--json'],
          raw: true,
        );
        return {};
      case 'conversations':
        final value = await run(
          id,
          platform == 'dingtalk'
              ? scoped([
                  'chat',
                  'list-all-conversations',
                  '--limit',
                  '50',
                  if (args['cursor'] != null) ...['--cursor', args['cursor']],
                ])
              : scoped([
                  'im',
                  '+chat-list',
                  '--types',
                  'p2p,group',
                  '--sort',
                  'active_time',
                  '--page-size',
                  '50',
                  if (args['cursor'] != null) ...[
                    '--page-token',
                    args['cursor'],
                  ],
                ], user: true),
        );
        return {
          'items': rows(
            value,
          ).map((j) => normalizeConversation(accountId, j).toJson()).toList(),
          'cursor': field(object(value), [
            'nextCursor',
            'nextPageToken',
            'page_token',
            'next_page_token',
          ]),
        };
      case 'messages':
        final c = object(args['conversation']);
        final older = args['before'] != null;
        final time = DateTime.fromMillisecondsSinceEpoch(
          args['before'] ??
              args['since'] ??
              DateTime.now().millisecondsSinceEpoch,
        );
        final dt = time
            .toLocal()
            .toIso8601String()
            .replaceFirst('T', ' ')
            .substring(0, 19);
        final command = platform == 'dingtalk'
            ? scoped([
                'chat',
                'message',
                'list',
                ...target(c),
                '--limit',
                '50',
                '--time',
                dt,
                '--direction',
                older || args['since'] == null ? 'older' : 'newer',
              ])
            : scoped([
                'im',
                '+chat-messages-list',
                '--chat-id',
                c['id'],
                '--page-size',
                '50',
                '--no-reactions',
                '--order',
                args['since'] != null ? 'asc' : 'desc',
                if (args['since'] != null) ...[
                  '--start',
                  time.toUtc().toIso8601String(),
                ],
                if (older) ...['--end', time.toUtc().toIso8601String()],
                if (args['cursor'] != null) ...['--page-token', args['cursor']],
              ], user: true);
        final value = await run(id, command);
        final items = rows(
          value,
        ).map((j) => normalizeMessage(accountId, c['id'], j).toJson()).toList();
        return {
          'items': items,
          'cursor': field(object(value), [
            'nextCursor',
            'nextPageToken',
            'page_token',
            'next_page_token',
          ]),
          'hasMore':
              object(value)['has_more'] ??
              object(value)['hasMore'] ??
              items.length == 50,
        };
      case 'send':
        if (args['approved'] != true) {
          throw const AppFailure('approval', '发送未授权');
        }
        final c = object(args['conversation']);
        final reply = object(args['reply']);
        final text = '${args['text'] ?? ''}';
        final attachment = '${args['attachment'] ?? ''}';
        final key = args['idempotencyKey'] as String;
        if (platform == 'dingtalk' &&
            reply.isNotEmpty &&
            attachment.isNotEmpty) {
          throw const AppFailure('unsupported', '当前钉钉契约不支持附件引用回复，请单独发送附件');
        }
        final file = attachment.isEmpty
            ? null
            : p.join('outgoing', p.basename(attachment));
        if (file != null) {
          await Directory(
            p.join(directory, 'outgoing'),
          ).create(recursive: true);
          await File(attachment).copy(p.join(directory, file));
        }
        List<String> command;
        if (platform == 'dingtalk') {
          if (reply.isNotEmpty && file == null) {
            command = [
              'chat',
              'message',
              'reply',
              '--conversation-id',
              c['id'],
              '--ref-msg-id',
              reply['id'],
              '--ref-sender',
              reply['senderId'],
              '--text',
              text,
              '--uuid',
              key,
            ];
          } else if (file != null && args['image'] == true) {
            final media = await run(
              id,
              scoped([
                'chat',
                'media',
                'upload',
                '--file',
                file,
                '--type',
                'image',
              ]),
            );
            final mediaId = field(object(media), ['mediaId', 'media_id']);
            if (mediaId.isEmpty) {
              throw const AppFailure('contract', '上传结果缺少 mediaId');
            }
            command = [
              'chat',
              'message',
              'send',
              ...target(c),
              '--msg-type',
              'image',
              '--media-id',
              mediaId,
              '--uuid',
              key,
            ];
          } else {
            command = [
              'chat',
              'message',
              'send',
              ...target(c),
              if (file != null) ...[
                '--msg-type',
                'file',
                '--file-path',
                file,
              ] else ...[
                '--text',
                text,
              ],
              '--uuid',
              key,
            ];
          }
        } else {
          command = [
            'im',
            reply.isEmpty ? '+messages-send' : '+messages-reply',
            if (reply.isEmpty) ...[
              '--chat-id',
              c['id'],
            ] else ...[
              '--message-id',
              reply['id'],
            ],
            if (file != null) ...[
              args['image'] == true ? '--image' : '--file',
              file,
            ] else ...[
              args['markdown'] == true ? '--markdown' : '--text',
              text,
            ],
            '--idempotency-key',
            key,
          ];
        }
        final value = await run(id, scoped(command, user: true));
        return {
          'result': value,
          'messageId': field(object(value), [
            'message_id',
            'openMessageId',
            'messageId',
          ]),
        };
      case 'attachment.download':
        final message = object(args['message']);
        final resourceId = '${args['resourceId'] ?? ''}';
        if (resourceId.isEmpty) {
          throw const AppFailure('resource', '消息未提供可下载资源 ID');
        }
        final relative = p.join('downloads', newId());
        await Directory(p.join(directory, 'downloads')).create(recursive: true);
        await run(
          id,
          platform == 'dingtalk'
              ? scoped([
                  'chat',
                  'message',
                  'download-media',
                  '--type',
                  'mediaId',
                  '--resource-id',
                  resourceId,
                  '--message-id',
                  message['id'],
                  '--open-conversation-id',
                  message['conversationId'],
                  '--output',
                  relative,
                ])
              : scoped([
                  'im',
                  '+messages-resources-download',
                  '--message-id',
                  message['id'],
                  '--file-key',
                  resourceId,
                  '--type',
                  message['kind'] == 'image' ? 'image' : 'file',
                  '--output',
                  relative,
                ], user: true),
        );
        return {'path': p.join(directory, relative)};
      case 'conversation.open':
        final contact = object(args['contact']);
        final peer = field(contact, [
          'open_id',
          'openId',
          'openDingTalkId',
          'openDingtalkId',
        ]);
        if (platform == 'feishu') {
          final chat = field(contact, ['p2p_chat_id']);
          if (chat.isEmpty) {
            throw const AppFailure('unsupported', '联系人未返回单聊 ID');
          }
          return Conversation(
            accountId: accountId,
            id: chat,
            title: field(contact, ['name', 'display_name'], peer),
            kind: 'p2p',
            peerId: peer,
          ).toJson();
        }
        if (peer.isEmpty) {
          throw const AppFailure('unsupported', '联系人未返回 openDingTalkId');
        }
        final value = object(
          await run(
            id,
            scoped(['chat', 'conversation-info', '--open-dingtalk-id', peer]),
          ),
        );
        final chat = field(value, [
          'openConversationId',
          'conversationId',
          'id',
        ]);
        if (chat.isEmpty) throw const AppFailure('contract', '会话详情缺少 ID');
        return Conversation(
          accountId: accountId,
          id: chat,
          title: field(contact, ['name', 'nick', 'displayName'], peer),
          kind: 'p2p',
          peerId: peer,
        ).toJson();
      case 'messages.search':
        final query = '${args['query']}';
        final now = DateTime.now().toUtc();
        final value = await run(
          id,
          platform == 'dingtalk'
              ? scoped([
                  'chat',
                  'message',
                  'search',
                  '--query',
                  query,
                  '--start',
                  now.subtract(const Duration(days: 30)).toIso8601String(),
                  '--end',
                  now.toIso8601String(),
                  '--limit',
                  '50',
                  '--cursor',
                  '0',
                ])
              : scoped([
                  'im',
                  '+messages-search',
                  '--query',
                  query,
                ], user: true),
        );
        return {
          'items': rows(
            value,
          ).map((j) => normalizeMessage(accountId, '', j).toJson()).toList(),
          'coverage': '最近30天或平台搜索可见范围，最多50条',
        };
      case 'resources.search':
        final query = '${args['query']}';
        final value = await run(
          id,
          platform == 'dingtalk'
              ? scoped(['doc', 'search', '--query', query, '--limit', '20'])
              : scoped([
                  'drive',
                  '+search',
                  '--query',
                  query,
                  '--page-size',
                  '20',
                ], user: true),
        );
        return {
          'items': rows(value)
              .map(
                (j) => ResourceRef(
                  accountId: accountId,
                  id: field(j, ['token', 'nodeId', 'node_id', 'id', 'url']),
                  title: field(j, ['title', 'name'], '文档'),
                  url: field(j, ['url', 'link']),
                  text: field(j, ['summary', 'snippet']),
                  updatedAt: timestamp(j['update_time'] ?? j['modifiedTime']),
                ).toJson(),
              )
              .where((j) => (j['id'] as String).isNotEmpty)
              .toList(),
        };
      case 'resources.read':
        final value = await run(
          id,
          platform == 'dingtalk'
              ? scoped(['doc', 'read', '--node', args['id']])
              : scoped([
                  'docs',
                  '+fetch',
                  '--doc',
                  args['id'],
                  '--doc-format',
                  'markdown',
                ], user: true),
        );
        return {'text': bodyText(value)};
      case 'contacts.resolve':
        final ids = (args['ids'] as List? ?? [])
            .whereType<String>()
            .take(20)
            .toList();
        if (ids.isEmpty) return {'items': []};
        final openIds = object(args['openIds']);
        final conversation = object(args['conversation']);
        final profiles = <String, Json>{};
        if (platform == 'dingtalk' &&
            conversation['kind'] == 'group' &&
            openIds.isNotEmpty &&
            !(_groupProfileRetry['${conversation['id']}']?.isAfter(
                  DateTime.now(),
                ) ??
                false)) {
          try {
            final value = await run(
              id,
              scoped([
                'chat',
                'group',
                'members',
                'list-by-ids',
                '--id',
                conversation['id'],
                '--users',
                ids
                    .where((id) => openIds[id] != null)
                    .map((id) => openIds[id])
                    .join(','),
              ]),
            );
            for (final j in rows(value)) {
              final openId = field(j, ['openDingTalkId', 'openDingtalkId']);
              final profile = normalizeSenderProfile(j);
              final matching = ids
                  .where(
                    (id) =>
                        id == profile['id'] ||
                        (openId.isNotEmpty && openIds[id] == openId),
                  )
                  .firstOrNull;
              if (matching != null) {
                profiles[matching] = {...profile, 'id': matching};
              }
            }
          } on AppFailure {
            _groupProfileRetry['${conversation['id']}'] = DateTime.now().add(
              const Duration(minutes: 5),
            );
            // Directory lookup can still supply names when group scope is absent.
          }
        }
        final remaining = ids
            .where(
              (id) =>
                  profiles[id] == null ||
                  profiles[id]!['name'] == '' ||
                  (profiles[id]!['avatar'] == '' &&
                      profiles[id]!['avatarResourceId'] == null),
            )
            .toList();
        if (remaining.isNotEmpty) {
          try {
            final value = await run(
              id,
              platform == 'dingtalk'
                  ? scoped([
                      'contact',
                      'user',
                      'get',
                      '--ids',
                      remaining.join(','),
                    ])
                  : scoped([
                      'contact',
                      '+search-user',
                      '--user-ids',
                      remaining.join(','),
                    ], user: true),
            );
            for (final j in rows(value)) {
              final profile = normalizeSenderProfile(j);
              final id = '${profile['id']}';
              if (!ids.contains(id)) continue;
              final previous = profiles[id] ?? <String, dynamic>{};
              profiles[id] = {
                'id': id,
                'name': field(previous, ['name'], '${profile['name']}'),
                'avatar': field(previous, ['avatar'], '${profile['avatar']}'),
                if (previous['avatarResourceId'] != null ||
                    profile['avatarResourceId'] != null)
                  'avatarResourceId':
                      previous['avatarResourceId'] ??
                      profile['avatarResourceId'],
              };
            }
          } on AppFailure {
            if (profiles.isEmpty) rethrow;
          }
        }
        return {'items': profiles.values.toList()};
      case 'contacts':
        return {
          'items': rows(
            await run(
              id,
              platform == 'dingtalk'
                  ? scoped([
                      'aisearch',
                      'person',
                      '--keyword',
                      args['query'],
                      '--dimension',
                      'name',
                    ])
                  : scoped([
                      'contact',
                      '+search-user',
                      '--query',
                      args['query'],
                    ], user: true),
            ),
          ),
        };
      case 'tool.execute':
        final tool = args['tool'];
        final a = object(args['arguments']);
        if (args['approved'] != true) {
          throw const AppFailure('approval', '业务写入未授权');
        }
        if (tool == 'document.create') {
          return run(
            id,
            platform == 'dingtalk'
                ? scoped([
                    'doc',
                    'create',
                    '--name',
                    a['title'],
                    '--content',
                    '-',
                  ])
                : scoped([
                    'docs',
                    '+create',
                    '--title',
                    a['title'],
                    '--content',
                    '-',
                    '--doc-format',
                    'markdown',
                  ], user: true),
            input: a['content'],
          );
        }
        if (tool == 'task.create') {
          return run(
            id,
            platform == 'dingtalk'
                ? scoped([
                    'todo',
                    'task',
                    'create',
                    '--title',
                    a['title'],
                    '--executors',
                    a['assignee'],
                    if ('${a['due'] ?? ''}'.isNotEmpty) ...['--due', a['due']],
                  ])
                : scoped([
                    'task',
                    '+create',
                    '--summary',
                    a['title'],
                    '--assignee',
                    a['assignee'],
                    '--idempotency-key',
                    args['idempotencyKey'],
                    if ('${a['due'] ?? ''}'.isNotEmpty) ...['--due', a['due']],
                  ], user: true),
          );
        }
        throw const AppFailure('unsupported', '未注册的业务工具');
      case 'subscribe':
        if (platform != 'dingtalk') {
          throw const AppFailure('unsupported', '飞书个人会话采用定时同步');
        }
        final c = object(args['conversation']);
        if (streams.containsKey(c['id'])) return {};
        final command = [
          'event',
          'consume',
          c['kind'] == 'p2p'
              ? 'user_im_message_receive_o2o'
              : 'user_im_message_receive_group',
          ...target(c),
          '--format',
          'ndjson',
          if (profile.isNotEmpty) ...['--profile', profile],
        ];
        final child = await Process.start(
          binary,
          command,
          workingDirectory: directory,
          environment: environment,
          includeParentEnvironment: false,
        );
        streams[c['id']] = child;
        var errorTail = '';
        final outputDone = child.stdout
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter())
            .forEach((line) {
              try {
                final j = object(unwrap(jsonDecode(line)));
                emit({
                  'method': 'message',
                  'params': normalizeMessage(
                    accountId,
                    c['id'],
                    object(j['payload'] ?? j),
                  ).toJson(),
                });
              } catch (e) {
                diagnostic(
                  'event.decode',
                  '消息事件解析失败：${e.runtimeType}',
                  conversationId: '${c['id']}',
                );
                emit({
                  'method': 'sync.gap',
                  'params': {'conversationId': c['id'], 'reason': '事件解析失败，需补拉'},
                });
              }
            });
        final errorDone = child.stderr
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter())
            .forEach((line) {
              errorTail += '$line\n';
              if (errorTail.length > 16384) {
                errorTail = errorTail.substring(errorTail.length - 16384);
              }
              if (line.contains('ready')) {
                emit({
                  'method': 'sync.ready',
                  'params': {'conversationId': c['id']},
                });
              }
            });
        unawaited(() async {
          final code = await child.exitCode;
          await Future.wait([outputDone, errorDone]);
          // Explicit unsubscribe/shutdown must not trigger an error or reconnect.
          if (!identical(streams[c['id']], child)) return;
          streams.remove(c['id']);
          final detail = diagnosticText(errorTail);
          diagnostic(
            'event consume',
            detail.isEmpty ? '订阅进程退出，没有错误输出' : detail,
            exitCode: code,
            conversationId: '${c['id']}',
          );
          emit({
            'method': 'sync.gap',
            'params': {
              'conversationId': c['id'],
              'disconnected': true,
              'reason': '订阅已断开 ($code)${detail.isEmpty ? '' : '：$detail'}',
            },
          });
        }());
        return {'started': true};
      case 'unsubscribe':
        final child = streams.remove(args['conversationId']);
        await child?.stdin.close();
        return {};
      case 'shutdown':
        final subscriptions = streams.values.toList();
        streams.clear();
        for (final child in subscriptions) {
          await child.stdin.close();
        }
        for (final child in processes.values.toList()) {
          child.kill();
        }
        return {'closed': true};
      default:
        throw AppFailure('method', '未支持的方法 $method');
    }
  }
}

Future<void> main() async {
  final adapter = Adapter();
  final pending = <Future<void>>{};
  await for (final line
      in stdin.transform(utf8.decoder).transform(const LineSplitter())) {
    Json request;
    try {
      request = object(jsonDecode(line));
    } catch (_) {
      continue;
    }
    final method = '${request['method']}';
    final args = object(request['params']);
    if (method == 'cancel') {
      adapter.processes[args['id']]?.kill();
      continue;
    }
    final id = request['id'] ?? newId();
    late Future<void> task;
    task = (() async {
      try {
        final result = await adapter.handle(id, method, args);
        emit({'id': id, 'result': result});
      } catch (e) {
        if (e is! AppFailure) {
          adapter.diagnostic(method, '适配器错误：${e.runtimeType}');
        }
        emit({
          'id': id,
          'error': e is AppFailure
              ? e.toJson()
              : {'code': 'adapter', 'message': '适配器错误：${e.runtimeType}'},
        });
      }
    })();
    pending.add(task);
    task.whenComplete(() => pending.remove(task));
    if (method == 'shutdown') {
      await task;
      break;
    }
  }
  if (adapter.initialized) await adapter.handle('exit', 'shutdown', {});
  await Future.wait(
    pending,
  ).timeout(const Duration(seconds: 5), onTimeout: () => []);
  exit(0);
}
