import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:imbroglio/src/core/approval.dart';
import 'package:imbroglio/src/core/models.dart';
import 'package:imbroglio/src/core/normalize.dart';
import 'package:imbroglio/src/services/agent.dart';

void main() {
  test('approval is account-bound, parameter-bound, and single use', () {
    final gate = ApprovalGate();
    final args = {
      'text': '你好',
      'nested': {'b': 2, 'a': 1},
    };
    final token = gate.approve('a', 'send', args);
    expect(
      () => gate.consume(token, 'b', 'send', args),
      throwsA(isA<AppFailure>()),
    );
    final changed = gate.approve('a', 'send', args);
    expect(
      () => gate.consume(changed, 'a', 'send', {'text': 'changed'}),
      throwsA(isA<AppFailure>()),
    );
    final valid = gate.approve('a', 'send', args);
    gate.consume(valid, 'a', 'send', args);
    expect(
      () => gate.consume(valid, 'a', 'send', args),
      throwsA(isA<AppFailure>()),
    );
    expect(
      actionDigest('a', 'send', {'a': 1, 'b': 2}),
      actionDigest('a', 'send', {'b': 2, 'a': 1}),
    );
  });
  test('composite identifiers never mix accounts or delimiter-shaped IDs', () {
    expect(compositeKey('a:b', 'c'), isNot(compositeKey('a', 'b:c')));
    expect(newId(), matches(RegExp(r'^[a-f0-9-]{36}$')));
  });
  test('JSON envelopes fail closed and preserve already-rendered text', () {
    expect(
      unwrap({
        'ok': true,
        'data': {
          'items': [
            {'id': 'one'},
          ],
        },
      }),
      {
        'items': [
          {'id': 'one'},
        ],
      },
    );
    expect(
      () => unwrap({
        'ok': false,
        'error': {'message': 'denied'},
      }),
      throwsA(isA<AppFailure>()),
    );
    expect(
      unwrap({
        'result': [
          {'type': 'text', 'text': '{"items":[{"id":"two"}]}'},
        ],
      }),
      {
        'items': [
          {'id': 'two'},
        ],
      },
    );
    final message = normalizeMessage('a', 'c', {
      'message_id': 'm',
      'content': '普通中文消息',
      'create_time': '1700000000000',
    });
    expect(message.text, '普通中文消息');
    expect(message.timestamp, 1700000000000);
    expect(
      () => normalizeMessage('a', 'c', {'content': 'no id'}),
      throwsA(isA<AppFailure>()),
    );
  });
  test('SSE handles byte splits, CRLF, comments, and multiline data', () async {
    final bytes = utf8.encode(
      ': ping\r\ndata: {"text":\r\ndata: "中文"}\r\n\r\ndata: [DONE]\n\n',
    );
    final result = await sseData(
      Stream.fromIterable(bytes.map((b) => [b])),
    ).toList();
    expect(result, ['{"text":\n"中文"}', '[DONE]']);
  });
  test(
    'model endpoint rejects credentials and external plaintext transport',
    () {
      expect(
        completionUri('https://host.example/v1/').toString(),
        'https://host.example/v1/chat/completions',
      );
      expect(completionUri('http://127.0.0.1:8000/v1').scheme, 'http');
      expect(
        () => completionUri('http://host.example/v1'),
        throwsA(isA<AppFailure>()),
      );
      expect(
        () => completionUri('https://secret@host.example'),
        throwsA(isA<AppFailure>()),
      );
    },
  );
  test('unknown plugin protocols and traversal identifiers are rejected', () {
    expect(
      () => PluginManifest({
        'id': '../bad',
        'name': 'x',
        'version': '1',
        'kind': 'agent',
        'protocol': 1,
      }),
      throwsFormatException,
    );
    expect(
      () => PluginManifest({
        'id': 'test.agent',
        'name': 'x',
        'version': '1',
        'kind': 'agent',
        'protocol': 2,
      }),
      throwsFormatException,
    );
  });
}
