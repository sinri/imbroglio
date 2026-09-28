import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imbroglio/src/core/models.dart';
import 'package:imbroglio/src/services/workspace.dart';
import 'package:imbroglio/src/ui/app.dart';
import 'package:imbroglio/src/ui/settings.dart';

class LoginWorkspace extends Workspace {
  String? connectedProfile;
  Completer<Json>? authorization;
  bool failConnect = false;
  @override
  Future<AccountRef> addAccount(String platform, String label) async =>
      AccountRef(id: 'test', platform: platform, label: label);
  @override
  Future<Json> authenticate(
    AccountRef a, {
    bool configure = false,
    Json config = const {},
  }) async => authorization != null
      ? await authorization!.future
      : {
          'profiles': [
            {'profile': 'test-org', 'corpName': '测试组织'},
          ],
        };
  @override
  Future<void> connect(
    AccountRef a, {
    String profile = '',
    String organization = '',
    String userId = '',
  }) async {
    if (failConnect) throw const AppFailure('test', '测试连接失败');
    connectedProfile = profile;
    changed();
  }
}

Future<void> openLogin(
  WidgetTester tester,
  LoginWorkspace workspace, {
  String platform = 'dingtalk',
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [workspaceProvider.overrideWith((ref) => workspace)],
      child: MaterialApp(
        home: Consumer(
          builder: (context, ref, _) => Scaffold(
            body: TextButton(
              onPressed: () => accountDialog(context, ref, platform),
              child: const Text('连接'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('连接'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'authorized profile closes dialog without disposing live fields',
    (tester) async {
      final workspace = LoginWorkspace();
      await openLogin(tester, workspace);
      await tester.tap(find.text('开始授权'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('测试组织'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(AlertDialog), findsNothing);
      expect(workspace.connectedProfile, 'test-org');
    },
  );

  testWidgets(
    'closing before authorization preserves controllers through exit animation',
    (tester) async {
      await openLogin(tester, LoginWorkspace());
      await tester.tap(find.byType(TextField));
      await tester.enterText(find.byType(TextField), '测试账号');
      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.byType(AlertDialog), findsNothing);
    },
  );

  testWidgets('automatic connection closes Feishu dialog safely', (
    tester,
  ) async {
    final workspace = LoginWorkspace();
    await openLogin(tester, workspace, platform: 'feishu');
    await tester.tap(find.text('开始授权'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byType(AlertDialog), findsNothing);
    expect(workspace.connectedProfile, '');
  });

  testWidgets('failed profile connection is shown and allows retry', (
    tester,
  ) async {
    final workspace = LoginWorkspace()..failConnect = true;
    await openLogin(tester, workspace);
    await tester.tap(find.text('开始授权'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('测试组织'));
    await tester.pumpAndSettle();
    expect(find.textContaining('测试连接失败'), findsOneWidget);
    expect(tester.takeException(), isNull);
    workspace.failConnect = false;
    await tester.tap(find.text('测试组织'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(workspace.connectedProfile, 'test-org');
  });

  testWidgets('late authorization completion does not access disposed dialog', (
    tester,
  ) async {
    final completion = Completer<Json>();
    final workspace = LoginWorkspace()..authorization = completion;
    await openLogin(tester, workspace);
    await tester.tap(find.text('开始授权'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    completion.complete({});
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(workspace.connectedProfile, isNull);
  });
}
