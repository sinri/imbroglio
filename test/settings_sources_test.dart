import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imbroglio/src/core/models.dart';
import 'package:imbroglio/src/services/plugins.dart';
import 'package:imbroglio/src/services/store.dart';
import 'package:imbroglio/src/services/workspace.dart';
import 'package:imbroglio/src/ui/app.dart';
import 'package:imbroglio/src/ui/settings.dart';

class CountingStore extends Store {
  CountingStore() : super(NativeDatabase.memory());
  int installationReads = 0;

  @override
  Future<Json?> get(String bucket, String key) {
    if (bucket == 'installations') installationReads++;
    return super.get(bucket, key);
  }
}

void main() {
  late Workspace w;
  setUp(() async {
    w = Workspace()
      ..root = '/test/workspace'
      ..store = CountingStore();
    await w.store.init();
    w.plugins = PluginManager(w.root, w.store, 'arm64');
    w.packages = [
      {'id': 'custom', 'name': '团队 IM', 'kind': 'im', 'enabled': true},
      {'id': 'agent', 'name': '助手', 'kind': 'agent', 'enabled': true},
    ];
  });
  tearDown(() => w.close());

  Future<void> showPage(WidgetTester tester, Widget page) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [workspaceProvider.overrideWith((ref) => w)],
        child: MaterialApp(home: Scaffold(body: page)),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('settings routes account creation by enabled IM source', (
    tester,
  ) async {
    await w.store.put('installations', 'feishu', {'enabled': false});
    await showPage(tester, const SettingsPage());
    OutlinedButton add(String id) =>
        tester.widget<OutlinedButton>(find.byKey(ValueKey('add-account:$id')));
    expect(add('dingtalk').onPressed, isNull);
    expect(add('feishu').onPressed, isNull);
    expect(add('custom').onPressed, isNotNull);
    expect(find.text('尚未安装插件，请前往插件中心安装'), findsOneWidget);
    expect(find.text('插件已停用，请前往插件中心启用'), findsOneWidget);
    expect(find.byKey(const ValueKey('account-source:agent')), findsNothing);
    await tester.tap(find.byKey(const ValueKey('add-account:custom')));
    await tester.pumpAndSettle();
    expect(find.text('连接 custom'), findsOneWidget);
    await tester.tap(find.text('关闭'));
    await tester.pumpAndSettle();
    await w.store.put('installations', 'feishu', {'enabled': true});
    w.changed();
    await tester.pumpAndSettle();
    expect(add('feishu').onPressed, isNotNull);
    await tester.tap(find.byKey(const ValueKey('add-account:feishu')));
    await tester.pumpAndSettle();
    expect(find.text('连接 飞书'), findsOneWidget);
    expect(find.text('初始化飞书应用配置'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('source status stays stable during background updates', (
    tester,
  ) async {
    await w.store.put('installations', 'feishu', {'enabled': true});
    await showPage(tester, const SettingsPage());
    final reads = (w.store as CountingStore).installationReads;
    for (var i = 0; i < 5; i++) {
      await w.store.put('diagnostics', '$i', {'detail': '后台同步'});
      w.changed();
      // Inspect the rebuild frame, before any newly created query could settle.
      await tester.pump();
      expect(find.text('正在读取插件状态…'), findsNothing);
      expect(find.text('插件已就绪'), findsNWidgets(2));
      for (final id in ['feishu', 'custom']) {
        expect(
          tester
              .widget<OutlinedButton>(find.byKey(ValueKey('add-account:$id')))
              .onPressed,
          isNotNull,
        );
      }
      expect((w.store as CountingStore).installationReads, reads);
    }
    await w.store.remove('installations', 'feishu');
    w.packages.first['enabled'] = false;
    w.changed();
    await tester.pumpAndSettle();
    expect(find.text('尚未安装插件，请前往插件中心安装'), findsNWidgets(2));
    expect(find.text('插件已停用，请前往插件中心启用'), findsOneWidget);
    for (final id in ['feishu', 'custom']) {
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(ValueKey('add-account:$id')))
            .onPressed,
        isNull,
      );
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('existing accounts are grouped and can be renamed in settings', (
    tester,
  ) async {
    w.accounts = [
      const AccountRef(
        id: 'a',
        platform: 'dingtalk',
        label: '工作钉钉',
        enabled: false,
      ),
      const AccountRef(
        id: 'b',
        platform: 'feishu',
        label: '工作飞书',
        enabled: false,
      ),
    ];
    await showPage(tester, const SettingsPage());
    final group = find.byKey(const ValueKey('account-source:dingtalk'));
    expect(
      find.descendant(of: group, matching: find.text('工作钉钉')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: group, matching: find.text('工作飞书')),
      findsNothing,
    );
    await tester.tap(find.descendant(of: group, matching: find.text('改名')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '新的名称');
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect(
      find.descendant(of: group, matching: find.text('新的名称')),
      findsOneWidget,
    );
    expect((await w.store.get('accounts', 'a'))!['label'], '新的名称');
    expect(tester.takeException(), isNull);
  });

  testWidgets('plugin page only offers plugin management', (tester) async {
    await showPage(tester, const PluginsPage());
    expect(find.text('安装插件包'), findsOneWidget);
    expect(find.text('安装'), findsNWidgets(2));
    expect(find.text('连接账号'), findsNothing);
    expect(find.byTooltip('连接账号'), findsNothing);
    expect(find.byIcon(Icons.person_add_alt), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
