import 'dart:async';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imbroglio/src/core/models.dart';
import 'package:imbroglio/src/services/store.dart';
import 'package:imbroglio/src/services/workspace.dart';
import 'package:imbroglio/src/ui/app.dart';
import 'package:imbroglio/src/ui/settings.dart';
import 'sync_test.dart' show FakeRpc;

void main() {
  for (final fail in [false, true]) {
    testWidgets(
      'logout has visible progress and ${fail ? 'failure' : 'success'} feedback',
      (tester) async {
        await tester.binding.setSurfaceSize(const Size(1200, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final completion = Completer<Json>();
        final rpc = FakeRpc(
          (method, _) => method == 'auth.logout' ? completion.future : {},
        );
        final w = Workspace()
          ..root = '/test/workspace'
          ..store = Store(NativeDatabase.memory())
          ..accounts = [
            const AccountRef(
              id: 'a',
              platform: 'feishu',
              label: '测试飞书',
              enabled: false,
            ),
          ]
          ..clients['a'] = rpc;
        await w.store.init();
        addTearDown(w.close);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [workspaceProvider.overrideWith((ref) => w)],
            child: const MaterialApp(home: Scaffold(body: SettingsPage())),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byTooltip('退出账号'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('确认'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 400));
        expect(find.byTooltip('正在退出账号'), findsOneWidget);
        expect(
          tester
              .widget<IconButton>(
                find.byWidgetPredicate(
                  (widget) =>
                      widget is IconButton && widget.tooltip == '正在退出账号',
                ),
              )
              .onPressed,
          isNull,
        );
        if (fail) {
          completion.completeError(const AppFailure('test', '注销失败，请重试'));
        } else {
          completion.complete({});
        }
        await tester.pumpAndSettle();
        expect(find.text(fail ? '注销失败，请重试' : '已退出 测试飞书'), findsOneWidget);
        expect(find.byTooltip('正在退出账号'), findsNothing);
        expect(rpc.closed, true);
        expect(w.clients, isEmpty);
        expect(w.account('a').signedOut, !fail);
        expect(
          AccountRef.fromJson((await w.store.get('accounts', 'a'))!).signedOut,
          !fail,
        );
        if (!fail) {
          expect(find.text('测试飞书'), findsNothing);
          expect(find.text('尚未连接账号'), findsNWidgets(2));
          expect(find.text('恢复'), findsNothing);
          expect(find.text('授权'), findsNothing);
        } else {
          expect(find.text('测试飞书'), findsOneWidget);
          expect(find.byTooltip('退出账号'), findsOneWidget);
          expect(find.text('恢复'), findsOneWidget);
          expect(find.text('授权'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('saved signed-out accounts stay hidden beside paused accounts', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final w = Workspace()
      ..root = '/test/workspace'
      ..store = Store(NativeDatabase.memory());
    await w.store.init();
    addTearDown(w.close);
    for (final account in [
      const AccountRef(
        id: 'signed-out',
        platform: 'feishu',
        label: '已退出的飞书',
        enabled: false,
        signedOut: true,
      ),
      const AccountRef(
        id: 'paused',
        platform: 'dingtalk',
        label: '暂停的钉钉',
        enabled: false,
      ),
    ]) {
      await w.store.put('accounts', account.id, account.toJson());
    }
    w.accounts = (await w.store.list(
      'accounts',
    )).map(AccountRef.fromJson).toList();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [workspaceProvider.overrideWith((ref) => w)],
        child: const MaterialApp(home: Scaffold(body: SettingsPage())),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('已退出的飞书'), findsNothing);
    expect(find.text('暂停的钉钉'), findsOneWidget);
    expect(find.text('恢复'), findsOneWidget);
    expect(find.text('尚未连接账号'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
