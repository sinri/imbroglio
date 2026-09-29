import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imbroglio/src/core/diagnostics.dart';
import 'package:imbroglio/src/core/models.dart';
import 'package:imbroglio/src/services/store.dart';
import 'package:imbroglio/src/services/workspace.dart';
import 'package:imbroglio/src/ui/activity.dart';
import 'package:imbroglio/src/ui/app.dart';
import '../bin/im_adapter.dart' as adapter;
// Adapter uses file URIs for its standalone pure Dart build.
// ignore: avoid_relative_lib_imports
import '../lib/src/core/models.dart' as wire;
import 'sync_test.dart' show FakeRpc;

class DiagnosticAdapter extends adapter.Adapter {
  final captured = <Map<String, dynamic>>[];
  final received = Completer<void>();
  @override
  void diagnostic(
    String operation,
    String message, {
    int? exitCode,
    String conversationId = '',
  }) {
    captured.add({
      'operation': operation,
      'detail': diagnosticText(message),
      'exitCode': exitCode,
    });
    if (!received.isCompleted) received.complete();
  }
}

void main() {
  for (final completed in [true, false]) {
    test(
      'exit 3 ${completed ? 'accepts explicit completed login with missing scopes' : 'rejects actual authorization failure'}',
      () async {
        final dir = await Directory.systemTemp.createTemp(
          'imbroglio-partial-login-',
        );
        try {
          final payload = completed
              ? {
                  'event': 'authorization_complete',
                  'user_open_id': 'test-user',
                  'granted': ['im:chat:read'],
                  'missing': ['vc:meeting.realtime:read'],
                  'warning': {'type': 'missing_scope'},
                }
              : {
                  'event': 'authorization_failed',
                  'error': 'user denied request',
                };
          final script = File('${dir.path}/cli');
          await script.writeAsString(
            "#!/bin/sh\ncat <<'RESULT'\n${jsonEncode(payload)}\nRESULT\nexit 3\n",
          );
          await Process.run('chmod', ['+x', script.path]);
          final cli = DiagnosticAdapter()
            ..binary = script.path
            ..directory = dir.path
            ..platform = 'feishu'
            ..accountId = 'a'
            ..initialized = true;
          if (completed) {
            final result = await cli.handle(1, 'auth.login', {});
            expect(result['completed'], true);
            expect(result['missingScopes'], ['vc:meeting.realtime:read']);
            expect(result['warning'], contains('权限未授予'));
            expect(cli.captured, isEmpty);
          } else {
            await expectLater(
              cli.handle(1, 'auth.login', {}),
              throwsA(
                isA<wire.AppFailure>().having(
                  (e) => e.message,
                  'message',
                  contains('user denied request'),
                ),
              ),
            );
          }
        } finally {
          await dir.delete(recursive: true);
        }
      },
    );
  }
  const a = AccountRef(id: 'a', platform: 'dingtalk', label: '测试账号');
  const c = Conversation(accountId: 'a', id: 'c', title: '测试群', watched: true);
  late Workspace w;
  setUp(() async {
    w = Workspace()
      ..store = Store(NativeDatabase.memory())
      ..accounts = [a]
      ..conversations = [c];
    await w.store.init();
  });
  tearDown(() => w.close());

  test('diagnostics strip payloads, credentials and URLs and cap length', () {
    final detail = diagnosticText(
      '{"msg":"failed","request":{"token":"private","body":"private message"},"error":{"message":"SYSTEM_ERROR"},"trace_id":"trace123"}\nAuthorization: Bearer abcdef\naccess_token=secret-value https://example.com/?token=secret',
    );
    expect(detail, contains('SYSTEM_ERROR'));
    expect(detail, contains('trace123'));
    for (final secret in ['private', 'abcdef', 'secret-value', 'example.com']) {
      expect(detail, isNot(contains(secret)));
    }
    expect(diagnosticText('x' * 10000).length, lessThanOrEqualTo(4097));
  });
  test(
    'authorization cancellation terminates the CLI without an error diagnostic',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'imbroglio-auth-cancel-',
      );
      try {
        final script = File('${dir.path}/cli');
        await script.writeAsString('#!/bin/sh\nexec sleep 60\n');
        await Process.run('chmod', ['+x', script.path]);
        final cli = DiagnosticAdapter()
          ..binary = script.path
          ..directory = dir.path
          ..platform = 'feishu'
          ..accountId = 'a'
          ..initialized = true;
        final attempt = cli.handle(1, 'auth.login', {});
        final assertion = expectLater(
          attempt,
          throwsA(
            isA<wire.AppFailure>().having((e) => e.code, 'code', 'cancelled'),
          ),
        );
        // Also covers cancellation while Process.start has not returned yet.
        cli.cancel(1);
        await assertion.timeout(const Duration(seconds: 5));
        expect(cli.processes, isEmpty);
        expect(cli.captured, isEmpty);
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'adapter surfaces a mixed-output authorization failure from a process',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'imbroglio-auth-error-',
      );
      try {
        final script = File('${dir.path}/cli');
        await script.writeAsString('''#!/bin/sh
cat >&2 <<'ERROR'
等待浏览器授权……
{
  "ok": false,
  "error": {
    "type": "authentication",
    "message": "failed to get user info",
    "hint": "check permissions"
  }
}
ERROR
exit 3
''');
        await Process.run('chmod', ['+x', script.path]);
        final cli = DiagnosticAdapter()
          ..binary = script.path
          ..directory = dir.path
          ..platform = 'feishu'
          ..accountId = 'a'
          ..initialized = true;
        await expectLater(
          cli.handle(1, 'auth.login', {}),
          throwsA(
            isA<wire.AppFailure>()
                .having((e) => e.code, 'code', 'authentication')
                .having(
                  (e) => e.message,
                  'message',
                  contains('failed to get user info'),
                )
                .having(
                  (e) => e.message,
                  'hint',
                  contains('check permissions'),
                ),
          ),
        );
        expect(cli.captured.single['exitCode'], 3);
        expect(cli.processes, isEmpty);
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'confidential rejection disables live and history requests across restart',
    () async {
      var fetches = 0;
      w.clients['a'] = FakeRpc((method, args) {
        if (method == 'messages') {
          fetches++;
          throw const AppFailure('upstream', '该群为保密群，无法获取消息记录');
        }
        return {};
      });
      await w.syncConversation(c);
      await w.syncConversation(c);
      await w.syncConversation(c, older: true);
      expect(fetches, 1);
      expect(w.backgroundPending, 0);
      expect(w.sync[c.key]!.error, contains('已停止拉取'));
      w.blockedConversations.clear();
      await w.loadSyncPolicies();
      await w.syncConversation(c);
      expect(fetches, 1);
      expect(w.diagnostics.single['detail'], contains('保密群'));
    },
  );

  test(
    'subscription failure backs off while message polling continues',
    () async {
      var subscriptions = 0, fetches = 0;
      w.clients['a'] = FakeRpc((method, args) {
        if (method == 'subscribe') {
          subscriptions++;
          throw const AppFailure(
            'upstream',
            'SYSTEM_ERROR registerToEventCenter failed',
          );
        }
        if (method == 'messages') {
          fetches++;
          return {'items': [], 'hasMore': false};
        }
        return {};
      });
      await w.syncConversation(c);
      await w.syncConversation(c);
      expect(subscriptions, 1);
      expect(fetches, 2);
      final retry = await w.store.get('subscriptionRetry', c.key);
      expect(retry!['failures'], 1);
      expect(
        retry['retryAt'],
        greaterThan(DateTime.now().millisecondsSinceEpoch),
      );
      await w.loadSyncPolicies();
      await w.syncConversation(c);
      expect(subscriptions, 1);
    },
  );

  test('persistent diagnostics retain only the latest 200 records', () async {
    for (var i = 0; i < 202; i++) {
      await w.recordDiagnostic(a, {
        'operation': 'event consume',
        'detail': 'failure $i',
      });
    }
    expect((await w.store.list('diagnostics')).length, 200);
    w.diagnostics.clear();
    await w.loadSyncPolicies();
    expect(w.diagnostics.length, 200);
    expect(w.diagnostics.first['detail'], 'failure 201');
  });

  test('CLI nonzero exit retains final stderr and exit code', () async {
    final cli = DiagnosticAdapter()
      ..binary = '/bin/sh'
      ..directory = Directory.current.path
      ..platform = 'dingtalk'
      ..accountId = 'a';
    await expectLater(
      cli.run(1, ['-c', 'printf "SYSTEM_ERROR final failure\\n" >&2; exit 7']),
      throwsA(isA<wire.AppFailure>()),
    );
    expect(cli.captured.single['exitCode'], 7);
    expect(cli.captured.single['detail'], contains('final failure'));
  });

  test(
    'subscription captures the last stderr line before reporting exit',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'imbroglio-subscription-',
      );
      try {
        final script = File('${dir.path}/cli');
        await script.writeAsString(
          '#!/bin/sh\nprintf "SYSTEM_ERROR registerToEventCenter failed\\n" >&2\nexit 9\n',
        );
        await Process.run('chmod', ['+x', script.path]);
        final cli = DiagnosticAdapter()
          ..binary = script.path
          ..directory = dir.path
          ..platform = 'dingtalk'
          ..accountId = 'a'
          ..initialized = true;
        await cli.handle(1, 'subscribe', {'conversation': c.toJson()});
        await cli.received.future.timeout(const Duration(seconds: 5));
        expect(cli.captured.single['exitCode'], 9);
        expect(
          cli.captured.single['detail'],
          contains('registerToEventCenter failed'),
        );
        expect(cli.streams, isEmpty);
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );

  test(
    'intentional unsubscribe does not create an unexpected exit record',
    () async {
      final dir = await Directory.systemTemp.createTemp(
        'imbroglio-unsubscribe-',
      );
      try {
        final script = File('${dir.path}/cli');
        await script.writeAsString(
          '#!/bin/sh\ncat >/dev/null\nprintf "closed\\n" >&2\n',
        );
        await Process.run('chmod', ['+x', script.path]);
        final cli = DiagnosticAdapter()
          ..binary = script.path
          ..directory = dir.path
          ..platform = 'dingtalk'
          ..accountId = 'a'
          ..initialized = true;
        await cli.handle(1, 'subscribe', {'conversation': c.toJson()});
        final child = cli.streams[c.id]!;
        await cli.handle(2, 'unsubscribe', {'conversationId': c.id});
        await child.exitCode.timeout(const Duration(seconds: 5));
        await Future<void>.delayed(const Duration(milliseconds: 50));
        expect(cli.captured, isEmpty);
      } finally {
        await dir.delete(recursive: true);
      }
    },
  );

  testWidgets('diagnostic records are visible from the persistent footer', (
    tester,
  ) async {
    w.diagnostics.add({
      'accountId': 'a',
      'account': '测试账号',
      'conversationId': 'c',
      'timestamp': 1700000000000,
      'operation': 'event consume',
      'exitCode': 7,
      'detail': 'SYSTEM_ERROR registerToEventCenter failed',
    });
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [workspaceProvider.overrideWith((ref) => w)],
        child: const MaterialApp(home: Scaffold(body: BackgroundActivityBar())),
      ),
    );
    await tester.tap(find.byTooltip('CLI 诊断记录'));
    await tester.pumpAndSettle();
    expect(find.textContaining('registerToEventCenter failed'), findsOneWidget);
    expect(find.textContaining('退出码 7'), findsOneWidget);
    expect(find.byTooltip('复制诊断记录'), findsOneWidget);
    expect(find.byType(SelectionArea), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
