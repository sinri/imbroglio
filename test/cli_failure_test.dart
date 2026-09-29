import 'package:flutter_test/flutter_test.dart';
import 'package:imbroglio/src/core/cli_failure.dart';

void main() {
  test(
    'extracts pretty JSON after progress, preserves hint and redacts secrets',
    () {
      final error = cliFailure(3, '''
等待浏览器授权……
\x1b[31m{
  "ok": false,
  "error": {
    "type": "authentication",
    "message": "failed to get user info: token=private-token",
    "hint": "retry https://example.com/?secret=private-secret"
  }
}\x1b[0m
''', '');
      expect(error.code, 'authentication');
      expect(error.message, contains('failed to get user info'));
      expect(error.message, contains('处理建议：retry'));
      expect(error.message, isNot(contains('private-token')));
      expect(error.message, isNot(contains('private-secret')));
    },
  );

  test('stdout error works when stderr only contains progress', () {
    final error = cliFailure(
      3,
      'Waiting for authorization',
      '{"ok":false,"error":{"type":"authentication","message":"denied"}}',
    );
    expect(error.message, contains('denied'));
    expect(error.code, 'authentication');
  });

  test('prefers stderr error and retains rate limit retry metadata', () {
    final error = cliFailure(
      4,
      'progress\n{"error":{"subtype":"rate_limit","message":"busy","retry_after":12}}',
      '{"message":"unrelated"}',
    );
    expect(error.code, 'rate_limit');
    expect(error.retryAfter, 12);
    expect(error.message, contains('busy'));
  });

  test('quoted braces and escaped quotes do not truncate the error', () {
    final error = cliFailure(
      3,
      r'progress {text} {"error":{"message":"denied {user} \"quoted\""}}',
      '',
    );
    expect(error.message, contains('denied {user}'));
  });

  test(
    'unstructured failure stays a failure without exposing stdout payload',
    () {
      final error = cliFailure(
        3,
        'unstructured failure',
        '{"data":"private payload"}',
      );
      expect(error.message, contains('CLI 诊断记录'));
      expect(error.message, isNot(contains('private payload')));
      expect(cliFailure(10, '', '').code, 'confirmation');
    },
  );
}
