import 'package:flutter_test/flutter_test.dart';
// The standalone adapter resolves shared models with file URIs.
// ignore: avoid_relative_lib_imports
import '../lib/src/core/models.dart';
import '../bin/im_adapter.dart' as adapter;

class RecordingAdapter extends adapter.Adapter {
  List<String> command = [];
  Object? response = {'items': []};
  String? stdinText;
  RecordingAdapter(String source) {
    platform = source;
    binary = '/managed/cli';
    directory = '/managed/account';
    accountId = 'account';
    profile = 'exact-profile';
    initialized = true;
  }
  @override
  Future<dynamic> run(
    Object id,
    List<String> args, {
    String? input,
    bool raw = false,
    Duration timeout = const Duration(seconds: 40),
    bool auth = false,
  }) async {
    command = args;
    stdinText = input;
    return response;
  }
}

void main() {
  test(
    'Feishu initial history bounds the start without changing descending order',
    () async {
      final a = RecordingAdapter('feishu');
      await a.handle(1, 'messages', {
        'conversation': {'id': 'c'},
        'notBefore': 1700000000000,
      });
      expect(
        a.command,
        containsAllInOrder([
          '--order',
          'desc',
          '--start',
          DateTime.fromMillisecondsSinceEpoch(
            1700000000000,
          ).toUtc().toIso8601String(),
        ]),
      );
      await a.handle(2, 'messages', {
        'conversation': {'id': 'c'},
        'before': 1700000000000,
      });
      expect(a.command, isNot(contains('--start')));
      expect(a.command, contains('--end'));
    },
  );
  test(
    'DingTalk group sender uses open ID and maps profile back to message ID',
    () async {
      final a = RecordingAdapter('dingtalk');
      a.response = {
        'members': [
          {
            'openDingTalkId': 'open1',
            'nick': '张三',
            'avatar': 'https://example.com/avatar.png',
          },
        ],
      };
      final result = object(
        await a.handle(1, 'contacts.resolve', {
          'ids': ['staff1'],
          'openIds': {'staff1': 'open1'},
          'conversation': {'id': 'chat1', 'kind': 'group'},
        }),
      );
      expect(
        a.command,
        containsAllInOrder([
          'chat',
          'group',
          'members',
          'list-by-ids',
          '--id',
          'chat1',
          '--users',
          'open1',
        ]),
      );
      expect(result['items'], [
        {
          'id': 'staff1',
          'name': '张三',
          'avatar': 'https://example.com/avatar.png',
        },
      ]);
    },
  );

  test('directory result preserves a string avatar', () async {
    final a = RecordingAdapter('dingtalk');
    a.response = [
      {
        'orgEmployeeModel': {'orgUserId': 'staff1', 'orgUserName': '李四'},
        'avatar': 'https://example.com/avatar.png',
      },
    ];
    final result = object(
      await a.handle(1, 'contacts.resolve', {
        'ids': ['staff1'],
      }),
    );
    expect(
      (result['items'] as List).single['avatar'],
      'https://example.com/avatar.png',
    );
    expect(
      a.command,
      containsAllInOrder(['contact', 'user', 'get', '--ids', 'staff1']),
    );
  });

  test('actual DingTalk member shape preserves avatar media ID', () async {
    final a = RecordingAdapter('dingtalk');
    a.response = {
      'members': [
        {
          'openDingtalkId': 'open1',
          'groupNick': '',
          'nick': '张三',
          'avatarMediaId': '@media',
        },
      ],
    };
    final result = object(
      await a.handle(1, 'contacts.resolve', {
        'ids': ['staff1'],
        'openIds': {'staff1': 'open1'},
        'conversation': {'id': 'chat1', 'kind': 'group'},
      }),
    );
    expect((result['items'] as List).single, {
      'id': 'staff1',
      'name': '张三',
      'avatar': '',
      'avatarResourceId': '@media',
    });
    expect(a.command, contains('list-by-ids'));
  });

  test('Feishu uses explicit user identity and exact profile', () async {
    final a = RecordingAdapter('feishu');
    await a.handle(1, 'conversations', {});
    expect(
      a.command,
      containsAllInOrder([
        '--types',
        'p2p,group',
        '--profile',
        'exact-profile',
        '--as',
        'user',
      ]),
    );
  });
  test(
    'DingTalk sends user text as an argument with stable idempotency',
    () async {
      final a = RecordingAdapter('dingtalk');
      a.response = {'messageId': 'remote-id'};
      const text =
          'line one\n'
          r'$(touch /tmp/nope) `whoami`';
      await a.handle(1, 'send', {
        'conversation': {'id': 'c', 'kind': 'group'},
        'text': text,
        'idempotencyKey': 'fixed-key',
        'approved': true,
      });
      expect(
        a.command,
        containsAllInOrder([
          '--group',
          'c',
          '--text',
          text,
          '--uuid',
          'fixed-key',
        ]),
      );
      expect(a.command, containsAllInOrder(['--profile', 'exact-profile']));
    },
  );
  test(
    'write without host authorization is rejected before CLI invocation',
    () async {
      final a = RecordingAdapter('feishu');
      await expectLater(
        a.handle(1, 'send', {'text': 'x'}),
        throwsA(isA<AppFailure>()),
      );
      expect(a.command, isEmpty);
    },
  );
  test('document content is sent over stdin, not parsed by a shell', () async {
    final a = RecordingAdapter('feishu');
    await a.handle(1, 'tool.execute', {
      'tool': 'document.create',
      'arguments': {'title': 'Title', 'content': '# 文档\n正文'},
      'approved': true,
    });
    expect(a.stdinText, '# 文档\n正文');
    expect(a.command, containsAllInOrder(['--content', '-']));
  });
  test('Feishu event listener cannot impersonate personal events', () async {
    final a = RecordingAdapter('feishu');
    await expectLater(a.handle(1, 'subscribe', {}), throwsA(isA<AppFailure>()));
  });
  test(
    'DingTalk p2p without resolved peer fails instead of sending to a group',
    () async {
      final a = RecordingAdapter('dingtalk');
      await expectLater(
        a.handle(1, 'send', {
          'conversation': {'id': 'c', 'kind': 'p2p'},
          'text': 'x',
          'approved': true,
          'idempotencyKey': 'id',
        }),
        throwsA(isA<AppFailure>()),
      );
      expect(a.command, isEmpty);
    },
  );
}
