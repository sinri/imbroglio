import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imbroglio/src/services/activity.dart';
import 'package:imbroglio/src/services/workspace.dart';
import 'package:imbroglio/src/ui/activity.dart';
import 'package:imbroglio/src/ui/app.dart';

void main() {
  test(
    'parallel activities finish independently and repeated polls coalesce',
    () async {
      final log = ActivityLog(() {});
      final blocked = Completer<void>();
      final running = log.run('one', '拉取新消息', '账号 · 会话', (_) => blocked.future);
      await log.run('two', '刷新会话列表', '账号', (_) async {});
      expect(log.runningCount, 1);
      blocked.complete();
      await running;
      expect(log.runningCount, 0);
      await log.run('one', '拉取新消息', '账号 · 会话', (_) async {});
      expect(log.items.where((e) => e.key == 'one').length, 1);
      for (var i = 0; i < 60; i++) {
        await log.run('task$i', '任务', '账号', (_) async {});
      }
      expect(log.items.length, 40);
    },
  );

  test('exceptions finish activities rather than leaving a spinner', () async {
    final log = ActivityLog(() {});
    await expectLater(
      log.run('one', '拉取新消息', '账号', (_) async {
        throw StateError('offline');
      }),
      throwsStateError,
    );
    expect(log.runningCount, 0);
    expect(log.attentionCount, 1);
    expect(log.items.single.detail, contains('offline'));
  });

  testWidgets('status bar opens live details with progress and retry time', (
    tester,
  ) async {
    final w = Workspace();
    final task = w.activities.begin('sync', '拉取新消息', '工作账号 · 测试群');
    task.progress('已拉取 2 页 · 80 条消息');
    await tester.binding.setSurfaceSize(const Size(1000, 740));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [workspaceProvider.overrideWith((ref) => w)],
        child: const MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: BackgroundActivityBar(),
            ),
          ),
        ),
      ),
    );
    expect(find.text('1 项进行中'), findsOneWidget);
    await tester.tap(find.text('后台活动'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('已拉取 2 页 · 80 条消息'), findsOneWidget);
    task.finish(
      state: 'failed',
      detail: '平台限流',
      retryAt: DateTime.now().add(const Duration(seconds: 60)),
    );
    await tester.pump();
    expect(find.textContaining('平台限流'), findsOneWidget);
    expect(find.textContaining('后重试'), findsOneWidget);
    expect(find.text('0 项进行中 · 1 项需留意'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('1 项后台活动需要留意'), findsOneWidget);
  });
}
