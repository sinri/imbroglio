import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:imbroglio/src/core/models.dart';
import 'package:imbroglio/src/core/normalize.dart';
import 'package:imbroglio/src/core/message_presentation.dart';

void main() {
  Message message(Map<String, dynamic> raw) =>
      normalizeMessage('a', 'c', {'id': 'm', ...raw});

  test('recognizes explicit and nested markdown including old text cache', () {
    for (final key in ['message_type', 'msgType', 'msgtype', 'messageType']) {
      final m = message({
        key: 'markdown',
        'content': {'text': '正文'},
      });
      expect(messagePresentation(m).markdown, isTrue);
      expect(messagePresentation(m).text, '正文');
    }
    final m = message({
      'content': jsonEncode({
        'markdown': {'title': '通知', 'text': '**完成**'},
      }),
    });
    expect(messagePresentation(m).text, '通知\n**完成**');
    expect(messagePresentation(m).markdown, isTrue);
    final cached = Message.fromJson({...m.toJson(), 'kind': 'text'});
    expect(messagePresentation(cached).markdown, isTrue);
  });

  test(
    'conservative inference accepts strong syntax, preserves everyday text',
    () {
      for (final text in [
        '# 标题',
        '**完成**',
        '```dart\nprint(1);\n```',
        '- 一\n- 二',
        '[链接](https://example.com)',
        '| a | b |\n| --- | --- |',
      ]) {
        expect(
          messagePresentation(message({'text': text})).markdown,
          isTrue,
          reason: text,
        );
      }
      for (final text in [
        '普通消息',
        'user_name',
        '2 * 3 = 6',
        '- 一件事',
        'https://example.com',
        '订单 #123',
        '[图片消息](mediaId=abc)',
      ]) {
        expect(
          messagePresentation(message({'text': text})).markdown,
          isFalse,
          reason: text,
        );
      }
      expect(
        messagePresentation(
          message({'type': 'file', 'text': '**file**'}),
        ).markdown,
        isFalse,
      );
    },
  );

  test(
    'structured post retains styles, paragraphs, link, mention and image',
    () {
      final m = message({
        'body': {
          'content': jsonEncode({
            'zh_cn': {
              'title': '进度',
              'content': [
                [
                  {
                    'tag': 'text',
                    'text': '完成',
                    'style': ['bold'],
                  },
                  {'tag': 'at', 'user_name': '小明'},
                ],
                [
                  {
                    'tag': 'a',
                    'text': '详情',
                    'href': 'https://example.com/a(b)',
                  },
                ],
                [
                  {'tag': 'text', 'text': '**这是原文**'},
                ],
                [
                  {'tag': 'img', 'image_key': 'a+b=='},
                ],
              ],
            },
          }),
        },
      });
      final p = messagePresentation(m);
      expect(p.markdown, isTrue);
      expect(p.text, contains('**进度**\n\n**完成**@小明'));
      expect(p.text, contains('[详情](https://example.com/a%28b%29)'));
      expect(p.text, contains(r'\*\*这是原文\*\*'));
      expect(messageImageReferences(p.text).single.resourceId, 'a+b==');
      expect(m.text, contains('完成@小明'));
    },
  );

  test('DingTalk richText keeps text and embedded media in sequence', () {
    final p = messagePresentation(
      message({
        'content': {
          'richText': [
            {'text': '前文'},
            {'mediaId': 'abc'},
            {'text': '后文'},
          ],
        },
      }),
    );
    expect(p.markdown, isTrue);
    expect(p.text, '前文\n\n[图片消息](mediaId=abc)\n\n后文');
  });

  test('malformed and deeply nested bodies fall back without throwing', () {
    expect(
      messagePresentation(message({'content': '{invalid'})).text,
      '{invalid',
    );
    Object value = {'tag': 'text', 'text': 'deep'};
    for (var i = 0; i < 20; i++) {
      value = {'body': value};
    }
    expect(
      () => messagePresentation(message({'content': value})),
      returnsNormally,
    );
  });
}
