import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imbroglio/src/core/models.dart';
import 'package:imbroglio/src/services/agent_extensions.dart';
import 'package:imbroglio/src/services/store.dart';
import 'package:imbroglio/src/ui/agent_editor.dart';

void main() {
  late Directory root;
  late Store store;
  late AgentExtensions extensions;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('agent-editor-ui-');
    store = Store(NativeDatabase.memory());
    await store.init();
    extensions = AgentExtensions(root.path, store);
  });
  tearDown(() async {
    await store.close();
    await root.delete(recursive: true);
  });
  Future<void> show(
    WidgetTester tester, {
    String kind = 'agent',
    Json? original,
    double width = 1000,
  }) async {
    await tester.binding.setSurfaceSize(Size(width, 1000));
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<bool>(
                context: context,
                barrierDismissible: false,
                builder: (_) => AgentDefinitionEditor(
                  extensions: extensions,
                  kind: kind,
                  skills: const [],
                  servers: const [],
                  original: original,
                ),
              ),
              child: const Text('打开编辑器'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开编辑器'));
    await tester.pumpAndSettle();
  }

  Finder field(String label) => find.byWidgetPredicate(
    (w) => w is TextField && w.decoration?.labelText == label,
  );
  Future<void> enter(WidgetTester tester, String label, String text) async {
    final target = field(label);
    await tester.ensureVisible(target);
    await tester.pumpAndSettle();
    await tester.enterText(target, text);
  }

  Future<void> save(WidgetTester tester) async {
    final button = tester.widget<FilledButton>(
      find.widgetWithText(FilledButton, '保存'),
    );
    await tester.runAsync(() async {
      await (button.onPressed as dynamic)();
    });
    await tester.pumpAndSettle();
  }

  testWidgets('create skill without imports and close editor after save', (
    tester,
  ) async {
    await show(tester, kind: 'skill', width: 420);
    await enter(tester, 'ID', 'test.skill');
    await enter(tester, '名称', '新技能');
    await enter(tester, '指令内容', '整理资料并注明来源');
    await save(tester);
    final record = await store.get('packages', 'test.skill');
    expect(record?['kind'], 'skill');
    expect(record?['prompt'], '整理资料并注明来源');
    expect(find.byType(AgentDefinitionEditor), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(null);
  });
  testWidgets('builtin edit locks ID and saves prompt without enabling it', (
    tester,
  ) async {
    final original = <String, dynamic>{
      'id': 'test.builtin',
      'name': '内置助手',
      'version': '1',
      'kind': 'agent',
      'protocol': 1,
      'prompt': '原指令',
      'tools': [],
      'builtin': true,
      'enabled': false,
      'mcpServers': [],
    };
    await store.put('packages', original['id'], original);
    await show(tester, original: original);
    expect(tester.widget<TextField>(field('ID')).readOnly, true);
    await enter(tester, '指令内容', '新指令');
    await save(tester);
    final saved = await store.get('packages', original['id']);
    expect(saved?['prompt'], '新指令');
    expect(saved?['enabled'], false);
    expect(saved?['mcpServers'], isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(null);
  });
  testWidgets(
    'create Agent with tool selection, explicit MCP scope and script code',
    (tester) async {
      await show(tester);
      await enter(tester, 'ID', 'test.scripted');
      await enter(tester, '名称', '脚本助手');
      FocusManager.instance.primaryFocus?.unfocus();
      await tester.pumpAndSettle();
      await Scrollable.ensureVisible(
        tester.element(find.widgetWithText(FilterChip, '搜索资料')),
        alignment: .3,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilterChip, '搜索资料'));
      final mcp = find.widgetWithText(SwitchListTile, '不限定 MCP 服务器');
      await tester.ensureVisible(mcp);
      await tester.pumpAndSettle();
      await tester.tap(mcp);
      await tester.ensureVisible(find.text('添加脚本'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('添加脚本'));
      await tester.pumpAndSettle();
      await enter(tester, '脚本 ID', 'hello');
      await enter(tester, '文件路径', 'scripts/hello.py');
      await enter(tester, '脚本代码', 'print("hello")');
      await save(tester);
      final record = (await store.get('packages', 'test.scripted'))!;
      expect(record['tools'], ['search']);
      expect(record['mcpServers'], isEmpty);
      expect(await tester.runAsync(() => extensions.scriptSources(record)), {
        'scripts/hello.py': 'print("hello")',
      });
      expect(await extensions.scriptsEnabled, false);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.binding.setSurfaceSize(null);
    },
  );

  testWidgets('cancel discards draft and does not create a package', (
    tester,
  ) async {
    await show(tester);
    await enter(tester, '名称', '不保存');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('放弃未保存的修改？'), findsOneWidget);
    await tester.tap(find.text('放弃修改'));
    await tester.pumpAndSettle();
    expect(await store.list('packages'), isEmpty);
    expect(find.byType(AgentDefinitionEditor), findsNothing);
    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(null);
  });
}
