import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:imbroglio/src/core/approval.dart';
import 'package:imbroglio/src/core/models.dart';
import 'package:imbroglio/src/core/normalize.dart';
import 'package:imbroglio/src/services/agent.dart';

void main() {
  test('quoted images are not attachments of the current message', () {
    final raw = {
      'text': '当前消息只有文字',
      'quotedMessage': {'content': '[图片消息](mediaId=quoted-image)'},
      'resourceRefs': [
        {'mediaId': 'quoted-image'},
      ],
      'sender': {
        'avatar': {'mediaId': 'avatar-image'},
      },
    };
    expect(findResourceId(raw), isEmpty);
    expect(
      findResourceId({...raw, 'body': '{"image_key":"own-image"}'}),
      'own-image',
    );
    expect(
      findResourceId({...raw, 'content': '[图片消息](mediaId=own-image)'}),
      'own-image',
    );
    expect(
      findResourceId({
        'content': {'file_key': 'own-file'},
      }),
      'own-file',
    );
  });

  test('structured post keeps title, mentions and body without raw JSON', () {
    final message = normalizeMessage('a', 'c', {
      'message_id': 'm',
      'message_type': 'post',
      'body': {
        'content':
            '{"zh_cn":{"title":"进度","content":[[{"tag":"text","text":"请确认"},{"tag":"at","user_name":"小明"}]]}}',
      },
      'sender': {
        'id': 'u',
        'name': 'Alice',
        'avatar_url': 'https://example.com/a.png',
      },
      'parent_id': 'parent',
    });
    expect(message.text, '进度\n请确认@小明');
    expect(message.extra['replyId'], 'parent');
    expect(message.extra['avatar'], 'https://example.com/a.png');
  });

  test('DingTalk string sender, camel-case ID and createTime are retained', () {
    final m = normalizeMessage('a', 'c', {
      'messageId': 'm',
      'sender': '张三',
      'senderId': 'staff1',
      'senderOpenDingTalkId': 'open1',
      'createTime': 1700000000000,
      'text': '你好',
    });
    expect(m.sender, '张三');
    expect(senderLookupId(m), 'staff1');
    expect(m.timestamp, 1700000000000);
    final cached = Message.fromJson({
      ...m.toJson(),
      'sender': '',
      'extra': {'raw': m.extra['raw']},
    });
    expect(messageSenderName(cached), '张三');
    expect(senderLookupId(cached), 'staff1');
  });

  test('profile avatars accept strings and nested image sizes', () {
    expect(
      normalizeSenderProfile({
        'userId': 'u',
        'avatar': 'https://example.com/a.png',
      })['avatar'],
      'https://example.com/a.png',
    );
    expect(
      normalizeSenderProfile({
        'orgEmployeeModel': {
          'orgUserId': 'u',
          'orgUserName': '李四',
          'avatar': 'https://example.com/b.png',
        },
      }),
      {'id': 'u', 'name': '李四', 'avatar': 'https://example.com/b.png'},
    );
    expect(
      avatarUrl({'avatar_72': 'https://example.com/72.png'}),
      'https://example.com/72.png',
    );
    expect(avatarUrl({'avatar_72': {}}), '');
  });

  test(
    'image markers preserve order and decode media IDs without losing plus signs',
    () {
      const text =
          '前文[图片消息](mediaId=%40first%2Bvalue)中间[图片消息](mediaId=second==)后文';
      final refs = messageImageReferences(text);
      expect(refs.map((r) => r.resourceId), ['@first+value', 'second==']);
      expect(text.substring(0, refs.first.start), '前文');
      expect(text.substring(refs.first.end, refs.last.start), '中间');
      expect(text.substring(refs.last.end), '后文');
      expect(
        findResourceId({'body': '{"text":"[图片消息](mediaId=%40first%2Bvalue)"}'}),
        '@first+value',
      );
      expect(messageImageReferences('[图片消息](mediaId=)'), isEmpty);
      expect(messageImageReferences('[其他链接](mediaId=test)'), isEmpty);
    },
  );

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
