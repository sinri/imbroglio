import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import '../core/models.dart';
import 'store.dart';

const _vault = FlutterSecureStorage(
  mOptions: MacOsOptions(usesDataProtectionKeychain: false),
);
const mcpVersions = ['2025-11-25', '2025-06-18', '2025-03-26'];
const _maxBytes = 2 * 1024 * 1024;

class McpRepository {
  final Store store;
  McpRepository(this.store);
  Future<List<Json>> list() => store.list('mcpServers');
  Future<bool> isCurrent(Json config) async {
    final current = await store.get('mcpServers', config['id']);
    return current?['enabled'] == true &&
        current?['revision'] == config['revision'];
  }

  Future<Json> load(String id) async {
    final config = await store.get('mcpServers', id);
    if (config == null) throw const AppFailure('mcp_missing', 'MCP 服务器不存在');
    final secret = await _vault.read(key: 'imbroglio.mcp.$id');
    return {...config, if (secret != null) ...object(jsonDecode(secret))};
  }

  Future<void> save(Json config, {bool enabled = false}) async {
    validateMcpConfig(config);
    final id = config['id'] as String;
    await _vault.write(
      key: 'imbroglio.mcp.$id',
      value: jsonEncode({
        'env': config['env'] ?? {},
        'headers': config['headers'] ?? {},
      }),
    );
    final public = {...config}
      ..remove('env')
      ..remove('headers');
    await store.put('mcpServers', id, {
      ...public,
      'enabled': enabled,
      'revision': newId(),
    });
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final config = await store.get('mcpServers', id);
    if (config == null) return;
    await store.put('mcpServers', id, {
      ...config,
      'enabled': enabled,
      'revision': newId(),
    });
  }

  Future<void> remove(String id) async {
    await _vault.delete(key: 'imbroglio.mcp.$id');
    await store.remove('mcpServers', id);
  }
}

void validateMcpConfig(Json config) {
  if (config['id'] is! String ||
      !RegExp(r'^[a-z][a-z0-9_.-]{1,63}$').hasMatch(config['id']) ||
      config['name'] is! String ||
      (config['name'] as String).trim().isEmpty ||
      !['stdio', 'http'].contains(config['transport'])) {
    throw const FormatException('请填写有效的 ID、名称和 transport（stdio 或 http）');
  }
  for (final field in ['env', 'headers']) {
    if (config[field] != null &&
        (config[field] is! Map ||
            (config[field] as Map).entries.any(
              (e) => e.key is! String || e.value is! String,
            ))) {
      throw FormatException('$field 必须是字符串键值对象');
    }
  }
  final headers = object(config['headers']);
  if (headers.keys.any(
    (k) => [
      'host',
      'content-length',
      'content-type',
      'accept',
      'mcp-session-id',
      'mcp-protocol-version',
    ].contains(k.toLowerCase()),
  )) {
    throw const FormatException('headers 不能覆盖 MCP 协议头');
  }
  if (config['transport'] == 'stdio') {
    if (config['command'] is! String ||
        (config['command'] as String).trim().isEmpty ||
        (config['args'] != null &&
            (config['args'] is! List ||
                (config['args'] as List).any((a) => a is! String))) ||
        (config['cwd'] != null && config['cwd'] is! String)) {
      throw const FormatException('stdio 需要 command、字符串数组 args 和可选 cwd');
    }
  } else {
    final uri = Uri.tryParse('${config['url'] ?? ''}');
    if (uri == null ||
        !uri.hasAuthority ||
        uri.userInfo.isNotEmpty ||
        uri.fragment.isNotEmpty ||
        (uri.scheme != 'https' &&
            !(uri.scheme == 'http' &&
                ['localhost', '127.0.0.1', '::1'].contains(uri.host)))) {
      throw const FormatException('远程 MCP 使用 HTTPS；仅本机地址允许 HTTP');
    }
  }
}

/// One connection per Agent run. No automatic retry of tools/call.
class McpClient {
  final Json config;
  final Duration timeout;
  McpClient(this.config, {this.timeout = const Duration(seconds: 45)});
  Process? _process;
  final _http = http.Client();
  StreamSubscription<List<int>>? _stdout, _stderr;
  final _pending = <int, Completer<Json>>{};
  final _methods = <int, String>{};
  Future<void>? _closing;
  final _line = <int>[];
  int _sequence = 0;
  bool _closed = false;
  String? _session, _version;
  Json capabilities = {};

