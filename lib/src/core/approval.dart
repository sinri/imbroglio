import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'models.dart';

Object? canonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.map((k) => k.toString()).toList()..sort();
    return {for (final k in keys) k: canonical(value[k])};
  }
  if (value is List) return value.map(canonical).toList();
  return value;
}

String actionDigest(String accountId, String tool, Json args) => sha256
    .convert(
      utf8.encode(
        jsonEncode(
          canonical({'account': accountId, 'tool': tool, 'args': args}),
        ),
      ),
    )
    .toString();

class ApprovalGate {
  final _grants = <String, String>{};
  String approve(String account, String tool, Json args) {
    final token = newId();
    _grants[token] = actionDigest(account, tool, args);
    return token;
  }

  void consume(String token, String account, String tool, Json args) {
    if (_grants.remove(token) != actionDigest(account, tool, args)) {
      throw const AppFailure('approval', '操作尚未确认或参数已改变');
    }
  }

  void clear() => _grants.clear();
}
