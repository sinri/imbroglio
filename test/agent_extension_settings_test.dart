import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imbroglio/src/services/agent_extensions.dart';
import 'package:imbroglio/src/services/plugins.dart';
import 'package:imbroglio/src/services/store.dart';
import 'package:imbroglio/src/services/workspace.dart';
import 'package:imbroglio/src/ui/app.dart';
import 'package:imbroglio/src/ui/settings.dart';

void main() {
  for (final width in [420.0, 1200.0]) {
    testWidgets('plugin sections and explicit script opt-in at width $width', (
      tester,
    ) async {
      final w = Workspace()
        ..root = '/test/workspace'
        ..store = Store(NativeDatabase.memory());
      await w.store.init();
      w.plugins = PluginManager(w.root, w.store, 'arm64');
      w.packages = [
        {
          'id': 'test.agent',
          'kind': 'agent',
          'name': '一个名称很长的本地工作助手，用于验证窄窗口中的信息布局',
          'version': '1.0',
          'enabled': true,
          'builtin': true,
          'tools': ['search'],
          'skills': ['test.skill'],
        },
        {
          'id': 'test.skill',
          'kind': 'skill',
          'name': '文本统计技能',
          'version': '1.0',
          'enabled': true,
          'scripts': [
            {'id': 'count'},
          ],
        },
      ];
      for (final package in w.packages) {
        await w.store.put('packages', package['id'], package);
      }
      await tester.binding.setSurfaceSize(Size(width, 1000));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [workspaceProvider.overrideWith((ref) => w)],
          child: const MaterialApp(home: Scaffold(body: PluginsPage())),
        ),
      );
      await tester.pumpAndSettle();
      for (final title in ['平台连接器', 'Agent', 'Skills · 技能', '运行权限']) {
        expect(find.text(title), findsOneWidget);
      }
      final details = find.text('查看详情').first;
      await tester.ensureVisible(details);
      await tester.pumpAndSettle();
      await tester.tap(details);
      await tester.pumpAndSettle();
      expect(find.text('ID：test.agent'), findsOneWidget);
      expect(tester.takeException(), isNull);
      final toggle = find.widgetWithText(SwitchListTile, '允许本地脚本执行');
      expect(tester.widget<SwitchListTile>(toggle).value, false);
      expect(find.text('导入 Agent / skill 目录'), findsOneWidget);
      expect(find.text('新建 Agent'), findsOneWidget);
      expect(find.text('新建 Skill'), findsOneWidget);
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(await AgentExtensions(w.root, w.store).scriptsEnabled, true);
      await tester.ensureVisible(toggle);
      await tester.pumpAndSettle();
      await tester.tap(toggle);
      await tester.pumpAndSettle();
      expect(await AgentExtensions(w.root, w.store).scriptsEnabled, false);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await w.close();
      await tester.binding.setSurfaceSize(null);
    });
  }
}
