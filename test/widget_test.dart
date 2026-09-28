import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:imbroglio/src/services/workspace.dart';
import 'package:imbroglio/src/ui/app.dart';

void main() {
  testWidgets('loading frame shows progress before workspace initialization', (
    tester,
  ) async {
    final workspace = Workspace();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [workspaceProvider.overrideWith((ref) => workspace)],
        child: const ImbroglioApp(),
      ),
    );
    expect(find.text('正在加载，请稍候'), findsOneWidget);
    workspace.startupProgress('正在打开消息数据库…');
    await tester.pump();
    expect(find.text('正在打开消息数据库…'), findsOneWidget);
    workspace.fatal = 'database unavailable';
    workspace.changed();
    await tester.pump();
    expect(find.textContaining('database unavailable'), findsOneWidget);
    expect(find.text('正在加载，请稍候'), findsNothing);
  });
  testWidgets('startup failure is visible rather than an empty shell', (
    tester,
  ) async {
    final workspace = Workspace()..fatal = 'test failure';
    await tester.pumpWidget(
      ProviderScope(
        overrides: [workspaceProvider.overrideWith((ref) => workspace)],
        child: const ImbroglioApp(),
      ),
    );
    expect(find.textContaining('test failure'), findsOneWidget);
  });
}
