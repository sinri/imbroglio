import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:imbroglio/src/services/store.dart';
import 'package:imbroglio/src/services/workspace.dart';
import 'package:imbroglio/src/services/agent.dart';
import 'package:imbroglio/src/ui/app.dart';
import 'package:imbroglio/src/ui/agent_page.dart';

void main() {
  for (final width in [360.0, 1280.0]) {
    testWidgets('composer and conversation at width $width', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 720));
      final w = Workspace()..store = Store(NativeDatabase.memory());
      await w.store.init();
      w.packages = [
        {'id': 'test', 'kind': 'agent', 'enabled': true, 'name': '通用工作助手'},
      ];
      final agent = AgentController(w);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            workspaceProvider.overrideWith((ref) => w),
            agentProvider.overrideWith((ref) => agent),
          ],
          child: MaterialApp(
            theme: ImbroglioApp().theme(Brightness.light),
            home: const Scaffold(body: AgentPage()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('今天想完成什么？'), findsOneWidget);
      await tester.tap(find.text('整理待办事项'));
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '整理待办事项',
      );
      await tester.tap(find.text('0 个账号'));
      await tester.pumpAndSettle();
      expect(find.text('选择资料范围'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      agent.history = [
        {'role': 'user', 'content': '分析资料'},
        {'role': 'assistant', 'content': List.filled(80, '回复内容').join('\n\n')},
      ];
      agent.notifyListeners();
      await tester.pumpAndSettle();
      final fieldRect = tester.getRect(find.byType(TextField));
      expect(fieldRect.bottom, lessThan(720));
      expect(fieldRect.top, greaterThan(450));
      final scrollable = tester.state<ScrollableState>(
        find.byType(Scrollable).first,
      );
      expect(scrollable.position.extentAfter, lessThan(1));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await w.close();
      await tester.binding.setSurfaceSize(null);
    });
  }
}
