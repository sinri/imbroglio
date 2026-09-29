import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imbroglio/src/core/models.dart';
import 'package:imbroglio/src/services/workspace.dart';
import 'package:imbroglio/src/ui/app.dart';
import 'package:imbroglio/src/ui/settings.dart';

class LoginWorkspace extends Workspace {
  String? connectedProfile;
  Completer<Json>? authorization;
  Completer<void>? initialization;
  bool emitAuthUrls = false;
  bool failConnect = false;
  bool failConfigure = false;
  bool failLogin = false;
  final configurations = <bool>[];
  bool cancelled = false;
  @override
  void cancelAuthentication(AccountRef a) {
    cancelled = true;
    authorization?.completeError(const AppFailure('cancelled', '授权已中止'));
  }

  @override
  Future<AccountRef> addAccount(String platform, String label) async =>
      AccountRef(id: 'test', platform: platform, label: label);
  @override
  Future<Json> authenticate(
    AccountRef a, {
    bool configure = false,
    Json config = const {},
    void Function(String stage)? onStage,
  }) async {
    configurations.add(configure);
    if (configure) {
      onStage?.call('应用初始化');
      if (emitAuthUrls) {
        authUrls[a.id] = 'https://accounts.feishu.cn/setup';
        changed();
      }
      if (initialization != null) await initialization!.future;
      if (failConfigure) throw const AppFailure('test', '应用初始化失败');
    }
    onStage?.call('用户授权');
    if (emitAuthUrls) {
      authUrls[a.id] = 'https://accounts.feishu.cn/login';
      changed();
    }
    if (failLogin) throw const AppFailure('test', '用户授权失败');
    final result = authorization != null
        ? await authorization!.future
        : {
            'profiles': [
              {'profile': 'test-org', 'corpName': '测试组织'},
            ],
          };
    onStage?.call('连接验证');
    return result;
  }

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
  testWidgets('browser launch failure leaves a manual authorization option', (
    tester,
  ) async {
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/url_launcher'),
      (_) async => false,
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/url_launcher'),
        null,
      ),
    );
    final workspace = LoginWorkspace()
      ..emitAuthUrls = true
      ..authorization = Completer<Json>();
    await openLogin(tester, workspace, platform: 'feishu');
    await tester.tap(find.text('开始授权'));
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('未能打开浏览器'), findsOneWidget);
    expect(find.text('打开授权页面'), findsOneWidget);
    expect(find.text('https://accounts.feishu.cn/login'), findsOneWidget);
    await tester.tap(find.text('中止授权'));
    await tester.pumpAndSettle();
    expect(find.text('授权已中止'), findsOneWidget);
    expect(workspace.connectedProfile, isNull);
  });
  testWidgets('browser setup proceeds to a distinct user authorization page', (
    tester,
  ) async {
    final urls = <String>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/url_launcher'),
      (call) async {
        if (call.method == 'launch') urls.add(call.arguments['url'] as String);
        return true;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/url_launcher'),
        null,
      ),
    );
    final workspace = LoginWorkspace()
      ..emitAuthUrls = true
      ..initialization = Completer<void>()
      ..authorization = Completer<Json>();
    await openLogin(tester, workspace, platform: 'feishu');
    await tester.tap(find.text('开始授权'));
    await tester.pump();
    await tester.pump();
    expect(urls, ['https://accounts.feishu.cn/setup']);
    workspace.initialization!.complete();
    await tester.pump();
    await tester.pump();
    expect(find.textContaining('应用配置已完成。第二步'), findsOneWidget);
    expect(urls, [
      'https://accounts.feishu.cn/setup',
      'https://accounts.feishu.cn/login',
    ]);
    workspace.changed();
    await tester.pump();
    expect(urls.length, 2);
    expect(workspace.connectedProfile, isNull);
    workspace.authorization!.complete({});
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(workspace.connectedProfile, '');
  });
  testWidgets('Feishu authorization can be stopped and restarted', (
    tester,
  ) async {
    final workspace = LoginWorkspace()..authorization = Completer<Json>();
    await openLogin(tester, workspace, platform: 'feishu');
    await tester.tap(find.text('开始授权'));
    await tester.pump();
    expect(find.text('中止授权'), findsOneWidget);
    await tester.tap(find.text('中止授权'));
    await tester.pumpAndSettle();
    expect(workspace.cancelled, true);
    expect(workspace.connectedProfile, isNull);
    expect(find.text('授权已中止'), findsOneWidget);
    expect(find.text('开始授权'), findsOneWidget);
    workspace.authorization = null;
    await tester.tap(find.text('开始授权'));
    await tester.pumpAndSettle();
    expect(workspace.configurations, [true, false]);
    expect(find.byType(AlertDialog), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Feishu login retry preserves completed initialization', (
    tester,
  ) async {
    final workspace = LoginWorkspace()..failLogin = true;
    await openLogin(tester, workspace, platform: 'feishu');
    await tester.tap(find.text('开始授权'));
    await tester.pumpAndSettle();
    expect(find.textContaining('用户授权失败'), findsOneWidget);
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      false,
    );
    workspace.failLogin = false;
    await tester.tap(find.text('开始授权'));
    await tester.pumpAndSettle();
    expect(workspace.configurations, [true, false]);
    expect(find.byType(AlertDialog), findsNothing);
  });

  testWidgets('failed initialization is retained for retry', (tester) async {
    final workspace = LoginWorkspace()..failConfigure = true;
    await openLogin(tester, workspace, platform: 'feishu');
    await tester.tap(find.text('开始授权'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      true,
    );
    workspace.failConfigure = false;
    await tester.tap(find.text('开始授权'));
    await tester.pumpAndSettle();
    expect(workspace.configurations, [true, true]);
  });

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