  Future<void> connect() async {
    validateMcpConfig(config);
    if (config['enabled'] != true) {
      throw const AppFailure('mcp_disabled', '请先启用 MCP 服务器');
    }
    if (_closed) throw const AppFailure('mcp_closed', 'MCP 连接已关闭');
    try {
      if (config['transport'] == 'stdio') {
        final process = await Process.start(
          config['command'],
          (config['args'] as List? ?? []).cast<String>(),
          workingDirectory: config['cwd'],
          environment: object(config['env']).cast<String, String>(),
          runInShell: false,
        );
        _process = process;
        if (_closed) {
          process.kill(ProcessSignal.sigkill);
          throw const AppFailure('mcp_closed', 'MCP 连接已取消');
        }
        unawaited(process.stdin.done.catchError((Object _) {}));
        _stdout = process.stdout.listen(
          _readBytes,
          onError: (Object e) => _fail(e),
          onDone: () => _fail(const AppFailure('mcp_exit', 'MCP 输出流已关闭')),
        );
        // Drain diagnostics without retaining potentially sensitive server output.
        _stderr = process.stderr.listen((_) {}, onError: (Object _) {});
        unawaited(
          process.exitCode.then(
            (_) => _fail(const AppFailure('mcp_exit', 'MCP 进程已退出')),
          ),
        );
      }
      final initialized = await request('initialize', {
        'protocolVersion': mcpVersions.first,
        'capabilities': {},
        'clientInfo': {'name': 'Imbroglio', 'version': '1.0.0'},
      });
      if (!mcpVersions.contains(initialized['protocolVersion'])) {
        throw const AppFailure('mcp_version', 'MCP 协议版本不兼容');
      }
      _version = initialized['protocolVersion'];
      capabilities = object(initialized['capabilities']);
      await _send({'jsonrpc': '2.0', 'method': 'notifications/initialized'});
    } catch (_) {
      await close();
      rethrow;
    }
  }

  void _readBytes(List<int> bytes) {
    try {
      for (final byte in bytes) {
        if (byte == 10) {
          if (_line.isNotEmpty) {
            _receive(object(jsonDecode(utf8.decode(_line))));
          }
          _line.clear();
        } else {
          _line.add(byte);
          if (_line.length > _maxBytes) {
            throw const AppFailure('mcp_limit', 'MCP 消息超过 2 MiB');
          }
        }
      }
    } catch (e) {
      _fail(e);
      unawaited(close());
    }
  }

  void _receive(Json message) {
    if (message['jsonrpc'] != '2.0') {
      throw const FormatException('无效 MCP JSON-RPC 响应');
    }
    if (message.containsKey('method')) {
      if (message.containsKey('id')) {
        unawaited(
          _send({
            'jsonrpc': '2.0',
            'id': message['id'],
            if (message['method'] == 'ping')
              'result': <String, dynamic>{}
            else
              'error': {
                'code': -32601,
                'message': 'Client capability not supported',
              },
          }).catchError((Object e) => _fail(e)),
        );
      }
      return;
    }
    final pending = _pending[message['id']];
    if (pending == null || pending.isCompleted) return;
    if (message['error'] != null) {
      // Do not echo server errors that may contain authentication values.
      pending.completeError(
        AppFailure('mcp_rpc', 'MCP 请求失败（${object(message['error'])['code']}）'),
      );
    } else if (message['result'] is Map) {
      pending.complete(object(message['result']));
    } else {
      pending.completeError(const FormatException('MCP 响应缺少 result'));
    }
  }

  Future<Json> request(String method, [Json params = const {}]) async {
    if (_closed) throw const AppFailure('mcp_closed', 'MCP 连接已关闭');
    final id = ++_sequence;
    final result = Completer<Json>();
    _pending[id] = result;
    _methods[id] = method;
    // Attach the response listener before sending (the process may exit meanwhile).
    final response = result.future;
    unawaited(response.then<void>((_) {}, onError: (Object _) {}));
    try {
      return await (() async {
        await _send({
          'jsonrpc': '2.0',
          'id': id,
          'method': method,
          'params': params,
        });
        return await response;
      })().timeout(timeout);
    } on TimeoutException {
      await close();
      throw const AppFailure('mcp_timeout', 'MCP 请求超时；操作结果可能未知，请核对后再试');
    } finally {
      _pending.remove(id);
      _methods.remove(id);
    }
  }

