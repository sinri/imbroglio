import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imbroglio/src/services/mcp.dart';
import 'package:imbroglio/src/services/store.dart';
import 'package:imbroglio/src/services/workspace.dart';
import 'package:imbroglio/src/ui/app.dart';
import 'package:imbroglio/src/ui/mcp_servers.dart';

void main() {
  testWidgets('MCP add, enable, edit and delete preserve explicit opt-in', (
    tester,
  ) async {
    FlutterSecureStorage.setMockInitialValues({});
    final w = Workspace()
      ..root = '/test/workspace'
      ..store = Store(NativeDatabase.memory());
    await w.store.init();
    await tester.binding.setSurfaceSize(const Size(700, 900));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [workspaceProvider.overrideWith((ref) => w)],
        child: const MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(child: McpServersSection()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加服务器'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byType(TextField),
      jsonEncode({
        'id': 'test.http',
        'name': '测试服务',
        'transport': 'http',
        'url': 'https://example.com/mcp',
        'headers': {'Authorization': 'Bearer token'},
      }),
    );
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    final repo = McpRepository(w.store);
    expect((await repo.list()).single['enabled'], false);
    await tester.pumpAndSettle();
    expect(find.text('测试服务'), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect((await repo.list()).single['enabled'], true);
    await tester.tap(find.byTooltip('管理 MCP'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('保存'));
    await tester.pumpAndSettle();
    expect((await repo.list()).single['enabled'], false);
    await tester.tap(find.byTooltip('管理 MCP'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(await repo.list(), isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await w.close();
    await tester.binding.setSurfaceSize(null);
  });
}
