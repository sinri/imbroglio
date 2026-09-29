import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
// The standalone adapter resolves shared models with file URIs.
// ignore: avoid_relative_lib_imports
import '../lib/src/core/models.dart';
// ignore: avoid_relative_lib_imports
import '../lib/src/core/normalize.dart';
import '../bin/im_adapter.dart' as adapter;

class RecordingAdapter extends adapter.Adapter {
  List<String> command = [];
  Object? response = {'items': []};
  String? stdinText;
  List<Object?>? responses;
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
    return responses?.removeAt(0) ?? response;
  }
}

void main() {
  test(
    'DingTalk self identity matches exact user ID despite duplicate names',
    () async {
      final a = RecordingAdapter('dingtalk')
        ..responses = [
          [
            {
              'orgEmployeeModel': {
                'userId': 'employee',
                'orgUserName': 'Same Name',
              },
            },
          ],
          [
            {'userId': 'other', 'name': 'Same Name', 'openDingTalkId': 'wrong'},
            {
              'userId': 'employee',
              'name': 'Same Name',
              'openDingTalkId': 'own-open',
            },
          ],
        ];
      final result = object(await a.handle(1, 'identity.self', {}));
      expect(result, {
        'userId': 'employee',
        'ids': ['employee', 'own-open'],
      });
      expect(a.command, containsAllInOrder(['--profile', 'exact-profile']));
    },
  );
  test(
    'DingTalk self identity never accepts a matching name with a different user ID',
    () async {
      final a = RecordingAdapter('dingtalk')
        ..responses = [
          [
            {
              'orgEmployeeModel': {
                'userId': 'employee',
                'orgUserName': 'Same Name',
              },
            },
          ],
          [
            {'userId': 'other', 'name': 'Same Name', 'openDingTalkId': 'wrong'},
          ],
        ];
      await expectLater(
        a.handle(1, 'identity.self', {}),
        throwsA(isA<AppFailure>()),
      );
    },
  );

  test(
    'notification settings preserve explicit muted and unmuted states',
    () async {
      final ding = RecordingAdapter('dingtalk')
        ..response = {
          'conversations': [
            {'openConversationId': 'muted', 'notificationOff': 1},
            {'openConversationId': 'normal', 'notificationOff': 0},
            {'openConversationId': 'unknown'},
          ],
          'hasMore': false,
        };
      final snapshot = object(
        await ding.handle(1, 'notifications.settings', {
          'ids': ['muted'],
        }),
      );
      expect(snapshot['items'], [
        {'id': 'muted', 'muted': true},
        {'id': 'normal', 'muted': false},
      ]);
      expect(ding.command, isNot(contains('--exclude-muted')));
      final feishu = RecordingAdapter('feishu')
        ..response = {
          'items': [
            {'chat_id': 'muted', 'is_muted': true},
            {'chat_id': 'normal', 'is_muted': false},
            {'chat_id': 'unknown'},
          ],
        };
      final batch = object(
        await feishu.handle(1, 'notifications.settings', {
          'ids': ['muted', 'normal', 'unknown'],
        }),
      );
      expect(batch['items'], snapshot['items']);
      expect(
        feishu.command,
        containsAllInOrder(['chat.user_setting', 'batch_query']),
      );
      expect(feishu.command, containsAllInOrder(['--as', 'user']));
    },
  );

  test('incomplete DingTalk notification snapshot is not accepted', () async {
    final ding = RecordingAdapter('dingtalk')
      ..response = {'conversations': [], 'hasMore': true};
    await expectLater(
      ding.handle(1, 'notifications.settings', {
        'ids': ['chat'],
      }),
      throwsA(isA<AppFailure>()),
    );
  });

  test(
    'DingTalk active continuation uses endpoint exhaustion metadata',
    () async {
      final a = RecordingAdapter('dingtalk')
        ..response = jsonEncode({
          'ok': true,
          'data': {
            'complete': false,
            'conversations': [
              {
                'conversationId': 'chat',
                'type': 'direct',
                'name': 'Peer',
                'latestMessageTime': '2026-09-29T01:00:00Z',
              },
            ],
          },
          'meta': {
            'pagination': {'endpoint_exhausted': true},
          },
        });
      final result = object(
        await a.handle(1, 'conversations.active', {
          'start': 1790640000000,
          'end': 1790647200000,
          'cursor': 'next',
        }),
      );
      expect(result['complete'], true);
      expect(object((result['items'] as List).single)['kind'], 'p2p');
      expect(
        a.command,
        containsAllInOrder(['+recent-conversations', '--start']),
      );
      expect(a.command, containsAllInOrder(['--cursor', 'next']));
      expect(a.command, containsAllInOrder(['--profile', 'exact-profile']));
    },
  );

  test(
    'Feishu active search aggregates messages by chat and carries pagination',
    () async {
      final a = RecordingAdapter('feishu')
        ..response = jsonEncode({
          'data': {
            'has_more': true,
            'page_token': 'next',
            'messages': [
              {
                'chat_id': 'chat',
                'chat_name': 'Chat',
                'chat_type': 'group',
                'create_time': '1790640000000',
              },
              {
                'chat_id': 'chat',
                'chat_name': 'Chat',
                'chat_type': 'group',
                'create_time': '1790640010000',
              },
            ],
          },
        });
      final result = object(
        await a.handle(1, 'conversations.active', {
          'start': 1790640000000,
          'end': 1790647200000,
        }),
      );
      expect(result['complete'], false);
      expect(result['cursor'], 'next');
      expect(
        object((result['items'] as List).single)['updatedAt'],
        1790640010000,
      );
      expect(a.command, containsAllInOrder(['+messages-search', '--start']));
      expect(a.command, containsAllInOrder(['--as', 'user']));
    },
  );

  for (final platform in ['feishu', 'dingtalk']) {
    test(
      '$platform activity time parameters use whole-second ISO format',
      () async {
        final a = RecordingAdapter(platform)
          ..response = jsonEncode({
            'data': {
              'complete': true,
              'has_more': false,
              'messages': [],
              'conversations': [],
            },
          });
        final start = DateTime.utc(
          2026,
          9,
          29,
          7,
          27,
          24,
          123,
        ).millisecondsSinceEpoch;
        final end = DateTime.utc(2026, 9, 29, 8, 29, 24).millisecondsSinceEpoch;
        await a.handle(1, 'conversations.active', {'start': start, 'end': end});
        expect(
          a.command[a.command.indexOf('--start') + 1],
          '2026-09-29T07:27:24Z',
        );
        expect(
          a.command[a.command.indexOf('--end') + 1],
          '2026-09-29T08:29:24Z',
        );
      },
    );
  }

  test('Feishu sender lookup preserves localized names and avatars', () async {
    final a = RecordingAdapter('feishu')
      ..response = {
        'users': [
          {
            'open_id': 'ou_sender',
            'localized_name': 'Sender',
            'avatar': {'avatar_72': 'https://example.com/avatar.png'},
          },
        ],
      };
    final result = object(
      await a.handle(1, 'contacts.resolve', {
        'ids': ['ou_sender'],
      }),
    );
    expect(
      a.command,
      containsAllInOrder([
        'contact',
        '+search-user',
        '--user-ids',
        'ou_sender',
      ]),
    );
    expect(a.command, containsAllInOrder(['--as', 'user']));
    expect((result['items'] as List).single, {
      'id': 'ou_sender',
      'name': 'Sender',
      'avatar': 'https://example.com/avatar.png',
    });
  });
  test('Feishu chat-list decodes chats and preserves pagination', () async {
    final a = RecordingAdapter('feishu');
    // Adapter.run unwraps the real CLI envelope before dispatching the result.
    a.response = unwrap({
      'ok': true,
      'identity': 'user',
      'data': {
        'chats': [
          {
            'chat_id': 'old-chat',
            'name': 'Existing chat',
            'chat_mode': 'group',
          },
        ],
        'has_more': true,
        'page_token': 'next-page',
      },
      'meta': {
        'pagination': {'complete': false, 'pages': 1, 'items': 1},
      },
    });
    final first = object(await a.handle(1, 'conversations', {}));
    expect((first['items'] as List).single, containsPair('id', 'old-chat'));
    expect(
      (first['items'] as List).single,
      containsPair('accountId', 'account'),
    );
    expect(first['cursor'], 'next-page');
    expect(a.command, containsAllInOrder(['--types', 'p2p,group']));
    expect(a.command, containsAllInOrder(['--as', 'user']));

    a.response = {'chats': [], 'has_more': false, 'page_token': ''};
    final last = object(
      await a.handle(2, 'conversations', {'cursor': first['cursor']}),
    );
    expect(a.command, containsAllInOrder(['--page-token', 'next-page']));
    expect(last['items'], isEmpty);
    expect(last['cursor'], isEmpty);
  });

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