  Future<void> _send(Json message) async {
    if (_closed) throw const AppFailure('mcp_closed', 'MCP 连接已关闭');
    if (config['transport'] == 'stdio') {
      _process!.stdin.writeln(jsonEncode(message));
      return;
    }
    final request = http.Request('POST', Uri.parse(config['url']))
      ..followRedirects = false
      ..headers.addAll({
        ...object(config['headers']).cast<String, String>(),
        'Content-Type': 'application/json',
        'Accept': 'application/json, text/event-stream',
        'MCP-Session-Id': ?_session,
        'MCP-Protocol-Version': ?_version,
      })
      ..body = jsonEncode(message);
    final response = await _http.send(request).timeout(timeout);
    if (response.statusCode == 202 &&
        (!message.containsKey('method') || !message.containsKey('id'))) {
      await response.stream.listen((_) {}).cancel();
      return;
    }
    if (response.statusCode != 200) {
      await response.stream.listen((_) {}).cancel();
      throw AppFailure(
        'mcp_http',
        'MCP HTTP ${response.statusCode}；请检查地址与认证配置',
      );
    }
    if (message['method'] == 'initialize') {
      _session = response.headers['mcp-session-id'];
    }
    var total = 0;
    final limited = response.stream.map((bytes) {
      total += bytes.length;
      if (total > _maxBytes) {
        throw const AppFailure('mcp_limit', 'MCP 响应超过 2 MiB');
      }
      return bytes;
    });
    final type = response.headers['content-type'] ?? '';
    if (type.contains('text/event-stream')) {
      final data = <String>[];
      await for (final line
          in limited
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .timeout(timeout)) {
        if (line.isEmpty) {
          if (data.isNotEmpty) {
            final raw = data.join('\n');
            data.clear();
            if (raw.trim().isNotEmpty) {
              final event = object(jsonDecode(raw));
              _receive(event);
              if (event['id'] == message['id'] &&
                  !event.containsKey('method')) {
                return;
              }
            }
          }
        } else if (line.startsWith('data:')) {
          data.add(line.substring(5).replaceFirst(RegExp(r'^ '), ''));
        }
      }
    } else if (type.contains('application/json')) {
      _receive(
        object(jsonDecode(await limited.transform(utf8.decoder).join())),
      );
    } else {
      await response.stream.listen((_) {}).cancel();
      throw const FormatException('MCP 返回了不支持的内容类型');
    }
  }

  Future<List<Json>> listTools() async {
    if (!capabilities.containsKey('tools')) return [];
    final tools = <Json>[];
    final names = <String>{}, cursors = <String>{};
    String? cursor;
    do {
      final page = await request('tools/list', {'cursor': ?cursor});
      for (final raw in page['tools'] as List) {
        final tool = object(raw);
        if (tool['name'] is! String ||
            !names.add(tool['name']) ||
            tool['inputSchema'] is! Map ||
            object(tool['inputSchema'])['type'] != 'object') {
          throw const FormatException('MCP 工具名称或 inputSchema 无效');
        }
        tools.add(tool);
        if (tools.length > 128) {
          throw const AppFailure('mcp_limit', 'MCP 工具超过 128 个');
        }
      }
      cursor = page['nextCursor'] as String?;
      if (cursor != null && (!cursors.add(cursor) || cursors.length > 32)) {
        throw const AppFailure('mcp_limit', 'MCP 工具分页异常');
      }
    } while (cursor != null);
    return tools;
  }

  Future<Json> callTool(String name, Json arguments) =>
      request('tools/call', {'name': name, 'arguments': arguments});

  void _fail(Object error) {
    for (final pending in _pending.values) {
      if (!pending.isCompleted) pending.completeError(error);
    }
  }

  Future<void> close() => _closing ??= _close();

  Future<void> _close() async {
    if (_closed) return;
    final cancellations = <Future<void>>[];
    for (final id in _pending.keys.toList()) {
      if (_methods[id] == 'initialize') continue;
      cancellations.add(
        _send({
          'jsonrpc': '2.0',
          'method': 'notifications/cancelled',
          'params': {'requestId': id, 'reason': 'Client stopped'},
        }).catchError((Object _) {}),
      );
    }
    _closed = true;
    _fail(const AppFailure('mcp_closed', 'MCP 连接已关闭；已发出的操作可能仍在执行'));
    try {
      await Future.wait(cancellations).timeout(const Duration(seconds: 1));
      if (_session != null && config['transport'] == 'http') {
        final request = http.Request('DELETE', Uri.parse(config['url']))
          ..followRedirects = false
          ..headers.addAll({
            ...object(config['headers']).cast<String, String>(),
            'MCP-Session-Id': _session!,
            'MCP-Protocol-Version': ?_version,
          });
        final response = await _http
            .send(request)
            .timeout(const Duration(seconds: 1));
        await response.stream.listen((_) {}).cancel();
      }
    } catch (_) {
      /* Termination is best effort; do not retry writes. */
    }
    _http.close();
    final process = _process;
    if (process != null) {
      unawaited(process.stdin.close().catchError((Object _) {}));
      try {
        await process.exitCode.timeout(const Duration(milliseconds: 300));
      } on TimeoutException {
        process.kill();
      }
      try {
        await process.exitCode.timeout(const Duration(milliseconds: 300));
      } on TimeoutException {
        process.kill(ProcessSignal.sigkill);
      }
    }
    await _stdout?.cancel();
    await _stderr?.cancel();
  }
}
