import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'models.dart';
import 'diagnostics.dart';

/// One JSON-RPC object per line. stdout is exclusively protocol traffic.
class RpcClient {
  final Process process;
  final _pending = <int, Completer<dynamic>>{};
  final _methods = <int, String>{};
  final events = StreamController<Json>.broadcast();
  int _sequence = 0;
  bool _closed = false;
  bool _exited = false;
  bool _closing = false;
  bool get hasPending => _pending.isNotEmpty;
  RpcClient(this.process) {
    process.stdout
        .transform(utf8.decoder)
        .transform(const LineSplitter())
        .listen((line) {
          try {
            if (line.length > 8 * 1024 * 1024) {
              throw const FormatException('协议消息过大');
            }
            final j = object(jsonDecode(line));
            if (j['id'] != null) {
              final completer = _pending.remove(j['id']);
              if (completer == null) return;
              if (j['error'] != null) {
                final e = object(j['error']);
                completer.completeError(
                  AppFailure(
                    '${e['code']}',
                    '${e['message']}',
                    retryAfter: e['retryAfter'] as int?,
                  ),
                );
              } else {
                completer.complete(j['result']);
              }
            } else if (!_closed) {
              events.add(j);
            }
          } catch (_) {
            _fail(const AppFailure('protocol', '插件返回了无效协议数据'));
          }
        }, onError: (Object e) => _fail(e));
    var errorTail = '';
    final errorsDone = process.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .forEach((chunk) {
          errorTail += chunk;
          if (errorTail.length > 16384) {
            errorTail = errorTail.substring(errorTail.length - 16384);
          }
        });
    process.exitCode.then((code) async {
      _exited = true;
      _fail(AppFailure('process_exit', '插件进程退出 ($code)'));
      await errorsDone;
      if (!_closed && !_closing) {
        events.add({
          'method': 'diagnostic',
          'params': {
            'operation': 'adapter.exit',
            'exitCode': code,
            'detail': diagnosticText(
              errorTail.isEmpty ? '插件进程意外退出，没有错误输出' : errorTail,
            ),
          },
        });
      }
    });
  }
  Future<dynamic> call(
    String method, [
    Json params = const {},
    Duration timeout = const Duration(seconds: 45),
  ]) async {
    if (_closed || _exited) throw const AppFailure('closed', '插件已关闭');
    final id = ++_sequence;
    final c = Completer<dynamic>();
    _pending[id] = c;
    _methods[id] = method;
    try {
      process.stdin.writeln(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'method': method,
          'params': params,
        }),
      );
      return await c.future.timeout(timeout);
    } on TimeoutException {
      notify('cancel', {'id': id});
      throw const AppFailure('timeout', '请求超时，写入结果可能未知，请先核对');
    } finally {
      _pending.remove(id);
      _methods.remove(id);
    }
  }

  void cancelPending(Set<String> methods) {
    for (final entry in _methods.entries.toList()) {
      if (!methods.contains(entry.value)) continue;
      final pending = _pending.remove(entry.key);
      if (pending == null || pending.isCompleted) continue;
      notify('cancel', {'id': entry.key});
      pending.completeError(const AppFailure('cancelled', '授权已中止'));
    }
  }

  void notify(String method, Json params) {
    if (!_closed && !_exited) {
      process.stdin.writeln(
        jsonEncode({'jsonrpc': '2.0', 'method': method, 'params': params}),
      );
    }
  }

  void _fail(Object e) {
    for (final c in _pending.values) {
      if (!c.isCompleted) c.completeError(e);
    }
    _pending.clear();
  }

  Future<void> close() async {
    if (_closed) return;
    _closing = true;
    try {
      await call('shutdown', {}, const Duration(seconds: 5));
    } catch (_) {
      /* child may already be gone */
    }
    _closed = true;
    try {
      await process.stdin.close();
    } catch (_) {
      /* already exited */
    }
    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
    } catch (_) {
      process.kill();
    }
    _fail(const AppFailure('closed', '插件已关闭'));
    await events.close();
  }
}
