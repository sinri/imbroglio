import 'dart:convert';

/// Retain error summaries, never whole JSON request/response envelopes.
String diagnosticText(String input) {
  String extract(Object? value, int depth) {
    if (depth > 6) return '';
    if (value is String) return value;
    if (value is! Map) return '';
    return [
      for (final key in [
        'error_code',
        'errorCode',
        'code',
        'error_msg',
        'errorMsg',
        'message',
        'msg',
        'trace_id',
        'error',
      ])
        if (value[key] != null) extract(value[key], depth + 1),
    ].where((s) => s.isNotEmpty).join(' · ');
  }

  final lines = input
      .split('\n')
      .map((line) {
        try {
          return extract(jsonDecode(line), 0);
        } catch (_) {
          return line;
        }
      })
      .where((s) => s.isNotEmpty)
      .join('\n');
  var safe = lines.replaceAll(RegExp(r'\x1B\[[0-9;]*[a-zA-Z]'), '');
  safe = safe.replaceAll(RegExp(r'https?://[^\s<>"\x27]+'), '[URL]');
  safe = safe.replaceAll(
    RegExp(r'bearer\s+[^\s,;]+', caseSensitive: false),
    'Bearer [已隐藏]',
  );
  safe = safe.replaceAllMapped(
    RegExp(
      r'''(access[_-]?token|refresh[_-]?token|token|secret|password|authorization|cookie|appSecret|clientSecret)["'\s:=]+[^\s,;}]+''',
      caseSensitive: false,
    ),
    (m) => '${m[1]}=[已隐藏]',
  );
  return safe.length > 4096 ? '…${safe.substring(safe.length - 4096)}' : safe;
}

bool confidentialFailure(String message) =>
    message.contains('保密群') &&
    (message.contains('无法获取') ||
        message.contains('不支持') ||
        message.contains('不允许'));

/// Transport failures are recoverable; permission and API validation errors are not.
bool transientNetworkFailure(Object error) {
  final text = error.toString().toLowerCase();
  return [
    'no such host',
    'failed host lookup',
    'network is unreachable',
    'network is down',
    'connection refused',
    'connection reset',
    'connection timed out',
    'i/o timeout',
    'socketexception',
    'timeoutexception',
    'temporary failure in name resolution',
    'tls handshake timeout',
    'client.timeout exceeded',
  ].any(text.contains);
}
