import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imbroglio/src/services/store.dart';
import 'package:imbroglio/src/services/workspace.dart';
import 'package:imbroglio/src/ui/app.dart';
import 'package:imbroglio/src/ui/settings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  late Workspace w;
  late List<String> mutations;
  bool failWrite = false;
  setUp(() async {
    mutations = [];
    failWrite = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'containsKey') return true;
          if (call.method == 'write' || call.method == 'delete') {
            if (failWrite) throw PlatformException(code: 'storage_failed');
            mutations.add(call.method);
          }
          return null;
        });
    w = Workspace()
      ..root = '/test/workspace'
      ..store = Store(NativeDatabase.memory());
    await w.store.init();
    await w.store.put('settings', 'model', {
      'baseUrl': 'https://example.com/v1',
      'model': 'original-model',
    });
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await w.close();
  });
  Future<void> show(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 1800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [workspaceProvider.overrideWith((ref) => w)],
        child: const MaterialApp(home: Scaffold(body: SettingsPage())),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> tap(WidgetTester tester, String text) async {
    await tester.ensureVisible(find.text(text));
    await tester.tap(find.text(text));
    await tester.pumpAndSettle();
  }

  testWidgets('context defaults to 1M, persists selection and cancels draft', (
    tester,
  ) async {
    await show(tester);
    expect(find.text('上下文限制：1M tokens'), findsOneWidget);
    await tap(tester, '编辑配置');
    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('128K').last);
    await tester.pumpAndSettle();
    await tap(tester, '保存模型配置');
    expect((await w.store.get('settings', 'model'))!['contextLimit'], 128000);
    expect(find.text('上下文限制：128K tokens'), findsOneWidget);
    await tap(tester, '编辑配置');
    await tester.tap(find.byType(DropdownButtonFormField<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('32K').last);
    await tester.pumpAndSettle();
    await tap(tester, '取消');
    await tap(tester, '编辑配置');
    expect(find.text('128K'), findsOneWidget);
    expect((await w.store.get('settings', 'model'))!['contextLimit'], 128000);
  });

  testWidgets('cancel discards draft and pending credential deletion', (
    tester,
  ) async {
    await show(tester);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('original-model'), findsOneWidget);
    await tap(tester, '编辑配置');
    await tester.enterText(find.byType(TextField).at(1), 'draft-model');
    await tap(tester, '删除已存密钥');
    expect(mutations, isEmpty);
    await tap(tester, '取消');
    expect(find.text('original-model'), findsOneWidget);
    expect(mutations, isEmpty);
    await tap(tester, '编辑配置');
    expect(
      tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
      'original-model',
    );
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      false,
    );
  });

  testWidgets('save updates summary and retains existing key when blank', (
    tester,
  ) async {
    await show(tester);
    await tap(tester, '编辑配置');
    await tester.enterText(find.byType(TextField).at(1), 'new-model');
    await tap(tester, '保存模型配置');
    expect(find.byType(TextField), findsNothing);
    expect(find.text('new-model'), findsOneWidget);
    expect((await w.store.get('settings', 'model'))!['model'], 'new-model');
    expect(mutations, isEmpty);
  });

  testWidgets('failed save keeps draft open and persisted config unchanged', (
    tester,
  ) async {
    await show(tester);
    await tap(tester, '编辑配置');
    await tester.enterText(find.byType(TextField).at(1), 'draft-model');
    await tester.enterText(find.byType(TextField).at(2), 'test-key');
    failWrite = true;
    await tap(tester, '保存模型配置');
    expect(find.byType(TextField), findsNWidgets(3));
    expect(
      tester.widget<TextField>(find.byType(TextField).at(1)).controller!.text,
      'draft-model',
    );
    expect(
      (await w.store.get('settings', 'model'))!['model'],
      'original-model',
    );
  });
}
