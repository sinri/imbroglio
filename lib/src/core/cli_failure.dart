import 'dart:convert';

import 'diagnostics.dart';
import 'models.dart';

// CLI progress and a pretty-printed JSON error can share the same stream.
Iterable<Json> cliJsonDocuments(String text) sync* {
  var start = -1, depth = 0;
  var quoted = false, escaped = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (start < 0) {
      if (c != '{') continue;
      start = i;
      depth = 1;
      continue;
    }
    if (quoted) {
      if (escaped) {
        escaped = false;
      } else if (c == r'\') {
        escaped = true;
      } else if (c == '"') {
        quoted = false;
      }
    } else if (c == '"') {
      quoted = true;
    } else if (c == '{') {
      depth++;
    } else if (c == '}' && --depth == 0) {
      try {
        yield object(jsonDecode(text.substring(start, i + 1)));
      } on FormatException {
        // Human-readable progress can also contain braces.
      }
      start = -1;
    }
  }
}

AppFailure cliFailure(int exitCode, String stderr, String stdout) {
  Json? envelope;
  // Prefer stderr, but some CLI commands emit their error on stdout.
  for (final stream in [stderr, stdout]) {
    final clean = stream.replaceAll(RegExp(r'\x1B\[[0-9;]*[a-zA-Z]'), '');
    for (final value in cliJsonDocuments(clean)) {
      if (value['error'] != null ||
          value['ok'] == false ||
          value['message'] != null ||
          value['errorMsg'] != null) {
        envelope = value;
      }
    }
    if (envelope != null) break;
  }
  final j = envelope ?? <String, dynamic>{};
  final e = object(j['error']);
  final detail =
      e['message'] ??
      j['message'] ??
      j['errorMsg'] ??
      (j['error'] is String ? j['error'] : null);
  final hint = e['hint'] ?? j['hint'];
  final summary = diagnosticText(
    [if (detail != null) '$detail', if (hint != null) '处理建议：$hint'].join('\n'),
  );
  var kind = '${e['type'] ?? 'upstream'}';
  if (e['code'] == 429 || e['subtype'] == 'rate_limit') kind = 'rate_limit';
  if (exitCode == 10) kind = 'confirmation';
  return AppFailure(
    kind,
    summary.isEmpty
        ? 'CLI 请求失败 ($exitCode)，请查看 CLI 诊断记录'
        : 'CLI 请求失败 ($exitCode)：$summary',
    retryAfter: int.tryParse(
      '${e['retry_after'] ?? e['retryAfter'] ?? j['retry_after']}',
    ),
  );
}
