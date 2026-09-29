import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imbroglio/src/core/models.dart';
import 'package:imbroglio/src/services/store.dart';
import 'package:imbroglio/src/services/workspace.dart';
import 'package:imbroglio/src/ui/app.dart';
import 'package:imbroglio/src/ui/settings.dart';

class CleanupWorkspace extends Workspace {
  final requests = <bool>[];
  bool fail = false;
  @override
  Future<void> deleteAccount(AccountRef a, {bool logout = true}) async {
    requests.add(logout);
    if (fail) throw const AppFailure('test', '清理失败，请重试');
    accounts.removeWhere((v) => v.id == a.id);
    changed();
  }
}

void main() {
  late CleanupWorkspace w;
  setUp(() async {
    w = CleanupWorkspace()
      ..root = '/test/workspace'
      ..store = Store(NativeDatabase.memory())
      ..accounts = [
        const AccountRef(
          id: 'a',
          platform: 'feishu',
          label: '测试账号',
          enabled: false,
        ),
      ];
    await w.store.init();
  });
  tearDown(() => w.close());
  Future<void> show(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [workspaceProvider.overrideWith((ref) => w)],
        child: const MaterialApp(home: Scaffold(body: SettingsPage())),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets(
    'cleanup requires confirmation and offers explicit local-only deletion',
    (tester) async {
      await show(tester);
      await tester.tap(find.byTooltip('删除账号及本地数据'));
      await tester.pumpAndSettle();
      expect(
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
        true,
      );
      expect(find.textContaining('此操作无法撤销'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(w.requests, isEmpty);
      expect(w.accounts, hasLength(1));
      await tester.tap(find.byTooltip('删除账号及本地数据'));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(CheckboxListTile));
      await tester.pumpAndSettle();
      expect(find.text('仅清理本地数据不会注销登录或撤销服务端授权。'), findsOneWidget);
      await tester.tap(find.text('永久删除'));
      await tester.pumpAndSettle();
      expect(w.requests, [false]);
      expect(find.text('已清理 测试账号 的本地数据'), findsOneWidget);
      expect(find.byTooltip('删除账号及本地数据'), findsNothing);
    },
  );

  testWidgets(
    'signed-out accounts expose cleanup only inside a collapsed section',
    (tester) async {
      w.accounts[0] = w.accounts[0].copyWith(signedOut: true);
      await show(tester);
      expect(find.text('测试账号'), findsNothing);
      await tester.tap(find.text('已退出账号的本地数据（1）'));
      await tester.pumpAndSettle();
      expect(find.text('测试账号'), findsOneWidget);
      expect(find.text('授权'), findsNothing);
      await tester.tap(find.text('清理本地数据'));
      await tester.pumpAndSettle();
      expect(find.byType(CheckboxListTile), findsNothing);
      await tester.tap(find.text('永久删除'));
      await tester.pumpAndSettle();
      expect(w.requests, [false]);
      expect(find.text('已退出账号的本地数据（1）'), findsNothing);
    },
  );

  testWidgets('failed cleanup keeps the account and retry entry', (
    tester,
  ) async {
    w.fail = true;
    await show(tester);
    await tester.tap(find.byTooltip('删除账号及本地数据'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('永久删除'));
    await tester.pumpAndSettle();
    expect(w.requests, [true]);
    expect(find.text('清理失败，请重试'), findsOneWidget);
    expect(find.byTooltip('删除账号及本地数据'), findsOneWidget);
    expect(w.accounts, hasLength(1));
    expect(tester.takeException(), isNull);
  });
}
